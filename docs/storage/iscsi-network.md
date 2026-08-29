# iSCSI storage network

## The path

TrueNAS (Proxmox VMID 450), OPNsense (405) and worker-02 (850) are all VMs on the
same host, `pve-blix-01`. Until 2026-08-29 all cluster block I/O took this route:

```
worker-02 (vmbr3, 10.50.1.60)
  -> 10.50.1.1  = OPNsense net1 on vmbr3
  -> pf routes + filters (4 vCPU FreeBSD VM, E5-2620 v4, host load 7-10)
  -> OPNsense net2 on vmbr2
  -> TrueNAS enp6s18 (192.168.141.150)
```

Two VMs on one physical box, with a stateful firewall in the block-I/O path.

TrueNAS's second vNIC (`net1`, bridge `vmbr3`) was already attached but unconfigured.
It now carries **10.50.1.150/24** as `enp6s19`, directly on the Kubernetes node
network — one bridge hop, no firewall.

Measured from worker-02 (interleaved, 3x60 packets, stable across rounds):

| target | path | min | avg |
|---|---|---|---|
| `10.50.1.150` | direct on vmbr3 | 0.22 ms | **0.372 ms** |
| `192.168.141.150` | via OPNsense | 0.35 ms | **0.55 ms** |

Same delta at 1400 B payload. The latency win is real but modest; the larger
benefits are that an OPNsense reboot or upgrade no longer stalls blix block
storage, and pf state tracking is out of the I/O path.

No TrueNAS-side changes were needed beyond the address: iSCSI portal 1 already
listens on `0.0.0.0:3260`, and initiator group 2 is allow-all (`initiators: []`).

## The trap: the portal is immutable per PV

democratic-csi bakes the portal into every PV at provision time, and Kubernetes
refuses to change it:

```
$ kubectl patch pv pvc-... --type=json \
    -p='[{"op":"replace","path":"/spec/csi/volumeAttributes/portal","value":"10.50.1.150:3260"}]'
The PersistentVolume "pvc-..." is invalid: spec.persistentvolumesource:
Forbidden: spec.persistentvolumesource is immutable after creation
```

**Editing the driver-config secret only affects newly provisioned volumes.** The 31
`democratic-csi-iscsi` PVs that existed on 2026-08-29 keep `192.168.141.150:3260`
until their PV object is recreated. Keep 192.168.141.150 alive for as long as any
of them remain — non-cluster consumers (`loke`) use it too.

Which portal a volume is on:

```bash
kubectl get pv -o json | jq -r '.items[]
  | select(.spec.csi != null and (.spec.storageClassName|test("democratic")))
  | "\(.spec.csi.volumeAttributes.portal)\t\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"' | sort
```

## Migrating an existing volume (phase 2)

Both iSCSI storage classes are `reclaimPolicy: Retain`, so the ZFS zvol survives PV
deletion. Per volume, in a window:

1. Scale the workload to 0 and confirm the `VolumeAttachment` is gone — this makes
   the node log out of the old portal cleanly.
2. Record the PV: `volumeHandle`, `iqn`, `lun`, capacity, `fsType`, claimRef.
3. Delete the PVC, then the PV.
4. Recreate the PV with the same `volumeHandle`/`iqn`/`lun` and
   `portal: 10.50.1.150:3260`, then recreate the PVC bound to it by name.
5. Scale up and confirm the new session:
   `kubectl -n kube-system exec <csi-node-pod> -c csi-driver -- iscsiadm -m session`

Worth doing for the sync-write volumes (the CNPG clusters, `storage-mariadb-*`,
`timescaledb-data-timescaledb-0`, `data-openbao-*`); the rest can migrate whenever
they are next rebuilt.

## Cross-site exposure

`10.50.1.0/24` is routed over the inter-site WireGuard link, so lørenskog nodes
reach both portals (~2.9-3.1 ms either way). The change is transparent there and
buys nothing — the WAN RTT dwarfs the firewall hop.

`ctrl-02` (lørenskog) does mount iSCSI today: `data-openbao-2` and
`audit-openbao-2`. OpenBao's 3-node raft puts one replica on each control plane,
so this is structural. Those are the volumes that needed the manual
`iscsiadm`/`e2fsck` repair in `docs/../democratic-csi fsck procedure` on
2026-07-07. See [`project_crosssite_iscsi_emergency_ro`] for the failure mode.

**Open idea (not implemented):** restrict `10.50.1.150:3260` to `10.50.1.0/24`
(TrueNAS initiator-group ACL, or an OPNsense rule) so a misscheduled pod fails to
mount loudly instead of silently flipping ext4 to `emergency_ro` weeks later. This
would turn the blix pins into a network-enforced invariant. OpenBao is
automatically exempt while its PVs still point at the old portal.

## Rollback

Re-point both configs back and restart the controllers; removing 10.50.1.150 from
`enp6s19` reverts the network side. Volumes provisioned while the new portal was
active would then need migrating back.
