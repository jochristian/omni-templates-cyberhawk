# dnscontrol — DNS zones via GitOps

DNS for all zones is managed by [dnscontrol](https://dnscontrol.org/) from
`GitOps/clusters/cyberhawk-talos-k8s/2-services/dnscontrol/`. The zone
config AND the Cloudflare token are SOPS-encrypted inside
`01-dnscontrol.sops.yaml` (public repo — records are dig-able anyway, but
not bulk-enumerable from GitHub).

## Change a DNS record

```bash
cd GitOps/clusters/cyberhawk-talos-k8s/2-services/dnscontrol
sops 01-dnscontrol.sops.yaml     # edit the dnsconfig.js block, save
git add 01-dnscontrol.sops.yaml && git commit && git push
```

ArgoCD syncs `2-services-dnscontrol`; the PostSync hook Job `dnscontrol-push`
runs `dnscontrol push` and logs the exact record diff:

```bash
kubectl -n dnscontrol logs job/dnscontrol-push
```

A daily CronJob (`dnscontrol-drift`, 03:30) re-pushes to revert any manual
Cloudflare-UI edits. Git is the source of truth.

## Preview locally before committing

```bash
cd GitOps/clusters/cyberhawk-talos-k8s/2-services/dnscontrol
sops -d 01-dnscontrol.sops.yaml | yq -r '.stringData["dnsconfig.js"]' > /tmp/dnsconfig.js
sops -d 01-dnscontrol.sops.yaml | yq -r '.stringData["creds.json"]'  > /tmp/creds.json
dnscontrol preview --config /tmp/dnsconfig.js --creds /tmp/creds.json
rm /tmp/dnsconfig.js /tmp/creds.json
```

## Notes

- Image `ghcr.io/dnscontrol/dnscontrol` (tags WITHOUT `v` prefix), pinned in
  `kustomization.yaml`, tracked by Renovate.
- A failed push fails the app sync in ArgoCD (visible there); the CronJob is
  the catch-up if Cloudflare was briefly unreachable.
- Registrar is `NewRegistrar("none")` — dnscontrol manages records only, not
  registrar NS delegation.
