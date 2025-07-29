## First create machineconfig
omnictl apply -f machineclass.yaml

## Create template
omnictl cluster template sync --file template.yaml
