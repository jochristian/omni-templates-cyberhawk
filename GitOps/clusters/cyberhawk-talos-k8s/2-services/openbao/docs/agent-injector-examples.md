# OpenBao Agent Injector — Annotation Examples

Annotation prefix: `openbao.openbao.org/` (NOT `vault.hashicorp.com/`)
Secrets rendered to: `/openbao/secrets/<name>`

---

## Example 1 — Basic KV secret injection (key=value format)

**Trade-off:** Simple, works for static config. File is re-rendered on lease renewal (~1h). App reads from file path, not env vars — avoids env leakage.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: example-api-sa
  namespace: 3-apps
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-api
  namespace: 3-apps
spec:
  template:
    metadata:
      annotations:
        # Enable the agent injector
        openbao.openbao.org/agent-inject: "true"
        # Kubernetes auth role (bound to 3-apps namespace)
        openbao.openbao.org/role: "app-kv"
        # Secret path and destination filename
        openbao.openbao.org/agent-inject-secret-config: "secret/data/3-apps/example-api/config"
        # Render as key=value pairs
        openbao.openbao.org/agent-inject-template-config: |
          {{- with secret "secret/data/3-apps/example-api/config" -}}
          DB_PASSWORD={{ .Data.data.db_password }}
          API_KEY={{ .Data.data.api_key }}
          {{- end }}
    spec:
      serviceAccountName: example-api-sa
      containers:
        - name: app
          image: example-api:latest
          # Read: source /openbao/secrets/config && use $DB_PASSWORD, $API_KEY
```

---

## Example 2 — Dynamic DB credentials injection

**Trade-off:** Credentials rotate automatically before expiry. App needs a reconnect-capable DB client. Sidecar runs continuously to renew leases — add resource limits if needed.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: example-worker-sa
  namespace: 3-apps
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-worker
  namespace: 3-apps
spec:
  template:
    metadata:
      annotations:
        openbao.openbao.org/agent-inject: "true"
        # Use app-db role (bound to 3-apps, gets database/creds access)
        openbao.openbao.org/role: "app-db"
        openbao.openbao.org/agent-inject-secret-db-creds: "database/creds/app-readwrite"
        openbao.openbao.org/agent-inject-template-db-creds: |
          {{- with secret "database/creds/app-readwrite" -}}
          DATABASE_URL=postgres://{{ .Data.username }}:{{ .Data.password }}@postgres:5432/appdb
          {{- end }}
    spec:
      serviceAccountName: example-worker-sa
      containers:
        - name: worker
          image: example-worker:latest
          # Read: DATABASE_URL from /openbao/secrets/db-creds
```

---

## Example 3 — Init container only (no sidecar renewal)

**Trade-off:** No sidecar — lower resource overhead. Secret expires when the credential TTL hits; pod must restart to get a new one. Fine for batch jobs. NOT suitable for long-running apps that need lease renewal.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: batch-job-sa
  namespace: 3-apps
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-job
  namespace: 3-apps
spec:
  template:
    metadata:
      annotations:
        openbao.openbao.org/agent-inject: "true"
        openbao.openbao.org/role: "app-kv"
        openbao.openbao.org/agent-inject-secret-config: "secret/data/3-apps/batch-job/config"
        # Init container only — no sidecar, secret populated once at pod startup
        openbao.openbao.org/agent-pre-populate-only: "true"
    spec:
      serviceAccountName: batch-job-sa
      containers:
        - name: batch
          image: batch-job:latest
          # Read secrets from /openbao/secrets/config at startup
```
