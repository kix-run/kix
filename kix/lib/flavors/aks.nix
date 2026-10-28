# Azure Kubernetes Service flavor.
#
# AKS provides a managed control plane, Azure CNI (exclusive), Azure Load
# Balancer (shadowable), and the Azure Disk CSI driver with `managed-csi` as
# the default StorageClass. No ingress controller is installed by default.

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "aks";

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
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        roles = [ "dns" ];
        out = {
          name = "coredns";
          fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
        };
      };
      optional = true;
    };

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
