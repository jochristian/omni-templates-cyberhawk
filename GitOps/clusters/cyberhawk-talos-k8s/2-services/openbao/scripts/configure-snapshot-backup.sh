#!/usr/bin/env bash
set -euo pipefail

# Requires: BAO_ADDR, BAO_TOKEN set in environment
# Example: kubectl port-forward svc/openbao 8200:8200 -n openbao
#          export BAO_ADDR=http://127.0.0.1:8200
#          export BAO_TOKEN=<root-token>
#
# Grants the openbao-snapshot ServiceAccount (openbao namespace) permission
# to take raft snapshots — used by the openbao-snapshot CronJob.

for var in BAO_ADDR BAO_TOKEN; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done
echo "✅ env vars set"

BAO_EXEC="kubectl exec -i -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN"

$BAO_EXEC bao policy write raft-snapshot - <<'EOF'
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
EOF
echo "✅ policy raft-snapshot written"

$BAO_EXEC bao write auth/kubernetes/role/raft-snapshot \
  bound_service_account_names="openbao-snapshot" \
  bound_service_account_namespaces="openbao" \
  policies="raft-snapshot" \
  ttl=15m
echo "✅ role raft-snapshot created"

echo "Done. Test with:"
echo "  kubectl create job -n openbao --from=cronjob/openbao-snapshot snapshot-test"
