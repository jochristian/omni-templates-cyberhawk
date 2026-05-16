# OpenBao Operator Runbook — cyberhawk cluster

## 1. Deployment order (first time)

```bash
# Step 1: generate TLS cert and encrypt
bash 2-services/openbao/scripts/generate-tls.sh > /tmp/openbao-tls.yaml
cp /tmp/openbao-tls.yaml 2-services/openbao/openbao-tls.sops.yaml
sops --encrypt --in-place 2-services/openbao/openbao-tls.sops.yaml
rm /tmp/openbao-tls.yaml

# Step 2: commit and sync (unseal keys stub already encrypted)
git add 2-services/openbao/ 1-system/namespaces/ && git commit -m "feat(openbao): deploy" && git push
# ArgoCD syncs automatically — wait for 3 pods Running

# Step 3: initialize (ONE TIME ONLY)
bash 2-services/openbao/scripts/init-and-unseal.sh
# Save all 5 keys. Then fill openbao-unseal-keys.sops.yaml with keys 1-3 + root token:
sops 2-services/openbao/openbao-unseal-keys.sops.yaml
git add 2-services/openbao/openbao-unseal-keys.sops.yaml && git commit -m "feat(openbao): store unseal keys" && git push

# Step 4: set env for configure scripts
export BAO_ADDR=https://openbao.openbao.svc.cluster.local:8200
export BAO_TOKEN=<root-token-from-init>
# Extract TLS cert for local verification:
kubectl get secret -n openbao openbao-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/openbao-tls.crt
export BAO_CACERT=/tmp/openbao-tls.crt

# Step 5: configure engines (in order)
bash 2-services/openbao/scripts/configure-k8s-auth.sh
bash 2-services/openbao/scripts/configure-kv-engine.sh
bash 2-services/openbao/scripts/configure-ssh-engine.sh
# Edit configure-db-engine.sh: replace all CHANGE_ME values, then:
bash 2-services/openbao/scripts/configure-db-engine.sh

# Step 6: verify everything
bash 2-services/openbao/scripts/verify.sh

# Step 7: distribute SSH CA keys to each target host
CLIENT_CA=$(kubectl exec -n openbao openbao-0 -- bao read -field=public_key ssh-client-signer/config/ca)
HOST_CA=$(kubectl exec -n openbao openbao-0 -- bao read -field=public_key ssh-host-signer/config/ca)
# On each target host:
sudo bash 2-services/openbao/scripts/setup-target-host.sh \
  --client-ca-key "$CLIENT_CA" --host-ca-key "$HOST_CA"

# Step 8: revoke root token
bao token revoke "$BAO_TOKEN"
```

## 2. Daily operator workflow (SSH access)

```bash
export BAO_ADDR=https://openbao.cyberhawk.no
# or: kubectl port-forward svc/openbao 8200:8200 -n openbao
export BAO_TOKEN=$(bao login -method=userpass username=<user> -field=token)
bash 2-services/openbao/scripts/ssh-sign.sh
ssh -i ~/.ssh/id_ed25519-cert.pub -i ~/.ssh/id_ed25519 ubuntu@<host>
```

## 3. Manual unseal after pod restart

```bash
# Decrypt unseal keys
sops --decrypt 2-services/openbao/openbao-unseal-keys.sops.yaml

# Unseal each pod with 3 keys
for pod in openbao-0 openbao-1 openbao-2; do
  kubectl exec -n openbao $pod -- bao operator unseal <key-1>
  kubectl exec -n openbao $pod -- bao operator unseal <key-2>
  kubectl exec -n openbao $pod -- bao operator unseal <key-3>
done
```

## 4. Adding a new KV secret for an app

```bash
# Convention: secret/<namespace>/<app>/<key>
bao kv put secret/3-apps/myapp/config db_password=secret api_key=abc123

# Add to app Deployment annotations:
# openbao.openbao.org/agent-inject: "true"
# openbao.openbao.org/role: "app-kv"
# openbao.openbao.org/agent-inject-secret-config: "secret/data/3-apps/myapp/config"
```

## 5. Adding a new target SSH host

```bash
sudo bash 2-services/openbao/scripts/setup-target-host.sh \
  --client-ca-key "<client-ca-public-key>"
# Configures sshd to trust OpenBao-signed user certificates on the target host.
```

## 6. Rotating the SSH CA

```bash
# Generate new CA (existing signed certs continue working until they expire)
kubectl exec -n openbao openbao-0 -- bao delete ssh-client-signer/config/ca
kubectl exec -n openbao openbao-0 -- bao write ssh-client-signer/config/ca generate_signing_key=true
# Re-run setup-target-host.sh on all hosts with the new CA public key
```

## 7. Renewing the OpenBao TLS cert

```bash
bash 2-services/openbao/scripts/generate-tls.sh > /tmp/openbao-tls.yaml
cp /tmp/openbao-tls.yaml 2-services/openbao/openbao-tls.sops.yaml
sops --encrypt --in-place 2-services/openbao/openbao-tls.sops.yaml
rm /tmp/openbao-tls.yaml
git add 2-services/openbao/openbao-tls.sops.yaml && git commit && git push
# ArgoCD applies the new Secret; pods do a rolling restart to pick up the new cert
```

## 8. Emergency contacts / escalation

_Fill in your team's escalation contacts here._
