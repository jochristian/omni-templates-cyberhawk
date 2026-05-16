#!/usr/bin/env bash
set -euo pipefail

# ⚠️  Edit this script and replace all CHANGE_ME values before running.
# ⚠️  rotate-root is irreversible — OpenBao becomes sole owner of vault admin password.

BAO_EXEC="kubectl exec -n openbao openbao-0 --"

for var in BAO_ADDR BAO_TOKEN BAO_CACERT; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done
echo "✅ env vars set"

if grep -q "CHANGE_ME" "$0"; then
  echo "ERROR: Edit this script and replace all CHANGE_ME values before running."
  exit 1
fi
echo "✅ no placeholders found"

$BAO_EXEC bao secrets enable database 2>/dev/null \
  || echo "database engine already enabled"
echo "✅ database engine enabled"

$BAO_EXEC bao write database/config/postgres-main \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@CHANGE_ME_POSTGRES_HOST:5432/CHANGE_ME_DB_NAME?sslmode=require" \
  allowed_roles="app-readonly,app-readwrite,app-admin" \
  username="CHANGE_ME_VAULT_ADMIN_USER" \
  password="CHANGE_ME_VAULT_ADMIN_PASS"
echo "✅ postgres-main connection configured"

echo ""
echo "⚠️  About to rotate root credentials for postgres-main."
echo "⚠️  After this, the password in this script is no longer valid."
echo "⚠️  OpenBao becomes the sole owner of the vault admin credentials."
read -rp "Confirm rotate-root? [type ROTATE to continue]: " CONFIRM
[[ "$CONFIRM" == "ROTATE" ]] || { echo "Aborted."; exit 1; }
$BAO_EXEC bao write -force database/rotate-root/postgres-main
echo "✅ postgres-main root credentials rotated"

$BAO_EXEC bao write database/roles/app-readonly \
  db_name=postgres-main \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h
echo "✅ role app-readonly created (TTL: 1h)"

$BAO_EXEC bao write database/roles/app-readwrite \
  db_name=postgres-main \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h
echo "✅ role app-readwrite created (TTL: 1h)"

$BAO_EXEC bao write database/roles/app-admin \
  db_name=postgres-main \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE CHANGE_ME_DB_NAME TO \"{{name}}\";" \
  default_ttl=15m \
  max_ttl=30m
echo "✅ role app-admin created (TTL: 15m)"

$BAO_EXEC bao policy write db-creds-reader - <<'EOF'
path "database/creds/app-readonly"  { capabilities = ["read"] }
path "database/creds/app-readwrite" { capabilities = ["read"] }
path "sys/leases/renew"             { capabilities = ["update"] }
EOF
echo "✅ policy db-creds-reader updated"

$BAO_EXEC bao policy write db-admin - <<'EOF'
path "database/creds/app-admin" { capabilities = ["read"] }
path "sys/leases/renew"         { capabilities = ["update"] }
EOF
echo "✅ policy db-admin written"

$BAO_EXEC bao write auth/kubernetes/role/db-admin-migration \
  bound_service_account_names="migration-runner" \
  bound_service_account_namespaces="3-apps,apps" \
  policies="db-admin" \
  ttl=30m
echo "✅ role db-admin-migration created"

echo ""
echo "Testing dynamic credential generation..."
$BAO_EXEC bao read database/creds/app-readonly
echo "✅ test credential issued successfully"
