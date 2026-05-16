#!/usr/bin/env bash
set -euo pipefail

# WARNING: Run this script ONLY on a fresh, uninitialized OpenBao cluster.
# Verify state first: kubectl exec -n openbao openbao-0 -- bao status
#
# StatefulSet behaviour: pods start sequentially — pod N only starts after pod N-1
# is Ready (unsealed). This script handles that by waiting for each pod before unsealing.

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq not found (brew install jq / apt install jq)"; exit 1; }

kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster not reachable"; exit 1; }

wait_for_pod_running() {
  local pod="$1"
  echo "Waiting for $pod to be Running..."
  local attempts=0
  until kubectl get pod -n openbao "$pod" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    ((attempts++))
    if [[ $attempts -ge 60 ]]; then
      echo "ERROR: $pod did not reach Running state after 5 minutes"
      exit 1
    fi
    sleep 5
  done
  echo "  $pod is Running."
}

unseal_pod() {
  local pod="$1"
  echo ""
  echo "Unsealing $pod..."
  read -rsp "  Key 1: " UNSEAL_KEY1; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY1" >/dev/null
  read -rsp "  Key 2: " UNSEAL_KEY2; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY2" >/dev/null
  read -rsp "  Key 3: " UNSEAL_KEY3; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY3" >/dev/null

  local sealed
  sealed=$(kubectl exec -n openbao "$pod" -- bao status -format=json 2>/dev/null | jq -r '.sealed')
  if [[ "$sealed" == "false" ]]; then
    echo "  ✅ $pod is unsealed"
  else
    echo "  ❌ $pod is still sealed — check keys"
    exit 1
  fi
}

# With Parallel pod management, all 3 pods start simultaneously.
# Wait for all 3 before init so Raft can form quorum (2/3) and elect a leader.
wait_for_pod_running openbao-0
wait_for_pod_running openbao-1
wait_for_pod_running openbao-2

echo "Giving Raft 10 seconds to elect a leader..."
sleep 10

echo "Checking initialization state..."
STATUS=$(kubectl exec -n openbao openbao-0 -- bao status -format=json 2>/dev/null || echo '{"initialized":false}')
INITIALIZED=$(echo "$STATUS" | jq -r '.initialized')

if [[ "$INITIALIZED" == "true" ]]; then
  echo "ERROR: OpenBao is already initialized. This script is for first-time init only."
  exit 1
fi

echo "Initializing OpenBao with 5 shares, threshold 3..."
INIT_OUTPUT=$(kubectl exec -n openbao openbao-0 -- bao operator init \
  -key-shares=5 -key-threshold=3 -format=json)

KEY1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
KEY2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
KEY3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
KEY4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
KEY5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo ""
echo "=========================================="
echo "UNSEAL KEYS (save all 5 securely NOW):"
echo "Key 1: $KEY1"
echo "Key 2: $KEY2"
echo "Key 3: $KEY3"
echo "Key 4: $KEY4"
echo "Key 5: $KEY5"
echo ""
echo "ROOT TOKEN (save securely NOW):"
echo "$ROOT_TOKEN"
echo "=========================================="
echo ""

read -rp "Have you saved the unseal keys and root token in a secure location? [type YES to continue]: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborted. Re-run when ready."
  exit 1
fi

# All pods are already Running (Parallel management). Unseal sequentially.
unseal_pod openbao-0
unseal_pod openbao-1
unseal_pod openbao-2

echo ""
echo "=========================================="
echo "Initialization complete. Next steps:"
echo "  1. Update openbao-unseal-keys.sops.yaml with keys 1-3 and the root token"
echo "  2. sops 2-services/openbao/openbao-unseal-keys.sops.yaml  (opens in editor)"
echo "  3. git add openbao-unseal-keys.sops.yaml && git commit && git push"
echo "  4. export BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200"
echo "  5. export BAO_TOKEN=$ROOT_TOKEN"
echo "  6. kubectl get secret -n openbao openbao-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/openbao-tls.crt"
echo "  7. export BAO_CACERT=/tmp/openbao-tls.crt"
echo "  8. Run configure scripts: configure-k8s-auth.sh → configure-kv-engine.sh → configure-ssh-engine.sh"
echo "  9. Edit configure-db-engine.sh (replace CHANGE_ME), then run it"
echo " 10. bash scripts/verify.sh"
echo " 11. Revoke root token: bao token revoke \$BAO_TOKEN"
echo "=========================================="
