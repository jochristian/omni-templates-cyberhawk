# Talos / Kubernetes upgrade runbook

For when an Omni-driven upgrade wedges on a node drain — usually worker-02,
usually at the worst possible moment.

## Why drains deadlock here

Zone **`blix` has exactly one schedulable worker: worker-02.** ctrl-00 and
ctrl-01 carry `topology.kubernetes.io/zone=blix` too, but they are tainted
`node-role.kubernetes.io/control-plane` and nothing tolerates it.

Every workload with a `democratic-csi-iscsi` PVC is hard-pinned to that zone
(`requiredDuringSchedulingIgnoredDuringExecution`), because the iSCSI target is
blix-side and a lørenskog attachment runs its block I/O over the inter-site
WireGuard link — a blip there flips ext4 to `emergency_ro` permanently.

So the moment Omni cordons worker-02:

```
0/5 nodes are available: 1 node(s) didn't match Pod's node affinity/selector,
1 node(s) were unschedulable, 3 node(s) had untolerated taint(s).
```

Every evicted blix pod goes **Pending forever** — including the `cnpg` and
`cert-manager` operators. Any PodDisruptionBudget over those pods can then never
regain a healthy replica, `ALLOWED DISRUPTIONS` sticks at 0, and eviction returns
429 in a loop until client-go's client-side rate limiter (5 QPS) burns the drain
context deadline:

```
rpc error: code = Internal desc = upgrade failed: cordon/drain before reboot failed:
failed to drain node "worker-02": [error when evicting pods/"mariadb-1" -n "monitoring":
client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline, ...]
```

**That error is a symptom.** The cause is a PDB that can never be satisfied
because the pod has nowhere to go. Read the PDBs, not the rate limiter.

## Triage

```bash
# Which PDBs are blocking? Anything with ALLOWED DISRUPTIONS 0 is a candidate.
kubectl get pdb -A

# What is actually left on the node? DaemonSet pods are ignored by drain —
# only the non-DaemonSet ones matter.
kubectl get pods -A -o wide --field-selector spec.nodeName=worker-02

# Is Omni still retrying, or has it given up?
omnictl get talosupgradestatus cyberhawk-talos-k8s-01 -o yaml
```

## Unstick it (during an upgrade)

`kubectl delete pod` is **not** an eviction, so it bypasses the PDB entirely and
lets the drain finish. This is the escape hatch:

```bash
kubectl delete pod -n <ns> <blocking-pod> --wait=false
```

Omni retries the drain on its own; no need to restart the upgrade. The pod stays
Pending until the node reboots back in (~5 min), then everything reschedules.

Do **not** `kubectl uncordon` while Omni is mid-upgrade — it re-cordons on the
next retry and you just churn.

## Prevent it (before an upgrade)

The four single-instance CNPG clusters already carry `spec.enablePDB: false` for
exactly this reason — with `instances: 1` on a single-node zone the primary PDB
protects nothing and only converts a 5-minute reboot into a permanent deadlock.
Do not re-enable it without a second blix worker.

`monitoring/mariadb` is the remaining blocker. `replicas: 2` is not real HA here
— both pods land on worker-02 — and `spec.podDisruptionBudget.maxUnavailable: 1`
does not help, because once the sibling is Pending the allowed disruptions drop
to 0 again. Before an upgrade:

```bash
kubectl -n monitoring delete pdb mariadb    # mariadb-operator recreates it afterwards
```

If more single-instance CNPG clusters get added, the generic CNPG lever is:

```bash
kubectl cnpg maintenance set --all-namespaces     # nodeMaintenanceWindow.inProgress=true, reusePVC=true
# ... run the upgrade ...
kubectl cnpg maintenance unset --all-namespaces
```

## The actual fix

**Add a second worker in zone blix** (a VM on `pve-blix-01`, joined via the
`role-worker` machineclass). RWO iSCSI volumes still cannot be in two places at
once, but they can *move* — which is all a drain needs. That removes the
deadlock, makes worker-02 stop being a single point of failure for every
iSCSI-backed workload, and makes mariadb's two replicas mean something.

Until then, worker-02 is undrainable by design and every upgrade needs the steps
above.

## Related

- `docs/kyverno/break-glass.md` — if admission is what is blocking, not a PDB.
- Regenerate the gitignored `patches/install_cilium.yaml` / `patches/install_argocd.yaml`
  before any `omnictl cluster template sync`, or the sync **downgrades** live
  Cilium/Argo CD to whatever stale version those files hold. See the README.
