# omni-templates-cyberhawk

Infrastructure-as-code for the **`cyberhawk-talos-k8s`** cluster. Two layers live in
this one repo:

1. **Cluster bootstrap** (repo root) — [Sidero Omni](https://www.sidero.dev/omni/)
   templates that provision a [Talos](https://www.talos.dev/) Kubernetes cluster with
   [Cilium](https://cilium.io/) as the CNI. Applied with `omnictl`.
2. **GitOps workloads** (`GitOps/clusters/cyberhawk-talos-k8s/`) — everything running on
   the cluster, reconciled from this repo by [Argo CD](https://argo-cd.readthedocs.io/).

The cluster is multi-site: nodes in zones `lorenskog` and `blix` are joined over Talos
**Kubespan**, and Cilium masquerades pod traffic between sites.

---

## Layer 1 — Cluster bootstrap (Omni / Talos)

### Files at the repo root

| File | Purpose |
|------|---------|
| `template.yaml` | Omni cluster template: defines the Cluster, ControlPlane (3 nodes), and Workers, and wires in the patches below. |
| `machineclass.yaml` | Omni `MachineClasses` — how nodes are discovered/auto-provisioned (`role-controlplane`, `proxmox-auto-worker-blix`, `role-worker-lorenskog`). |
| `cilium_values.yaml` | Reference copy of the Cilium Helm values used at bootstrap. The GitOps-managed source of truth is `GitOps/.../kube-system/cilium/values.yaml`. |
| `patches/` | Talos machine-config patches applied by `template.yaml`. |

### Patches (`patches/`)

| Patch | Effect |
|-------|--------|
| `cni.yml` | Disables the default CNI and kube-proxy (Cilium replaces both), schedules on control planes. |
| `kubespan.yml` | Enables Kubespan for inter-node/site WireGuard mesh. |
| `install_cilium.yaml` | Cilium as a Talos **inline manifest**. **Generated, gitignored** (see below). |
| `install_argocd.yaml` | Argo CD as a Talos **inline manifest**. **Generated, gitignored.** |
| `extraManifests.yml` | URLs for cluster add-ons: kubelet-serving-cert-approver, metrics-server, Gateway API CRDs, CSI external-snapshotter CRDs. |
| `monitoring.yaml` / `monitoring-controlplane.yaml` | Kubelet args for metrics scraping. |
| `gvisor-sysctl.yaml` / `gvisor-runtime-class.yaml` | gVisor runtime class + sysctls. |
| `etcd-timeouts.yaml`, `zswap.yaml`, `enable_helm.yaml` | etcd tuning, zswap, and Argo CD `--enable-helm` for kustomize helmCharts. |

> **Generated patches:** `install_cilium.yaml` and `install_argocd.yaml` are
> **gitignored** — they are rendered from Helm charts/kustomize and must be regenerated
> before applying the template (see step 2 below). (`install_nfs-csi-driver.yaml` is also
> gitignored but no longer used at bootstrap — the NFS CSI driver is now a GitOps app.)

### Prerequisites

- An operational **Sidero Omni** environment and machines it can provision.
- `omnictl`, `kubectl`, `helm`, `yq`, and `sops` on your workstation.

### Deploy / update the cluster

```bash
# 1. Helm repos (once)
helm repo add cilium https://helm.cilium.io/
helm repo update

# 2. Regenerate the gitignored Cilium inline-manifest patch from the in-repo chart
echo "cluster:"              >  patches/install_cilium.yaml
echo "  inlineManifests:"    >> patches/install_cilium.yaml
echo "    - name: cilium"    >> patches/install_cilium.yaml
echo "      contents: |"     >> patches/install_cilium.yaml
helm template cilium GitOps/clusters/cyberhawk-talos-k8s/1-system/kube-system/cilium \
  --namespace kube-system \
  | yq -i 'with(.cluster.inlineManifests.[] | select(.name=="cilium"); .contents=load_str("/dev/stdin"))' \
    patches/install_cilium.yaml
# (Render install_argocd.yaml the same way from 1-system/argocd before first bootstrap.)

# 3. Apply to Omni
omnictl apply -f machineclass.yaml
omnictl cluster template sync --file template.yaml
```

After the cluster comes up, load the SOPS age key so Argo CD can decrypt secrets:

```bash
cat keys.txt | kubectl -n argocd create secret generic argocd-sops-age-key \
  --from-file=keys.txt=/dev/stdin
```

---

## Layer 2 — GitOps workloads (Argo CD)

Everything under `GitOps/clusters/cyberhawk-talos-k8s/` is reconciled by Argo CD. The
model is **directory-driven**: a single `ApplicationSet`
(`1-system/argocd/appset.yaml`) discovers folders and creates one Argo CD `Application`
per directory. **To add a workload you create a directory — there is nothing to register.**

### Layers

Directories are grouped into numbered layers (applied roughly in order):

| Layer | Contains |
|-------|----------|
| `1-system/` | Cluster infrastructure: argocd, cilium (+ cilium-bgp), cnpg, mariadb-operator, CSI drivers (nfs, democratic-csi), gateway, namespaces. |
| `2-services/` | Platform services: cert-manager, monitoring (kube-prometheus-stack, librenms), openbao, newt, volsync-system. |
| `3-apps/` | Applications: it-tools, karakeep, portfolio. |
| `4-media/` | Media apps: tautulli, tracearr, yamtrack. |

### Discovery & naming rules

The ApplicationSet scans each layer at two depths:

- **`<layer>/<name>/`** → app `‹layer›-‹name›`, deployed to namespace `‹name›`.
- **`<layer>/<group>/<app>/`** → app `‹layer›-‹group›-‹app›`, deployed to namespace
  `‹group›` (the parent dir). E.g. `2-services/monitoring/librenms/` lands in the
  `monitoring` namespace.

Every discovered leaf directory **must contain a `kustomization.yaml`** (which may use
`helmCharts:` — `--enable-helm` is on). Sync policy is automated with `prune: true`,
`selfHeal: false`, server-side apply, and `CreateNamespace=true`. Changes take effect
only **after they are pushed** — Argo CD reconciles `HEAD` of `main`.

### Conventions for workload directories

- **Numeric file prefixes** (`01-…`, `10-…`, `31-…`) order how manifests are applied.
- **Image versions are pinned in `kustomization.yaml`** via the `images:`/`newTag`
  block — not in the Deployment manifests.
- **Databases via operators:** MariaDB apps use `MariaDB`/`Database`/`User`/`Grant` CRs
  (mariadb-operator); Postgres uses CNPG. Don't hand-roll DB StatefulSets.

### Secrets — SOPS + KSOPS

Secrets are committed **encrypted** as `*.sops.yaml`, encrypted with **age** via SOPS
(`.sops.yaml` defines recipients; only `data`/`stringData` are encrypted). Argo CD
decrypts them at apply time using the **KSOPS** kustomize plugin, installed into
`argocd-repo-server` by `1-system/argocd/argocd-repo-server-patch.yaml`.

Reference a secret through a **ksops generator**, not as a plain resource:

```yaml
# kustomization.yaml
generators:
  - 01-secret.yaml        # a viaduct.ai/v1 ksops manifest pointing at 01-secret.sops.yaml
```

Edit encrypted files with `sops <file>.sops.yaml` (requires the age private key locally).
See [`docs/openbao/sops-workflow.md`](docs/openbao/sops-workflow.md) for the full workflow.

---

## Cilium notes

Cilium replaces kube-proxy (`kubeProxyReplacement: true`, Talos
`k8sServiceHost: localhost`, port `7445`). BGP, Hubble, and the L7 proxy are enabled;
BGP peering is configured in `1-system/kube-system/cilium-bgp/bgp-config.yaml`. Cilium is
first installed as a Talos inline manifest at bootstrap, then managed in-cluster by Argo
CD from the chart at `1-system/kube-system/cilium/`.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture orientation for working in this repo.
- [`docs/openbao/`](docs/openbao/) — OpenBao operator runbook, user guide, SOPS
  workflow, and agent-injector examples.
