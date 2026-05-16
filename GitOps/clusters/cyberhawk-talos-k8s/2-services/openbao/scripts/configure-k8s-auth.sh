#!/usr/bin/env bash
set -euo pipefail

# Requires: BAO_ADDR, BAO_TOKEN set in environment
# Example: kubectl port-forward svc/openbao 8200:8200 -n openbao
#          export BAO_ADDR=http://127.0.0.1:8200
#          export BAO_TOKEN=<root-token>

for var in BAO_ADDR BAO_TOKEN; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done
echo "✅ env vars set"

BAO_EXEC="kubectl exec -i -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN"

$BAO_EXEC bao auth enable kubernetes 2>/dev/null || echo "kubernetes auth already enabled"
echo "✅ kubernetes auth enabled"

KUBE_CA=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d)
TOKEN=$(kubectl create token openbao-auth -n openbao --duration=8760h)
echo "✅ reviewer token created"

$BAO_EXEC bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert="$KUBE_CA" \
  token_reviewer_jwt="$TOKEN" \
  disable_local_ca_jwt=false
echo "✅ kubernetes auth configured"

$BAO_EXEC bao policy write kv-reader - <<'EOF'
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read","list"] }
EOF
echo "✅ policy kv-reader written"

$BAO_EXEC bao policy write db-creds-reader - <<'EOF'
path "database/creds/app-readonly"  { capabilities = ["read"] }
path "database/creds/app-readwrite" { capabilities = ["read"] }
path "sys/leases/renew"             { capabilities = ["update"] }
EOF
echo "✅ policy db-creds-reader written"

$BAO_EXEC bao policy write ssh-client-signer - <<'EOF'
path "ssh-client-signer/sign/gitlab-runner" { capabilities = ["create","update"] }
EOF
echo "✅ policy ssh-client-signer written"

$BAO_EXEC bao write auth/kubernetes/role/app-kv \
  bound_service_account_names="*" \
  bound_service_account_namespaces="3-apps,apps,default" \
  policies="kv-reader" \
  ttl=1h
echo "✅ role app-kv created"

$BAO_EXEC bao write auth/kubernetes/role/app-db \
  bound_service_account_names="*" \
  bound_service_account_namespaces="3-apps,apps" \
  policies="db-creds-reader" \
  ttl=1h
echo "✅ role app-db created"

$BAO_EXEC bao write auth/kubernetes/role/gitlab-runner-ssh \
  bound_service_account_names="gitlab-runner" \
  bound_service_account_namespaces="gitlab-runner" \
  policies="ssh-client-signer" \
  ttl=30m
echo "✅ role gitlab-runner-ssh created"

echo ""
echo "Kubernetes auth configured."
echo "Policies: kv-reader, db-creds-reader, ssh-client-signer"
echo "Roles: app-kv (3-apps,apps,default), app-db (3-apps,apps), gitlab-runner-ssh (gitlab-runner)"
