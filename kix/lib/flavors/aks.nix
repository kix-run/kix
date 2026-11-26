# Azure Kubernetes Service flavor.
#
# AKS provides a managed control plane, Azure CNI (exclusive), Azure Load
# Balancer (shadowable), and the Azure Disk CSI driver with `managed-csi` as
# the default StorageClass. No ingress controller is installed by default.
#
# Pods get Azure identities through Microsoft Entra Workload ID, which the
# `cloud-identity` import declares.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit lib kix;
    inherit (config) clusterDomain;
  };
  platformCloudIdentity = import ./cloud-identity.nix { inherit kix; };
  mechanisms = import ../vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  cluster.provider = lib.mkDefault "aks";
  # The cloud runs and upgrades the pods in kube-system, so Kix writes no
  # default deny there.
  networkPolicy.platformNamespaces = lib.mkDefault [ "kube-system" ];

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "azure-cni";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "azure-lb";
    };
    # AKS runs a managed metrics-server in kube-system.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (aks-managed)";
    };
  };

  # AKS node images keep unpacked containerd layers so Spegel peers can serve
  # them.
  cluster.containerd.discardUnpackedLayers = lib.mkDefault false;

  cluster.capabilities = {
    # A new AKS cluster's system node pool has three nodes by default.
    multiNode = lib.mkDefault true;
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
    };

    cloud-identity = platformCloudIdentity { mechanism = mechanisms.azureWorkloadId { }; };

    platform-storage = {
      package = kix.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "managed-csi";
          name = "managed-csi";
        };
      };
    };
  };
}
