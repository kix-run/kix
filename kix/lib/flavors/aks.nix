# Flavor: AKS — Azure Kubernetes Service.
#
# Managed control plane. Azure CNI gives pods VNet IPs — the cni role is
# environment-owned (exclusive). Azure Load Balancer provides external IPs
# automatically (shadowable). Azure Disk CSI with snapshot support
# pre-installed. No ingress controller by default (AGIC and nginx are
# opt-in addons).
#
# Platform imports: DNS (coredns, managed by AKS), storage (managed-csi).

{ lib, kix, ... }:
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
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "managed-csi";
          rwx = false; # Azure Disk is RWO; RWX needs Azure Files
          snapshots = true; # pre-installed since AKS 1.20+
        };
      };
      optional = true;
    };
  };
}
