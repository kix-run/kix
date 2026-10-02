# Azure Kubernetes Service flavor.
#
# Managed control plane. Azure CNI gives pods VNet IPs, and the cni role is
# environment-owned (exclusive). Azure Load Balancer provides external IPs
# automatically (shadowable). Azure Disk CSI with snapshot support
# pre-installed. No ingress controller by default (AGIC and nginx are
# opt-in addons).
#
# Platform imports: DNS (coredns, managed by AKS), storage (managed-csi,
# the default class the Azure Disks CSI driver creates:
# https://learn.microsoft.com/azure/aks/azure-disk-csi).

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
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, not on by default
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  # Platform-provided imports.
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
