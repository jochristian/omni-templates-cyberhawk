#!/bin/bash

# ---
# This script restructures the GitOps repository into a cluster-centric layout.
# It moves existing application definitions into a new structure and creates
# a root ApplicationSet to manage everything.
# ---

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Step 1: Creating the new directory structure..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/1-system
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/2-services
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/3-apps

# ---
# Step 2: Move and reorganize system applications
# ---
echo "Step 2: Moving system applications..."

# ArgoCD
echo "  -> Moving ArgoCD..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/1-system/argocd
# Move all the configuration files for ArgoCD itself
mv GitOps/apps/argocd/argocd/* GitOps/clusters/cyberhawk-talos-k8s/1-system/argocd/
# The bootstrap-app-set.yaml will be replaced by our new root appset, so we remove it
rm GitOps/clusters/cyberhawk-talos-k8s/1-system/argocd/bootstrap-app-set.yaml

# Cilium
echo "  -> Moving Cilium..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/1-system/kube-system
# Move the entire directory as its source is defined by path
mv GitOps/apps/kube-system/cilium GitOps/clusters/cyberhawk-talos-k8s/1-system/kube-system/

# Traefik
echo "  -> Moving Traefik..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/1-system/system
mv GitOps/apps/system/traefik/app.yaml GitOps/clusters/cyberhawk-talos-k8s/1-system/system/traefik.yaml

# NFS CSI Driver (assuming it deploys to kube-system)
echo "  -> Moving NFS CSI Driver..."
# Create a new Application manifest for the NFS driver
cat <<EOF > GitOps/clusters/cyberhawk-talos-k8s/1-system/kube-system/nfs-csi-driver.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi-driver
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    chart: csi-driver-nfs
    targetRevision: v4.11.0 # As per your README
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF


# ---
# Step 3: Move and reorganize shared services
# ---
echo "Step 3: Moving shared services..."

# Cert-Manager
echo "  -> Moving Cert-Manager..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/2-services/cert-manager
mv GitOps/apps/cert-manager/cert-manager/cert-manager.yaml GitOps/clusters/cyberhawk-talos-k8s/2-services/cert-manager/app.yaml

# Vault
echo "  -> Moving Vault..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/2-services/vault
mv GitOps/apps/vault/vault/vault.yaml GitOps/clusters/cyberhawk-talos-k8s/2-services/vault/app.yaml

# Volsync
echo "  -> Moving Volsync..."
mkdir -p GitOps/clusters/cyberhawk-talos-k8s/2-services/volsync-system
mv GitOps/apps/volsync/volsync/volsync.yaml GitOps/clusters/cyberhawk-talos-k8s/2-services/volsync-system/app.yaml


# ---
# Step 4: Create the new root ApplicationSet
# ---
echo "Step 4: Creating the new root ApplicationSet..."
cat <<'EOF' > GitOps/clusters/cyberhawk-talos-k8s/appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cyberhawk-talos-k8s
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/jochristian/omni-templates-cyberhawk.git # CHANGE THIS TO YOUR REPO URL
        revision: HEAD
        # This will find any .yaml file that defines an Application or Kustomization
        files:
          - path: "GitOps/clusters/cyberhawk-talos-k8s/*/*/*.yaml"
          - path: "GitOps/clusters/cyberhawk-talos-k8s/*/*/*/*.yaml" # For Cilium's nested structure
  template:
    metadata:
      # Name will be like "system-traefik", "services-vault"
      name: '{{ path.segments[3] }}-{{ path.basenameNormalized | replace ".yaml" "" }}'
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/jochristian/omni-templates-cyberhawk.git # CHANGE THIS TO YOUR REPO URL
        targetRevision: HEAD
        # The path to the directory containing the file
        path: '{{ path.directory }}'
      destination:
        server: https://kubernetes.default.svc
        # Namespace is taken from the directory name (e.g., "vault", "kube-system")
        namespace: '{{ path.segments[4] }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
EOF


echo "-------------------------------------"
echo "✅ Restructuring complete!"
echo "Your new directory structure is in 'GitOps/clusters/cyberhawk-talos-k8s/'"
echo "IMPORTANT: Review 'GitOps/clusters/cyberhawk-talos-k8s/appset.yaml' and change the repoURL to match your own Git repository."
echo "You can verify the new structure by running: tree GitOps"
echo "-------------------------------------"
