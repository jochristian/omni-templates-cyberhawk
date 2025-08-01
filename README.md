# Sidero Omni Templates for Cilium and Custom Manifests

This project provides a set of templates for [Sidero Omni](https://www.sidero.dev/omni/) to automate the creation of Talos clusters with Cilium as the CNI. It also includes configurations for BGP, Hubble, NFS CSI driver, and other useful components.

## Overview

These templates are designed to bootstrap a Kubernetes cluster with a robust networking and storage setup. The key features include:

-   **Cilium CNI:** Uses Cilium for networking, providing advanced features like BGP, Hubble for observability, and L7 proxying.
-   **Custom Manifests:**  Applies a set of custom manifests to the cluster, including:
    -   Cilium BGP policies and IP pools.
    -   NFS CSI driver for persistent storage.
    -   Metrics Server for resource metrics.
    -   Gateway API CRDs.
    -   Kubelet Serving Cert Approver.
-   **Omni Patches:**  Utilizes Omni's patching mechanism to customize the cluster configuration, such as disabling the default CNI and enabling Kubespan.

## File Structure

```
omni-templates-cyberhawk/
├───cilium_values.yaml
├───machineclass.yaml
├───README.md
├───template.yaml
├───manifests/
│   ├───cilium-bgp-ippool.yml
│   ├───cilium-bgp-policy.yml
│   ├───install_cilium.yaml
│   └───install_nfs-csi-driver.yaml
└───patches/
    ├───cni.yml
    ├───extraManifests.yml
    ├───kubespan.yml
    └───monitoring.yaml
```

## Requirements

- **Sidero Omni:** An operational Sidero Omni environment.
- **Helm:** Used for templating the Cilium and NFS CSI driver charts.
- **kubectl:** The Kubernetes command-line tool for interacting with the cluster.
- **omnictl:** The omnictl command-line tool for interacting with Omni dashboard.

## Installation

1. **Install Helm required repositories:**
   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
   helm repo update
   ```
2. **Template the charts:**
   ```bash
   helm template cilium cilium/cilium --version 1.18.0 --namespace kube-system -f cilium_values.yaml > manifests/install_cilium.yaml
   helm template csi-driver-nfs csi-driver-nfs/csi-driver-nfs --namespace kube-system --version v4.11.0 > manifests/install_nfs-csi-driver.yaml
   ```
3. **Apply the template to your Omni environment:**
   ```bash
   omnictl apply -f machineclass.yaml
   omnictl cluster template sync --file template.yaml
   ```



### Core Files

-   `template.yaml`: The main Omni template file. It defines the cluster, control plane, and worker nodes, and orchestrates the application of patches and configurations.
-   `cilium_values.yaml`: Contains the configuration values for the Cilium installation. This is where you can customize Cilium's behavior.
-   `machineclass.yaml`: Defines the machine classes for control plane and worker nodes, specifying matching labels for machine discovery.

### Manifests

The `manifests/` directory contains the raw Kubernetes manifests that are applied to the cluster:

-   `install_cilium.yaml`: The primary manifest for installing Cilium and its components (agent, operator, Hubble, etc.).
-   `cilium-bgp-policy.yml`: Defines the BGP peering policies for Cilium.
-   `cilium-bgp-ippool.yml`:  Configures the IP address pool for Cilium's BGP load balancer.
-   `install_nfs-csi-driver.yaml`: Installs the NFS CSI driver for providing persistent storage from an NFS server.

### Patches

The `patches/` directory contains Omni patches that modify the base cluster configuration:

-   `cni.yml`: Disables the default CNI to allow for the installation of Cilium.
-   `extraManifests.yml`:  Applies the custom manifests from the `manifests/` directory.
-   `kubespan.yml`: Enables Kubespan for inter-cluster communication.
-   `monitoring.yaml`: Adds extra arguments to the Kubelet for monitoring purposes.

## How to Use

1.  **Prerequisites:**
    -   An operational Sidero Omni environment.
    -   Machines that can be provisioned by Omni.
    -   An understanding of your network environment, especially if you are using BGP.

2.  **Customization:**
    -   Review and modify `cilium_values.yaml` to match your network and cluster requirements. Pay close attention to the BGP settings, IPAM mode, and any other features you want to enable or disable.
    -   Adjust the `machineclass.yaml` to match the labels of your machines.
    -   If necessary, modify the manifests in the `manifests/` directory to suit your needs.

3.  **Deployment:**
    -   Apply the `template.yaml` to your Omni environment. Omni will then use this template and the associated files to provision and configure your Talos cluster.

## Configuration Details

### Cilium

Cilium is configured via the `cilium_values.yaml` file. Some key configurations in this template include:

-   **BGP:** BGP is enabled for advertising service IPs. You will need to configure the `peerASN` and `peerAddress` in `manifests/cilium-bgp-policy.yml` to match your network's BGP router.
-   **Hubble:** Hubble is enabled for network observability.
-   **L7 Proxy:** The L7 proxy is enabled for L7 policy enforcement.
-   **Kube-proxy Replacement:**  Kube-proxy is replaced by Cilium for better performance and more features.

### NFS CSI Driver

The NFS CSI driver is installed to provide persistent storage. You will need to have an NFS server available in your environment. When creating PersistentVolumeClaims, you can specify the `nfs.csi.k8s.io` provisioner.

### Patches

The patches in the `patches/` directory are essential for the proper functioning of this template. They ensure that the default CNI is disabled, and that all the necessary custom manifests are applied to the cluster.
