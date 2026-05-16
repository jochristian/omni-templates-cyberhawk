#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/generate-tls.sh > /tmp/openbao-tls.yaml
#   # Review the output, then:
#   cp /tmp/openbao-tls.yaml 2-services/openbao/openbao-tls.sops.yaml
#   sops --encrypt --in-place 2-services/openbao/openbao-tls.sops.yaml
#   rm /tmp/openbao-tls.yaml

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CA_KEY="$TMPDIR/ca.key"
CA_CERT="$TMPDIR/ca.crt"
SERVER_KEY="$TMPDIR/server.key"
SERVER_CSR="$TMPDIR/server.csr"
SERVER_CERT="$TMPDIR/server.crt"
EXT_FILE="$TMPDIR/san.ext"

cat > "$EXT_FILE" <<'EOF'
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = openbao-0.openbao-internal.openbao.svc.cluster.local
DNS.2 = openbao-1.openbao-internal.openbao.svc.cluster.local
DNS.3 = openbao-2.openbao-internal.openbao.svc.cluster.local
DNS.4 = openbao.openbao.svc.cluster.local
DNS.5 = openbao.openbao.svc
DNS.6 = openbao
DNS.7 = localhost
IP.1  = 127.0.0.1
EOF

# Generate CA
openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
openssl req -new -x509 -days 3650 -key "$CA_KEY" -out "$CA_CERT" \
  -subj "/CN=openbao-ca/O=cyberhawk" 2>/dev/null

# Generate server key and CSR
openssl genrsa -out "$SERVER_KEY" 4096 2>/dev/null
openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" \
  -subj "/CN=openbao/O=cyberhawk" 2>/dev/null

# Sign CSR with CA
openssl x509 -req -days 3650 \
  -in "$SERVER_CSR" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -extfile "$EXT_FILE" -extensions v3_req \
  -out "$SERVER_CERT" 2>/dev/null

# Bundle: server cert + CA cert (full chain) in tls.crt
CHAIN="$(cat "$SERVER_CERT" "$CA_CERT")"
TLS_CRT="$(printf '%s' "$CHAIN" | base64 | tr -d '\n')"
TLS_KEY="$(base64 < "$SERVER_KEY" | tr -d '\n')"

cat <<YAML
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: openbao-tls
  namespace: openbao
data:
  tls.crt: ${TLS_CRT}
  tls.key: ${TLS_KEY}
YAML
