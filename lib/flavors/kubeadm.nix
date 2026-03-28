# Flavor: kubeadm — vanilla upstream Kubernetes bootstrap.
#
# Ships nothing beyond the control plane. CNI, storage, ingress, and
# load balancing are all bring-your-own. Override capabilities after
# importing this module to reflect what you've installed.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "kubeadm";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault null; # must be installed separately
    networkPolicyAPI = lib.mkDefault "none"; # depends on CNI choice
    persistentStorage = lib.mkDefault false; # no default StorageClass
    volumeSnapshots = lib.mkDefault false;
  };
}
