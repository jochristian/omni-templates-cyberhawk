#!/usr/bin/env bash
set -euo pipefail

BAO_EXEC="kubectl exec -n openbao openbao-0 --"

for var in BAO_ADDR BAO_TOKEN; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done
echo "✅ env vars set"

# --- Client signing ---

$BAO_EXEC bao secrets enable -path=ssh-client-signer ssh 2>/dev/null \
  || echo "ssh-client-signer already enabled"
echo "✅ ssh-client-signer enabled"

$BAO_EXEC bao write ssh-client-signer/config/ca generate_signing_key=true 2>/dev/null \
  || echo "Client CA already exists"
echo "✅ client signing CA configured"

$BAO_EXEC bao write ssh-client-signer/roles/human-access - <<'EOF'
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "allowed_extensions": "permit-pty,permit-port-forwarding,permit-agent-forwarding",
  "default_extensions": {"permit-pty": ""},
  "key_type": "ca",
  "default_user": "ubuntu",
  "ttl": "8h",
  "max_ttl": "24h"
}
EOF
echo "✅ role human-access created (TTL: 8h)"

$BAO_EXEC bao write ssh-client-signer/roles/gitlab-runner - <<'EOF'
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "git,ubuntu,deploy,root",
  "allowed_extensions": "",
  "default_extensions": {},
  "key_type": "ca",
  "default_user": "git",
  "ttl": "30m",
  "max_ttl": "1h"
}
EOF
echo "✅ role gitlab-runner created (TTL: 30m)"

# --- Host signing ---

$BAO_EXEC bao secrets enable -path=ssh-host-signer ssh 2>/dev/null \
  || echo "ssh-host-signer already enabled"
echo "✅ ssh-host-signer enabled"

$BAO_EXEC bao write ssh-host-signer/config/ca generate_signing_key=true 2>/dev/null \
  || echo "Host CA already exists"
echo "✅ host signing CA configured"

$BAO_EXEC bao secrets tune -max-lease-ttl=87600h ssh-host-signer
echo "✅ ssh-host-signer max-lease-ttl set to 87600h"

$BAO_EXEC bao write ssh-host-signer/roles/linux-hosts - <<'EOF'
{
  "key_type": "ca",
  "algorithm_signer": "rsa-sha2-256",
  "ttl": "87600h",
  "allow_host_certificates": true,
  "allowed_domains": "*.cyberhawk.no,*.upcloud.cyberhawk.no,*.netsecurity.no,localhost",
  "allow_subdomains": true
}
EOF
echo "✅ role linux-hosts created (TTL: 87600h)"

$BAO_EXEC bao policy write human-ssh - <<'EOF'
path "ssh-client-signer/sign/human-access" { capabilities = ["create","update"] }
EOF
echo "✅ policy human-ssh written"

$BAO_EXEC bao policy write host-signing - <<'EOF'
path "ssh-host-signer/sign/linux-hosts" { capabilities = ["create","update"] }
EOF
echo "✅ policy host-signing written"

echo ""
echo "===================================================="
echo "CLIENT SIGNING CA PUBLIC KEY"
echo "Add to /etc/ssh/trusted-user-ca-keys.pem on every target host."
echo "===================================================="
$BAO_EXEC bao read -field=public_key ssh-client-signer/config/ca

echo ""
echo "===================================================="
echo "HOST SIGNING CA PUBLIC KEY"
echo "Add to ~/.ssh/known_hosts on operator workstations:"
echo "@cert-authority *.cyberhawk.no <key>"
echo "===================================================="
$BAO_EXEC bao read -field=public_key ssh-host-signer/config/ca

echo ""
echo "⚠️  The CA keys above must be distributed to target hosts."
echo "   Run setup-target-host.sh on each target host."
