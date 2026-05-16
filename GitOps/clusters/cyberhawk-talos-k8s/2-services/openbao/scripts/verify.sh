#!/usr/bin/env bash
set -euo pipefail

BAO_EXEC="kubectl exec -n openbao openbao-0 --"
PASS=0
FAIL=0

check() {
  local num="$1" name="$2"
  printf "Check %2d: %-55s " "$num" "$name"
}
ok()   { echo "✅"; ((PASS++)) || true; }
fail() { echo "❌ ${*}"; ((FAIL++)) || true; }

for var in BAO_ADDR BAO_TOKEN BAO_CACERT; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is not set"; exit 1; }
done

# Infrastructure
check 1 "openbao-0 Running and Ready"
kubectl get pod -n openbao openbao-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running \
  && kubectl get pod -n openbao openbao-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true \
  && ok || fail

check 2 "openbao-1 Running and Ready"
kubectl get pod -n openbao openbao-1 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running \
  && kubectl get pod -n openbao openbao-1 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true \
  && ok || fail

check 3 "openbao-2 Running and Ready"
kubectl get pod -n openbao openbao-2 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running \
  && kubectl get pod -n openbao openbao-2 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true \
  && ok || fail

check 4 "openbao-0 Initialized: true"
$BAO_EXEC bao status -format=json 2>/dev/null | grep -q '"initialized":true' && ok || fail

check 5 "openbao-0 Sealed: false"
$BAO_EXEC bao status -format=json 2>/dev/null | grep -q '"sealed":false' && ok || fail

check 6 "openbao-1 Sealed: false"
kubectl exec -n openbao openbao-1 -- bao status -format=json 2>/dev/null | grep -q '"sealed":false' && ok || fail

check 7 "openbao-2 Sealed: false"
kubectl exec -n openbao openbao-2 -- bao status -format=json 2>/dev/null | grep -q '"sealed":false' && ok || fail

# Auth methods
check 8 "kubernetes/ auth method enabled"
$BAO_EXEC bao auth list -format=json 2>/dev/null | grep -q '"kubernetes/"' && ok || fail

check 9 "role app-kv exists"
$BAO_EXEC bao read auth/kubernetes/role/app-kv >/dev/null 2>&1 && ok || fail

# Secret engines
check 10 "secret/ (KV v2) enabled"
$BAO_EXEC bao secrets list -format=json 2>/dev/null | grep -q '"secret/"' && ok || fail

check 11 "ssh-client-signer/ enabled"
$BAO_EXEC bao secrets list -format=json 2>/dev/null | grep -q '"ssh-client-signer/"' && ok || fail

check 12 "database/ enabled"
$BAO_EXEC bao secrets list -format=json 2>/dev/null | grep -q '"database/"' && ok || fail

# SSH CA
check 13 "role human-access exists"
$BAO_EXEC bao read ssh-client-signer/roles/human-access >/dev/null 2>&1 && ok || fail

check 14 "role gitlab-runner exists"
$BAO_EXEC bao read ssh-client-signer/roles/gitlab-runner >/dev/null 2>&1 && ok || fail

check 15 "client CA public key readable"
$BAO_EXEC bao read -field=public_key ssh-client-signer/config/ca >/dev/null 2>&1 && ok || fail

# SSH end-to-end signing
TMPKEY=$(mktemp /tmp/verify-ssh-XXXXXX)
trap 'rm -f "$TMPKEY" "${TMPKEY}.pub" "${TMPKEY}-cert.pub"' EXIT

check 16 "generate temp ed25519 keypair"
ssh-keygen -t ed25519 -f "$TMPKEY" -N "" -q 2>/dev/null && ok || fail

check 17 "sign temp key (TTL: 1m)"
$BAO_EXEC bao write -field=signed_key \
  ssh-client-signer/sign/human-access \
  public_key="$(cat "${TMPKEY}.pub")" \
  ttl=1m > "${TMPKEY}-cert.pub" 2>/dev/null && ok || fail

check 18 "signed cert has permit-pty extension"
ssh-keygen -Lf "${TMPKEY}-cert.pub" 2>/dev/null | grep -q "permit-pty" && ok || fail

# Database
check 19 "role app-readonly exists"
$BAO_EXEC bao read database/roles/app-readonly >/dev/null 2>&1 && ok || fail

check 20 "read test credential from app-readonly"
$BAO_EXEC bao read -format=json database/creds/app-readonly 2>/dev/null | grep -q '"username"' && ok || fail

echo ""
echo "$((PASS + FAIL)) checks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
