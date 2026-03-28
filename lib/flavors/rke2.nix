# Flavor: RKE2 — Rancher's next-generation Kubernetes distribution.
#
# Designed for security-conscious environments. Ships Canal (Flannel + Calico
# NetworkPolicy enforcement) by default. CIS benchmark hardened out of the box.
# No default StorageClass or LoadBalancer — install Longhorn, MetalLB, etc.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "rke2";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "canal"; # Flannel networking + Calico policy enforcement
    networkPolicyAPI = lib.mkDefault "calico";
    persistentStorage = lib.mkDefault false; # no default StorageClass
    volumeSnapshots = lib.mkDefault false;
  };
}
