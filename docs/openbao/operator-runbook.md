# OpenBao Operator Runbook — cyberhawk cluster

OpenBao runs as a 3-node Raft HA cluster in the `openbao` namespace, deployed via the
Helm chart in `2-services/openbao/` (kustomize `helmCharts:` + `openbao-values.yaml`).

**Key facts about the current deployment:**

- **TLS is disabled** (`tlsDisable: true`). Listeners and all clients speak **HTTP** on
  port 8200. The in-cluster scripts talk to `http://127.0.0.1:8200` via `kubectl exec`.
- **Auto-unseal is enabled** via a `seal "static"` stanza. The key is delivered as the
  env var `BAO_STATIC_UNSEAL_KEY`, sourced from the SOPS-managed `openbao-static-unseal`
  Secret. Pods **unseal themselves automatically on restart** — no manual unseal needed
  in normal operation. The Shamir keys in `openbao-unseal-keys.sops.yaml` remain as
  **recovery keys** only.
- Both `openbao-unseal-keys.sops.yaml` and `openbao-static-unseal.sops.yaml` are
  decrypted into the cluster by KSOPS via `ksops-generator.yaml`.

> ⚠️ **Unrecoverable-loss warning:** if the static unseal key **and** the SOPS age key
> are both lost, the cluster cannot be unsealed — even from a Raft snapshot. Keep the age
> key backed up.

---

## 1. First-time deployment

```bash
cd GitOps/clusters/cyberhawk-talos-k8s

# Step 1: generate the static unseal key, store it encrypted
KEY=$(openssl rand -base64 32)
cat > 2-services/openbao/openbao-static-unseal.sops.yaml <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: openbao-static-unseal
  namespace: openbao
stringData:
  BAO_STATIC_UNSEAL_KEY: "$KEY"
EOF
sops --encrypt --in-place 2-services/openbao/openbao-static-unseal.sops.yaml

# Step 2: commit and sync (the unseal-keys stub is already encrypted)
git add 2-services/openbao/ 1-system/namespaces/
git commit -m "feat(openbao): deploy" && git push
# Argo CD syncs automatically — wait for the 3 pods to be Running

# Step 3: initialize (ONE TIME ONLY) — with static seal, init returns recovery keys
bash 2-services/openbao/scripts/init-and-unseal.sh
# Save all keys + root token. Fill openbao-unseal-keys.sops.yaml (recovery keys + root):
sops 2-services/openbao/openbao-unseal-keys.sops.yaml
git add 2-services/openbao/openbao-unseal-keys.sops.yaml
git commit -m "feat(openbao): store recovery keys" && git push

# Step 4: env for the configure scripts (HTTP via port-forward)
kubectl port-forward svc/openbao -n openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<root-token-from-init>

# Step 5: configure engines (in order)
bash 2-services/openbao/scripts/configure-k8s-auth.sh
bash 2-services/openbao/scripts/configure-kv-engine.sh
bash 2-services/openbao/scripts/configure-ssh-engine.sh
# Edit configure-db-engine.sh: replace all CHANGE_ME values, then:
bash 2-services/openbao/scripts/configure-db-engine.sh

# Step 6: verify everything
bash 2-services/openbao/scripts/verify.sh

# Step 7: distribute SSH CA keys to each target host
CLIENT_CA=$(kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao read -field=public_key ssh-client-signer/config/ca)
HOST_CA=$(kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao read -field=public_key ssh-host-signer/config/ca)
# On each target host:
sudo bash 2-services/openbao/scripts/setup-target-host.sh \
  --client-ca-key "$CLIENT_CA" --host-ca-key "$HOST_CA"

# Step 8: revoke the root token
bao token revoke "$BAO_TOKEN"
```

## 2. Daily operator workflow (SSH access)

```bash
kubectl port-forward svc/openbao -n openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=$(bao login -method=userpass username=<user> -field=token)
bash 2-services/openbao/scripts/ssh-sign.sh
ssh -i ~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519 ubuntu@<host>
```

## 3. Unseal recovery (auto-unseal failed)

Normally pods auto-unseal on restart from the static key. You only do this if the static
seal is unavailable (e.g. the `openbao-static-unseal` Secret was lost and you must fall
back to the Shamir recovery keys):

```bash
# Decrypt the recovery keys
sops --decrypt 2-services/openbao/openbao-unseal-keys.sops.yaml

# Unseal each pod with the threshold of recovery keys
for pod in openbao-0 openbao-1 openbao-2; do
  kubectl exec -n openbao $pod -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal <key-1>
  kubectl exec -n openbao $pod -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal <key-2>
  kubectl exec -n openbao $pod -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal <key-3>
done
```

## 4. Adding a new KV secret for an app

```bash
# Convention: secret/<namespace>/<app>/<key>
bao kv put secret/3-apps/myapp/config db_password=secret api_key=abc123

# Add to the app Deployment pod annotations:
#   openbao.openbao.org/agent-inject: "true"
#   openbao.openbao.org/role: "app-kv"
#   openbao.openbao.org/agent-inject-secret-config: "secret/data/3-apps/myapp/config"
```

See [`agent-injector-examples.md`](agent-injector-examples.md) for full annotation examples.

## 5. Adding a new target SSH host

```bash
sudo bash 2-services/openbao/scripts/setup-target-host.sh \
  --client-ca-key "<client-ca-public-key>"
# Configures sshd to trust OpenBao-signed user certificates on the target host.
```

## 6. Rotating the SSH CA

```bash
# Generate a new CA (existing signed certs keep working until they expire)
kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao delete ssh-client-signer/config/ca
kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 \
  bao write ssh-client-signer/config/ca generate_signing_key=true
# Re-run setup-target-host.sh on all hosts with the new CA public key
```

## 7. Rotating the static unseal key

```bash
# Generate a new key and add it as the next key id (Bao re-wraps the root key)
NEW_KEY=$(openssl rand -base64 32)
# Update openbao-static-unseal.sops.yaml with the new value:
sops 2-services/openbao/openbao-static-unseal.sops.yaml
# Bump the seal stanza in openbao-values.yaml to add the new key id and roll the pods.
git add 2-services/openbao/ && git commit -m "chore(openbao): rotate static unseal key" && git push
```

## 8. Emergency contacts / escalation

_Fill in your team's escalation contacts here._
