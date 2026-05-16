# OpenBao User Guide — cyberhawk cluster

OpenBao is deployed as a 3-node HA cluster in the `openbao` namespace. It provides:
- **SSH certificates** — short-lived signed SSH certs for operator access to Linux hosts
- **KV secrets** — static secrets injected into pods via the agent sidecar
- **Dynamic database credentials** — auto-rotating Postgres credentials for apps
- **Web UI** — browser-based management at `http://localhost:8200/ui` via port-forward

---

## Prerequisites

**Install the `bao` CLI** on your workstation:
```bash
# macOS
brew install openbao

# Linux (check https://openbao.org/docs/install for latest version)
curl -Lo bao.zip https://github.com/openbao/openbao/releases/latest/download/bao_linux_amd64.zip
unzip bao.zip && sudo mv bao /usr/local/bin/
```

**Connect to OpenBao** (run this before any `bao` commands):
```bash
kubectl port-forward svc/openbao -n openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<your-token>    # root token, or a scoped token you were issued
```

---

## 1. SSH access to Linux hosts

OpenBao signs your existing SSH public key and issues a short-lived certificate (8h TTL). The target host trusts OpenBao's CA, not individual public keys.

### First time: set up a target host

This needs to run once on each Linux host you want to SSH into. Requires root.

```bash
# Get the client CA public key from OpenBao
CLIENT_CA=$(kubectl exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN \
  bao read -field=public_key ssh-client-signer/config/ca)

# On the target host (copy setup-target-host.sh there first)
sudo bash setup-target-host.sh --client-ca-key "$CLIENT_CA"
```

This writes the CA public key to `/etc/ssh/trusted-user-ca-keys.pem` and reloads sshd. Existing `authorized_keys` entries keep working — this is additive.

### Daily workflow: get a signed cert and SSH in

```bash
# Step 1: sign your key (valid for 8 hours)
bash scripts/ssh-sign.sh
# Output: ~/.ssh/id_ed25519-cert.pub (or id_rsa-cert.pub)

# Step 2: SSH — no extra flags needed, ssh picks up the cert automatically
ssh ubuntu@<host>

# Or explicitly:
ssh -i ~/.ssh/id_ed25519 ubuntu@<host>
```

The script checks if your existing cert is still valid and asks before re-signing.

### Sign for a specific user or TTL

```bash
bao write -field=signed_key ssh-client-signer/sign/human-access \
  public_key=@~/.ssh/id_ed25519.pub \
  valid_principals="deploy" \
  ttl=1h \
  > ~/.ssh/id_ed25519-cert.pub
```

### Check what's in your cert

```bash
ssh-keygen -Lf ~/.ssh/id_ed25519-cert.pub
```

Shows: who it's valid for, expiry time, allowed extensions (permit-pty = terminal, permit-port-forwarding = tunnels).

---

## 2. KV secrets (static secrets)

Path convention: `secret/<namespace>/<app>/<key>`

### Write a secret

```bash
# Single key
bao kv put secret/3-apps/myapp/config db_password=hunter2

# Multiple keys at once
bao kv put secret/3-apps/myapp/config \
  db_password=hunter2 \
  api_key=abc123 \
  redis_url=redis://redis:6379
```

### Read a secret

```bash
# All keys
bao kv get secret/3-apps/myapp/config

# Single field
bao kv get -field=db_password secret/3-apps/myapp/config
```

### Update a secret (creates a new version, old version retained)

```bash
bao kv patch secret/3-apps/myapp/config db_password=newpassword
```

### List secrets

```bash
bao kv list secret/3-apps/myapp/
```

### Inject into a pod (Agent Injector)

Add these annotations to your `Deployment`. The agent sidecar writes the secret to `/openbao/secrets/<name>` inside the pod.

```yaml
metadata:
  annotations:
    openbao.openbao.org/agent-inject: "true"
    openbao.openbao.org/role: "app-kv"
    openbao.openbao.org/agent-inject-secret-config: "secret/data/3-apps/myapp/config"
    # Optional: custom format (default is key=value pairs)
    openbao.openbao.org/agent-inject-template-config: |
      {{- with secret "secret/data/3-apps/myapp/config" -}}
      DB_PASSWORD={{ .Data.data.db_password }}
      API_KEY={{ .Data.data.api_key }}
      {{- end }}
spec:
  serviceAccountName: myapp-sa   # must exist in 3-apps namespace
```

Inside the pod, read with:
```bash
cat /openbao/secrets/config
# DB_PASSWORD=hunter2
# API_KEY=abc123
```

**Important:** The annotation prefix is `openbao.openbao.org/` — NOT `vault.hashicorp.com/`.

---

## 3. Dynamic database credentials

OpenBao creates a temporary Postgres user on demand with a 1h TTL. When the TTL expires OpenBao drops the user automatically.

### Get credentials manually

```bash
# Read-only user (SELECT on all tables)
bao read database/creds/app-readonly

# Read-write user (SELECT, INSERT, UPDATE, DELETE)
bao read database/creds/app-readwrite

# Admin user (all privileges, 15min TTL)
bao read database/creds/app-admin
```

Output:
```
Key                Value
---                -----
lease_id           database/creds/app-readonly/abc123
lease_duration     1h
lease_renewable    true
password           A1a-generated-password
username           v-root-app-rea-generated
```

### Renew a lease before it expires

```bash
bao lease renew database/creds/app-readonly/<lease-id>
```

### Inject into a pod

```yaml
metadata:
  annotations:
    openbao.openbao.org/agent-inject: "true"
    openbao.openbao.org/role: "app-db"
    openbao.openbao.org/agent-inject-secret-db-creds: "database/creds/app-readwrite"
    openbao.openbao.org/agent-inject-template-db-creds: |
      {{- with secret "database/creds/app-readwrite" -}}
      DATABASE_URL=postgres://{{ .Data.username }}:{{ .Data.password }}@postgres:5432/appdb
      {{- end }}
spec:
  serviceAccountName: myapp-sa
```

The sidecar renews the credential automatically before the TTL expires. Your app reads `DATABASE_URL` from `/openbao/secrets/db-creds`.

---

## 4. Web UI

```bash
kubectl port-forward svc/openbao -n openbao 8200:8200
```

Open `http://localhost:8200/ui` — log in with your token. The UI lets you browse secrets, manage auth methods, view leases, and check cluster health.

---

## 5. Getting a token

The root token (from initial setup) should only be used for administration. For daily use, create a scoped token:

```bash
# Token with only KV read access (1 day TTL)
bao token create -policy=kv-reader -ttl=24h

# Token with SSH signing access
bao token create -policy=human-ssh -ttl=24h

# Check what policies your current token has
bao token lookup
```

---

## 6. Common troubleshooting

**"permission denied" on `bao` commands**
Your token doesn't have the required policy. Check with `bao token lookup` and ask an admin to issue a token with the right policy.

**SSH cert rejected by host ("Certificate invalid")**
- Cert expired: re-run `bash scripts/ssh-sign.sh`
- Host not configured: run `setup-target-host.sh` on the host
- Wrong user: check `Valid Principals` in `ssh-keygen -Lf ~/.ssh/id_ed25519-cert.pub`

**Agent injector not injecting**
- Check the pod annotation prefix is `openbao.openbao.org/` not `vault.hashicorp.com/`
- Check the ServiceAccount exists in the correct namespace
- Check injector logs: `kubectl logs -n openbao -l app.kubernetes.io/name=openbao-agent-injector`
- Check init container logs: `kubectl logs <pod> -c vault-agent-init`

**OpenBao sealed after pod restart**
Pods lose their unsealed state on restart. Unseal with:
```bash
sops --decrypt GitOps/clusters/cyberhawk-talos-k8s/2-services/openbao/openbao-unseal-keys.sops.yaml
# then run the unseal commands from operator-runbook.md section 3
```
