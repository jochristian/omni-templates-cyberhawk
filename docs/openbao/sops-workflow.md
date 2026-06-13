# SOPS Workflow — OpenBao Secrets

## 1. Encrypting a new secret file

```bash
# Create plaintext secret
cat > mysecret.yaml <<EOF
apiVersion: v1
kind: Secret
stringData:
  key: value
EOF
sops --encrypt --in-place mysecret.yaml   # reads .sops.yaml for recipients
git add mysecret.yaml && git commit       # commit only after encryption
```

## 2. Verifying before committing

```bash
# Confirm file is encrypted — must NOT show plaintext values
head -5 mysecret.yaml        # must show sops: header, not stringData: plaintext
sops --decrypt mysecret.yaml | head -5   # verify decryption works
```

## 3. Editing an encrypted file

```bash
sops mysecret.yaml   # opens in $EDITOR, saves re-encrypted automatically
```
Safer than decrypt-edit-encrypt: atomic operation, no plaintext file left on disk.

## 4. Viewing without editing

```bash
sops --decrypt mysecret.yaml
```

## 5. What KSOPS requires

`ksops-generator.yaml` lists encrypted files. `kustomization.yaml` references it via `generators:`. ArgoCD's repo-server runs `ksops` (exec plugin) which decrypts each listed file using the age key mounted at `/.config/sops/age/keys.txt`. Both the generator file and kustomization must exist for ArgoCD to sync secrets.

## 6. Age key rotation

```bash
# 1. Update .sops.yaml with new age public key
# 2. Re-encrypt each file (requires OLD key to still be available).
#    Do this for EVERY *.sops.yaml in the repo, e.g. for OpenBao:
sops updatekeys 2-services/openbao/openbao-unseal-keys.sops.yaml
sops updatekeys 2-services/openbao/openbao-static-unseal.sops.yaml
#    (find them all with: git ls-files '*.sops.yaml')
# 3. Update the argocd-sops-age-key Secret with the new private key
# 4. Commit and push
```

## 7. Emergency: secret committed in plaintext

```bash
# 1. Immediately revoke/rotate the exposed credential
# 2. Remove from git history (requires force-push — coordinate with team):
git filter-repo --path <file> --invert-paths
git push origin main --force
# 3. Encrypt and recommit:
sops --encrypt --in-place <file>
git add <file> && git commit && git push
# 4. Enable GitHub secret scanning to catch future leaks
```
