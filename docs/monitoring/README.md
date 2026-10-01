# Observability stack (`2-services/monitoring/` + `1-system/tetragon/`)

Moved out of the repo-root `CLAUDE.md` to keep its per-message size down. Read this before editing anything under `2-services/monitoring/` or `1-system/tetragon/`.

- **Metrics:** `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager). Grafana
  uses anonymous auth and provisions datasources via the chart's `additionalDataSources`
  (Prometheus is the chart default — do **not** redeclare it, that broke all dashboards
  once) plus a `Loki` datasource. Latest stable is tracked (kps/grafana/loki/alloy).
- **Logs:** single-binary **Loki** (`loki/`, filesystem on iSCSI) + **Grafana Alloy**
  (`alloy/`, single Deployment) which tails the Tetragon `export-stdout` sidecar over the
  K8s API and pushes to Loki. Durable across pod/node restarts (the agents' export dir is
  an emptyDir).
- **Dashboards:** `dashboards/` — each JSON is wired in via a `configMapGenerator` entry
  labelled `grafana_dashboard: "1"` (Grafana sidecar auto-loads it). `servicemonitors.yaml`
  holds the hand-written ServiceMonitor/PodMonitors (argocd, cilium-agent, cilium-operator).
  Official Cilium **agent/operator** + **Hubble** dashboards and custom **Tetragon** and
  **Gatus** dashboards (the latter bound to `gatus_*` metrics) live here.
- **Uptime/status:** **Gatus** (`gatus/`, config-as-code, no admin UI — edit `config.yaml`,
  the `configMapGenerator` hash rolls the pod). sqlite history on iSCSI, exposed via Omni
  workload proxy `:50083`, `release: monitoring` ServiceMonitor feeds `gatus_*` into
  Prometheus. Checks are grouped `cyberhawk-talos-k8s (cluster)` / `External hosts` /
  `Internet / DNS`. **Probe user apps via their public hostname, not internal Services** —
  user apps (karakeep, …) carry `allow-external-deny-internal` CiliumNetworkPolicies,
  so a monitoring→app Service probe is denied (false "down"). ICMP checks need `NET_RAW`
  on the pod (otherwise it's drop-ALL caps / non-root / RO-rootfs).
- **Runtime security:** **Tetragon** (`1-system/tetragon/`) runs **observe-only**
  (monitor-mode TracingPolicies, `Post` action only — never enforcement). `tetra`/Loki
  viewer: `docs/tetragon/policy-matches.sh` (`--loki` reads durable history).

## Monitoring gotchas (these cause silent "No data" / OutOfSync)

- **No blanket `namespace:` transformer in the kps kustomization.** Helm already
  namespaces every resource; a top-level `namespace: monitoring` rewrites the
  `kube-system` exporter Services (coredns/kube-controller-manager/scheduler/etcd/proxy)
  into `monitoring`, leaving them with no endpoints.
- **Scrape selection:** a ServiceMonitor/PodMonitor is only scraped if it carries the
  label `release: monitoring`. Any `relabelings` must pin `action: replace` (CRD default)
  or the app sits OutOfSync. Official Cilium dashboards filter on `k8s_app="cilium"` /
  `io_cilium_app="operator"`, so the monitors relabel those pod labels onto the metrics.
- **etcd** is scraped via `prometheus.prometheusSpec.additionalScrapeConfigs` (static
  config, job `kube-etcd`, http `:2381`) — **not** the chart's Service+Endpoints, because
  ArgoCD's `resource.exclusions` drops `Endpoints`/`EndpointSlice`. Control-plane IPs:
  ctrl-00 `10.50.1.50` (blix), ctrl-01 `10.50.1.51` (blix), ctrl-02 `192.168.155.10`
  (lørenskog). Sites by subnet: blix `10.50.1.0/24`, lørenskog `192.168.155.0/24`
  (worker-01 `192.168.155.100` is lørenskog).
- **kps major upgrades:** apply the chart CRDs out-of-band first (`kubectl apply
  --server-side`), else ArgoCD wedges at sync status `Unknown` with a `ComparisonError`
  on new CR fields.
