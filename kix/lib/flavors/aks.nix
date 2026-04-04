# Flavor: AKS — Azure Kubernetes Service.
#
# Managed control plane. Azure CNI gives pods VNet IPs.
# Azure Load Balancer provides external IPs automatically.
# Azure Disk CSI with snapshot support pre-installed.
# No ingress controller by default (AGIC and nginx are opt-in addons).
#
# Platform imports: DNS (coredns, managed by AKS), storage (managed-csi).

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "aks";

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    loadBalancer = lib.mkDefault true;
    cni = lib.mkDefault "azure-cni";
    networkPolicyAPI = lib.mkDefault "k8s"; # Azure NPM or Calico as enforcer
    persistentStorage = lib.mkDefault true; # Azure Managed Disk CSI
    volumeSnapshots = lib.mkDefault true; # pre-installed since AKS 1.20+
    nodeAutoscaling = lib.mkDefault false; # available per node pool, not on by default
  };

  # Platform-provided imports.
  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        out = {
          name = "coredns";
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      aliases = [ "dns" ];
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        out = {
          storageClassName = "managed-csi";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };
}
