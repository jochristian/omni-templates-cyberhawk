# Kyverno break-glass runbook

For when a policy in **Enforce** mode blocks something it shouldn't —
at 11pm, over SSH, without debugging Kyverno first.

Current posture (see `GitOps/clusters/cyberhawk-talos-k8s/1-system/kyverno/`):
policies audit the GitOps-managed namespaces and **Enforce only the
namespaces listed in each rule's `failureActionOverrides`** (initially
`karakeep`). Webhooks are fail-open (`failurePolicy: Ignore`), so a *down*
Kyverno never blocks anything — break-glass is only needed when a policy is
*working* but wrong.

## Option 1 — PolicyException (surgical, preferred)

Exempts specific resources from specific rules without touching the policy.
Exceptions are only honoured from the `kyverno` namespace
(`features.policyExceptions.namespace: kyverno` in the kustomization).

```bash
kubectl apply -f - <<'EOF'
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: break-glass-TICKET-OR-DATE
  namespace: kyverno
spec:
  exceptions:
    - policyName: disallow-latest-tag        # or require-labels
      ruleNames:
        - validate-image-tag                 # rule name(s) from the policy
        - autogen-validate-image-tag         # include the autogen twin for Pod-matching rules!
  match:
    any:
      - resources:
          kinds:
            - Pod
            - Deployment
          namespaces:
            - karakeep
          names:
            - "the-blocked-workload*"
EOF
```

Afterwards: fix the workload or the policy in git, then
`kubectl -n kyverno delete policyexception break-glass-TICKET-OR-DATE`.

## Option 2 — demote the namespace to Audit (broader)

Remove the namespace from `failureActionOverrides` in the policy file in
git and push — ArgoCD syncs it. If git/ArgoCD is part of what's broken,
patch live (ArgoCD selfHeal is off, so the patch sticks until the next
sync of the app):

```bash
kubectl patch clusterpolicy disallow-latest-tag --type=json \
  -p='[{"op":"remove","path":"/spec/rules/1/validate/failureActionOverrides"}]'
```

(rule index: 0 = require-image-tag, 1 = validate-image-tag;
require-labels has a single rule, index 0.)

## Option 3 — kill switch (last resort)

```bash
kubectl delete clusterpolicy disallow-latest-tag require-labels
```

Audit history is lost (reports are rebuilt when the policies come back via
ArgoCD sync). Kyverno itself keeps running. If Kyverno must go entirely,
remember its ValidatingWebhookConfigurations are runtime-created and NOT
pruned by ArgoCD:

```bash
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl delete validatingwebhookconfigurations <the kyverno-* ones>
```

## Verify the coast is clear

```bash
kubectl get clusterpolicies                      # READY True
kubectl -n karakeep get policyreports            # FAIL counts
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=10m | grep -i denied
```
