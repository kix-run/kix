# Flavor: RKE2 — Rancher's next-generation Kubernetes distribution.
#
# Designed for security-conscious environments. Ships Canal (Flannel + Calico
# NetworkPolicy enforcement) by default. CIS benchmark hardened out of the box.
# No default StorageClass or LoadBalancer — install Longhorn, MetalLB, etc.
#
# Platform imports: DNS (coredns, bundled). No default storage.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "rke2";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "canal"; # Flannel networking + Calico policy enforcement
    networkPolicyAPI = lib.mkDefault "calico";
    persistentStorage = lib.mkDefault false; # no default StorageClass
    volumeSnapshots = lib.mkDefault false;
  };

  # Platform-provided imports.
  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        out = {
          name = "coredns";
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      aliases = [ "dns" ];
      optional = true;
    };
  };
}
