# NetBox

NetBox runs at https://netbox.cyberhawk.no (`3-apps/netbox/`, Argo application
`3-apps-netbox`). It is the source of truth for sites, IPAM, devices and the
overlay topology.

## Deployment

Manifests live in `GitOps/clusters/cyberhawk-talos-k8s/3-apps/netbox/`. Notable
choices, all commented in place:

- **Postgres via CNPG** (`netbox-db`), **one Valkey** with DB 0 for the RQ task
  queue and DB 1 for the cache — the layout NetBox's own
  `configuration.example.py` uses.
- **Media on `nfs-csi` (RWX)**, shared by the web and worker pods. The pods run
  with `runAsGroup: 999` because the NFS server ignores the client's
  supplementary group list, so `fsGroup` alone leaves the volume read-only.
- **Probes send an explicit `Host` header** — NetBox enforces `ALLOWED_HOSTS`
  and the kubelet otherwise probes with `Host: <podIP>`.
- **`/metrics` is redirected at the HTTPRoute.** NetBox 4.x applies
  `LOGIN_REQUIRED` per view and django-prometheus's endpoint is not one of them,
  so it would be world-readable through the gateway. Prometheus scrapes the
  ClusterIP directly and is unaffected.

Two backup streams, both to restic on Hetzner: `netbox-backup` (nightly
`pg_dump` at 02:30, replicated 04:45) and `netbox-media-backup` (04:00).

## Populating it

The discovery-and-seed tooling lives **outside this repository**, in
`~/netbox-seed`, and is deliberately not committed: its `facts/` directory holds
a complete map of the network — BGP peers, WireGuard endpoints, MAC addresses
and every internal prefix — which does not belong in a public repo. See
`~/netbox-seed/README.md` for the full workflow.

Short version:

```bash
cd ~/netbox-seed
python3 collect/vyos.py --target <user>@<router> --name <router>   # and the other collectors
python3 reconcile.py
NETBOX_TOKEN=... python3 seed.py --dry-run
```

**The seed is never run by Argo.** It is a bootstrap and a disaster-recovery
path; after seeding, NetBox itself is authoritative and you edit it in the UI.

Because the tooling is not in git, `~/netbox-seed` is a single point of failure —
back it up, or keep it in the private repo.

## Gotchas

- **The superuser API token in `01-secret.sops.yaml` is inert.** netbox-docker's
  `super_user.py` exits early when the user already exists, and `admin` was
  created on first boot before `API_TOKEN_PEPPER_1` was set. Mint tokens in the
  UI. The token/key pair in the secret only applies to a fresh-database rebuild.
- **First-boot migrations take over 11 minutes** on worker-02 (~300 migrations).
  The startup probe budget is 30 minutes for that reason. Overshooting it is not
  destructive — Django commits per migration and the entrypoint resumes — but it
  costs a restart cycle.
- **v2 API tokens need a pepper.** Without `API_TOKEN_PEPPER_1` NetBox logs
  `API_TOKEN_PEPPERS is not defined` and refuses to create them.

## Related runbooks

- `docs/dnscontrol/` — DNS; `netbox` is in `CYBERHAWK_GATEWAY_APPS`, so it
  resolves to the gateway VIP on the LAN and to Pangolin publicly.
