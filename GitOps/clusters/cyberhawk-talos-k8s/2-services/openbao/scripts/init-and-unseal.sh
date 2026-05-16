#!/usr/bin/env bash
set -euo pipefail

# WARNING: Run this script ONLY on a fresh, uninitialized OpenBao cluster.
# Verify state first: kubectl exec -n openbao openbao-0 -- bao status

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq not found (brew install jq / apt install jq)"; exit 1; }

kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster not reachable"; exit 1; }

PODS=(openbao-0 openbao-1 openbao-2)

echo "Checking pod states..."
for pod in "${PODS[@]}"; do
  phase=$(kubectl get pod -n openbao "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
  if [[ "$phase" != "Running" ]]; then
    echo "ERROR: Pod $pod is not Running (phase: $phase). Ensure all pods are Running before init."
    exit 1
  fi
done
echo "All pods Running."

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

for pod in "${PODS[@]}"; do
  echo ""
  echo "Unsealing $pod..."
  read -rsp "  Key 1: " UNSEAL_KEY1; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY1" >/dev/null
  read -rsp "  Key 2: " UNSEAL_KEY2; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY2" >/dev/null
  read -rsp "  Key 3: " UNSEAL_KEY3; echo
  kubectl exec -n openbao "$pod" -- bao operator unseal "$UNSEAL_KEY3" >/dev/null

  SEALED=$(kubectl exec -n openbao "$pod" -- bao status -format=json 2>/dev/null \
    | jq -r '.sealed')
  if [[ "$SEALED" == "false" ]]; then
    echo "  ✅ $pod is unsealed"
  else
    echo "  ❌ $pod is still sealed — check keys"
  fi
done

echo ""
echo "Initialization complete. Next steps:"
echo "  1. Update openbao-unseal-keys.sops.yaml with keys 1-3 and the root token"
echo "  2. sops --encrypt --in-place 2-services/openbao/openbao-unseal-keys.sops.yaml"
echo "  3. git commit and push"
echo "  4. export BAO_TOKEN=$ROOT_TOKEN"
echo "  5. Run configure-k8s-auth.sh then configure-kv-engine.sh, configure-ssh-engine.sh, configure-db-engine.sh"
echo "  6. Revoke the root token when bootstrapping is complete: bao token revoke <token>"
