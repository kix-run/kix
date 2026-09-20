# RKE2 flavor.
#
# Designed for security-conscious environments. Ships Canal (Flannel +
# Calico NetworkPolicy enforcement) by default. The cni role is
# environment-owned (exclusive). CIS benchmark hardened out of the box.
# No default StorageClass or LoadBalancer is provided; install
# Longhorn, MetalLB, etc. (The lithus flavor extends this with RKE2
# configured for external Cilium instead of Canal.)
#
# Platform imports: DNS (coredns, bundled). No default storage.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "rke2";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "canal"; # Flannel networking + Calico policy enforcement
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "absent"; # no default StorageClass
    loadBalancer.binding = lib.mkDefault "absent";
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
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
  };
}
