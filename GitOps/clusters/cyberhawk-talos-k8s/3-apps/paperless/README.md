# paperless-ngx

Document management. `https://paperless.cyberhawk.no` — public via pangolin/newt,
internal via the gateway VIP (both views come from the single `paperless` entry in
`CYBERHAWK_GATEWAY_APPS` in `2-services/dnscontrol/01-dnscontrol.sops.yaml`).

Structure follows `3-apps/netbox/`: CNPG Postgres + a per-app Valkey + one
application Deployment, all pinned to the **blix** zone because the iSCSI target
lives there.

## Volumes

| PVC | Class | Mode | Holds | Backed up |
|---|---|---|---|---|
| `paperless-data` | `democratic-csi-iscsi` | RWO | Whoosh index, classifier | no — rebuildable |
| `paperless-media` | `nfs-csi` | RWX | **the documents** | `paperless-media-backup`, 05:00 |
| `paperless-consume` | `nfs-csi` | RWX | drop folder | no — transient |
| `paperless-backup` | `democratic-csi-iscsi` | RWO | nightly `pg_dump` | `paperless-backup`, 05:30 |
| `paperless-valkey` | `democratic-csi-iscsi` | RWO | Celery broker AOF | no |

`media` is on NFS rather than iSCSI deliberately: an ext4-on-iSCSI mount flips to
permanent `emergency_ro` when the inter-site link blips, and does so *silently*
(the pod stays `Running`). NFS reconnects. The tradeoff is that `nfs-csi` has
`reclaimPolicy: Delete` while `democratic-csi-iscsi` has `Retain` — so an Argo
prune of this directory **destroys the documents**, and the restic snapshots are
the only thing that survives it.

Restore = `pg_restore` the dump into a fresh CNPG cluster, then restore
`paperless-media` from restic. The two ReplicationSources run 30 min apart on the
same night, and the `pg_dump` runs at 02:45, so any given night's pair is
self-consistent for anything not ingested between 02:45 and 05:00.

## The container runs as root

Unlike everything else in `3-apps/`. Both reasons are in the image's s6 init chain
and run before Django starts:

- `init-tesseract-langs` shells out to `apt-get install tesseract-ocr-nor` on
  **every** container start, because `PAPERLESS_OCR_LANGUAGES=nor` is set. This is
  why the rootfs is writable and why the egress policy allows `:80` — the Debian
  mirror is plain HTTP. Norwegian receipts OCR badly with `eng` alone, which is the
  whole reason this is turned on.
- `init-folders` chowns `data`/`media`/`consume` to `paperless:paperless`, which
  `init-modify-user` has remapped to `USERMAP_UID`/`USERMAP_GID` (1000:1000).

s6 drops to uid 1000 before anything binds `:8000`, so the Django process itself is
unprivileged. To go fully non-root later, drop `PAPERLESS_OCR_LANGUAGES` (bake the
language pack into a derived image instead), then set `runAsNonRoot: true`,
`runAsUser`/`runAsGroup: 1000` and `readOnlyRootFilesystem: true` in
`33-paperless-deployment.yaml`.

First boot is slow — APT install, then the full Django migration set. The startup
probe budget is 10 minutes.

## Gotchas

- **`enableServiceLinks: false` is load-bearing.** The Service is named `paperless`
  in namespace `paperless`, so the kubelet injects `PAPERLESS_PORT=tcp://<clusterIP>:8000`
  — and paperless-ngx reads `PAPERLESS_PORT` as the port granian binds. Turning the
  links back on gives you a pod that is `Running`, never restarts, and never listens:
  s6 respawns granian forever with `Invalid value for '--port'`, and the only visible
  symptom is a startup probe `connection refused`. Bit us on the very first sync.
  `PAPERLESS_PORT` is also pinned in `02-configmap.yaml` as a second line of defence.
  The general rule: any app whose config env prefix collides with a Service name in
  its own namespace needs this.
- **Probes must send an explicit `Host` header.** `PAPERLESS_ALLOWED_HOSTS` is
  pinned, and the kubelet probes with `Host: <podIP>` → Django 400 `DisallowedHost`.
  Keep the probe header and the configmap value in sync. Same trap as netbox and
  patchmon.
- **`PAPERLESS_CONSUMER_POLLING` is mandatory here.** The consume dir is NFS and
  inotify does not fire across it; without polling nothing dropped in is ingested.
- The public path needs a matching Pangolin resource configured on the pangolin
  side. The in-cluster half is the `newt` rule in `50-networkpolicies.yaml`.

## First-boot checklist

1. Log in as `admin` (password is `PAPERLESS_ADMIN_PASSWORD` in `01-secret.sops.yaml`).
2. Upload a Norwegian receipt, confirm the OCR text has æ/ø/å rather than mojibake.
   If it doesn't, check `[init-tesseract-langs]` in the pod log before anything else.
3. Change the admin password in the UI; the env var only seeds the account.
