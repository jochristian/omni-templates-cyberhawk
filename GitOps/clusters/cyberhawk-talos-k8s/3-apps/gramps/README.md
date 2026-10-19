# Gramps Web

Genealogy. `https://gramps.cyberhawk.no`: public via pangolin/newt, internal via
the gateway VIP (the `gramps` entry in `CYBERHAWK_GATEWAY_APPS` in
`2-services/dnscontrol/01-dnscontrol.sops.yaml`). The public path also needs a
Pangolin resource pointing at `gramps.gramps.svc:5000`.

## Layout

One pod, three containers: `grampsweb` (gunicorn, :5000), `celery` (background
tasks) and `valkey` (broker, loopback only, no persistence). Celery is required:
tree schema upgrades without a task queue can corrupt the tree.

All state is SQLite plus files on one PVC, `gramps-data` (`democratic-csi-iscsi`,
RWO), split by subPath: `grampsdb` (tree), `users` (user DB), `indexdir` (search
index), `media`. SQLite on NFS breaks on locking, hence iSCSI, hence the blix pin.
Caches and `/tmp` are emptyDirs.

Registration is disabled and there is no SMTP: the owner creates accounts and
resets passwords in the UI. The first visit with an empty user DB runs the
onboarding wizard, which creates the owner account.

## Backup

VolSync `gramps-backup` snapshots `gramps-data` at 05:15 to
`s3-backup-hetzner-gramps`. restic copies the live SQLite files, so a snapshot
taken mid-write can be inconsistent. Writes are rare, but before an upgrade or a
big edit also take a Gramps XML export (Export > "Gramps XML (family tree)").

## Upgrades

Renovate bumps `ghcr.io/gramps-project/grampsweb` in `kustomization.yaml`. Read
the Gramps Web API release notes first. A bump that changes the tree schema shows
an "Upgrade Family Tree" screen on first login; export the tree before clicking it.
