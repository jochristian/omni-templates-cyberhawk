## create cilium install from helm template
helm template cilium cilium/cilium --version 1.18.0 --namespace kube-system -f cilium_values.yaml > manifests/install_cilium.yaml


## Create omni machineconfig
omnictl apply -f machineclass.yaml

## Create template
omnictl cluster template sync --file template.yaml
