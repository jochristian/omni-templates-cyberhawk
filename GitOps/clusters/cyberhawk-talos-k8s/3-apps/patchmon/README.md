# PatchMon

Linux patch monitoring, running **2.0.2**. Migrated from a Docker Compose deployment on
2026-07-31, upgrading 1.4.2 → 2.0.2 in the same cutover.

## Shape

A single container (`ghcr.io/patchmon/patchmon-server`) — the React frontend, the agent
binaries and the SCAP compliance content are all embedded in the Go binary, so there are
**no application PVCs**. Background jobs run on Asynq against a per-app Valkey; data lives
in a per-app CNPG PostgreSQL 17 cluster.

```
Deployment patchmon           1 replica, Recreate, zone=blix, nonroot 65532, RO rootfs
Deployment patchmon-valkey    + 1Gi PVC   (Asynq job queue)
Cluster    patchmon-db        5Gi iSCSI, PG 17
CronJob    patchmon-db-dump   03:15 -> patchmon-backup PVC -> VolSync 05:15 -> S3
Service patchmon:3000 <- HTTPRoute patchmon.cyberhawk.no <- cilium-gateway
```

## Gotchas

- **The health probes must send an explicit `Host` header.** PatchMon 2.0.2 enforces a Host
  allowlist and answers **403** to anything it does not recognise. The kubelet probes with
  `Host: <podIP>`, which is rejected, so without the `httpGet.httpHeaders` entry in
  `30-deployment.yaml` the pod never becomes Ready and Argo CD sits Progressing forever.
  Measured on a live pod: Host `127.0.0.1` → 200, Host `<podIP>` → **403**, Host
  `patchmon.cyberhawk.no` → 200. Upstream never hits this because their Docker
  `HEALTHCHECK` runs *inside* the container against localhost. Keep the header value in
  sync with `CORS_ORIGIN`. Real traffic is unaffected — the gateway forwards the correct
  Host from the HTTPRoute hostname.
- **`runAsUser: 65532` is mandatory.** The image declares `USER nonroot` as a *name*, and
  the kubelet cannot verify a non-numeric image user against `runAsNonRoot` — omitting the
  uid gives `CreateContainerConfigError`.
- **The Valkey password lives in two secrets** — `REDIS_PASSWORD` in `patchmon-secret` and
  `requirepass` in `patchmon-valkey-config`. They must be changed together; a mismatch
  fails at connect time, not at sync time.
- **The backup CronJob needs its own network-policy grant.** `50-networkpolicies.yaml`
  admits port 5432 from both `app: patchmon` and `app: patchmon-db-dump`. Dropping the
  second selector silently breaks backups — the job hangs, fails, and VolSync then
  replicates an empty PVC.
- **`TRUST_PROXY` is deliberately unset.** 2.0.2 defaults it to `true`, which is correct
  behind a reverse proxy. Setting it to `false` breaks OIDC and client IPs.
- **The public URL is database-backed**, in the `settings` table, not in the ConfigMap.
  Change it in Settings → Server, not in Git.
- **Exposure is split-horizon** via dnscontrol: the external view goes through the tunnel,
  the internal view resolves straight to the cluster gateway. The tunnel's resource target
  is configured outside Git.
- **2.0 dropped the 1.4.x volumes.** No agent-binary or branding-asset volume is needed:
  agents are served from the image and custom logos are stored in the database.

## Backups

`patchmon-db-dump` writes `pg_dump -Fc` output to the `patchmon-backup` PVC at 03:15 daily,
keeping the 7 most recent, and `chmod 0644`s each file so the VolSync mover (uid 1000) can
read what the job (uid 26) wrote. VolSync replicates that PVC to S3 at 05:15.

Restore is `pg_restore` **as `patchmon_user`** — restoring as the `postgres` superuser
leaves every object owned by the wrong role.

The restic password for `s3-backup-hetzner-patchmon` exists **only** in
`62-volsync-secret.sops.yaml`. Without it the backups cannot be restored:

```bash
sops -d 62-volsync-secret.sops.yaml
```

Trigger an out-of-band backup with:

```bash
kubectl -n patchmon create job --from=cronjob/patchmon-db-dump patchmon-db-dump-manual
```

## Upgrading from 1.4.x

Handled automatically: golang-migrate replaced Prisma in 2.0, and its first migration is
written entirely as `CREATE TABLE IF NOT EXISTS` specifically so an existing Prisma
database migrates in place. Observed on this cluster: version 0 → 40, tables 33 → 45.
Restore the old dump, then start 2.0.2 against it.
