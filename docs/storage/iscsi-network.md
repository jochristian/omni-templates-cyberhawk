# iSCSI storage network

> **2026-08-29: an attempt to move iSCSI onto the node network caused a
> cluster-wide storage outage.** Read "The incident" before touching any of this.

## The current path

TrueNAS (Proxmox VMID 450), OPNsense (405) and worker-02 (850) are all VMs on the
same host, `pve-blix-01`. All cluster block I/O takes this route:

```
worker-02 (vmbr3, 10.50.1.60)
  -> 10.50.1.1  = OPNsense net1 on vmbr3
  -> pf routes + filters (4 vCPU FreeBSD VM, E5-2620 v4, host load 7-10)
  -> OPNsense net2 on vmbr2
  -> TrueNAS enp6s18 (192.168.141.150)
```

Two VMs on one physical box, with a stateful firewall in the block-I/O path.
TrueNAS has a second vNIC (`net1`, bridge `vmbr3`) that is attached but **must stay
unconfigured** unless the policy-routing fix below is in place first.

The firewall hop costs about **0.17 ms** — direct 0.372 ms avg vs 0.55 ms via
OPNsense, measured interleaved over 3x60 packets, same delta at 1400 B. Modest.
The better arguments for moving are that an OPNsense reboot currently stalls all
blix block storage and that pf state sits in the I/O path — not raw latency.

## The incident (2026-08-29)

Adding `10.50.1.150/24` to `enp6s19` — with `192.168.141.150` still live on
`enp6s18` and still the portal in every PV — **took down all 21 iSCSI volumes on
worker-02 and corrupted 17 filesystems.**

Why: TrueNAS's default route stays on `enp6s18`, but `10.50.1.0/24` becomes
directly connected on `enp6s19`. Requests from worker-02 still arrived via
OPNsense, while replies took the new direct route. OPNsense saw only one half of
each flow, pf dropped the packets as out-of-state, and the initiator timed out:

```
connection12:0: ping timeout of 5 secs expired
connection12:0: detected conn error (1022)
sd 8:0:0:0: Power-on or device reset occurred
EXT4-fs (sdX): Remounting filesystem read-only
```

**Two things made it worse:**

1. **Downing the link is not enough.** `enp6s19` was set link-down but kept its
   address, so TrueNAS still held a connected route for `10.50.1.0/24` out a dead
   interface and black-holed every reply to worker-02. Storage stayed down until
   the *address* was deleted. Always remove the alias, never just the link.
2. **Downing the interface caused a second damage wave** as in-flight I/O errored
   out. Seven more filesystems went read-only at that moment.

Recovery took ~90 minutes: 17 `e2fsck` runs plus one `valkey-check-aof --fix`.
No data was lost, but that was luck as much as anything.

## If you try this again

Do **not** dual-home TrueNAS without one of these:

- **Policy routing on TrueNAS**, so replies sourced from `192.168.141.150` keep
  using `enp6s18`. Persist as a TrueNAS init script — it must survive reboots:
  ```
  ip rule add from 192.168.141.150 lookup 100
  ip route add default via 192.168.141.1 dev enp6s18 table 100
  ```
  Verify with `ip route get 10.50.1.60 from 192.168.141.150` before touching k8s.
- **Or a full cutover with everything stopped** — scale all iSCSI workloads to 0
  (see the Argo caveat below), bring up the new address, migrate all PVs, restart.
  No overlap window means no asymmetry.

## The other trap: the portal is immutable per PV

democratic-csi bakes the portal into every PV at provision time, and Kubernetes
refuses to change it:

```
spec.persistentvolumesource: Forbidden: spec.persistentvolumesource is immutable
after creation
```

**Editing the driver-config secret only affects newly provisioned volumes.** And
because the config drives the *controller's* API host too, pointing it at an
unreachable address breaks provisioning and detach for every volume — which is
exactly what happened here when the address was removed but the config still said
`10.50.1.150`.

Which portal a volume is on:

```bash
kubectl get pv -o json | jq -r '.items[]
  | select(.spec.csi != null and (.spec.storageClassName|test("democratic")))
  | "\(.spec.csi.volumeAttributes.portal)\t\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"' | sort
```

## Argo reverts `kubectl scale`

Every deployment scaled to 0 was back at `replicas: 1` within a minute.
`selfHeal: false` does not protect you: the manual change makes the app OutOfSync
and `automated: true` syncs `replicas` back from git on the next refresh.

**To hold a blix workload down, cordon `worker-02` and delete the pod.** Cordoned,
the blix-pinned pod has nowhere to reschedule and stays Pending regardless of what
Argo sets. CNPG's `cnpg.io/hibernation: on` annotation also survives, because it
isn't in git.

## Repair procedure

Filesystem state across all iSCSI volumes:

```bash
kubectl -n kube-system exec democratic-csi-iscsi-node-<id> -c csi-driver -- sh -c '
for l in /dev/disk/by-path/*iscsi*lun-0; do
  dev=$(readlink -f "$l")
  echo "$l $(dumpe2fs -h "$dev" 2>/dev/null | grep "Filesystem state:")"
done'
```

Per damaged volume, with the workload held down and the VolumeAttachment gone:

```bash
IQN=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeAttributes.iqn}')
# in the csi-driver container on the node:
iscsiadm -m discovery -t st -p 192.168.141.150:3260
iscsiadm -m node -T "$IQN" -p 192.168.141.150:3260 --login
DEV=$(readlink -f /dev/disk/by-path/ip-192.168.141.150:3260-iscsi-$IQN-lun-0)
e2fsck -fy "$DEV"
iscsiadm -m node -T "$IQN" -p 192.168.141.150:3260 --logout
iscsiadm -m node -T "$IQN" -p 192.168.141.150:3260 -o delete
```

Device letters are reassigned on every login/logout — **always resolve the device
through `/dev/disk/by-path`, never assume a previous `sdX`.** `e2fsck` refuses to
run on a mounted device, which is the safety net if a volume re-attached.

fsck repairs the filesystem but not file *contents*. Applications that were
mid-write need their own repair — here, valkey's incr AOF had a corrupt 60 KB tail
and needed `valkey-check-aof --fix <file>` run from a helper pod sharing the same
RWO PVC on the same node (RWO permits this; access is per-node, not per-pod).

## Cross-site

`10.50.1.0/24` is routed over the inter-site WireGuard link, so lørenskog nodes
reach the portal at ~2.9-3.1 ms. `ctrl-02` mounts iSCSI today: `data-openbao-2`
and `audit-openbao-2`, because OpenBao's 3-node raft puts one replica on each
control plane. See [[project_crosssite_iscsi_emergency_ro]].

**Open idea (not implemented):** restrict the portal to `10.50.1.0/24` so a
misscheduled pod fails to mount loudly instead of silently flipping ext4 to
`emergency_ro`. Only worth doing as part of a properly sequenced migration.

## Building this kustomization

`kustomize build` here renders the KSOPS secrets as **nothing at all — silently,
exit 0, no stderr** unless `--enable-exec` is passed:

```bash
kustomize build --enable-helm --enable-alpha-plugins --enable-exec .
```
