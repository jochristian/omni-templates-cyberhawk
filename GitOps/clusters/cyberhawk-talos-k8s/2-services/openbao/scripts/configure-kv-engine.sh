#!/usr/bin/env bash
set -euo pipefail

# Secret path convention: secret/<namespace>/<app>/<key>
# Example: secret/3-apps/portfolio/db-password

for var in BAO_ADDR BAO_TOKEN; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done
echo "✅ env vars set"

BAO_EXEC="kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN"

$BAO_EXEC bao secrets enable -path=secret -version=2 kv 2>/dev/null \
  || echo "KV v2 at secret/ already enabled"
echo "✅ KV v2 enabled at secret/"

$BAO_EXEC bao policy write kv-reader - <<'EOF'
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read","list"] }
EOF
echo "✅ kv-reader policy updated"

echo ""
echo "KV v2 configured. Write secrets with:"
echo "  bao kv put secret/<namespace>/<app>/<key> value=<val>"
