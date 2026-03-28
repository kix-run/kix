# Flavor: k3s — lightweight K8s distribution by Rancher.
#
# Pre-installs: flannel CNI, local-path StorageClass, servicelb, traefik.
# Flannel does NOT enforce NetworkPolicy — replace with Cilium or Calico if needed.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "k3s";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault true; # servicelb / klipper
    cni = lib.mkDefault "flannel";
    networkPolicyAPI = lib.mkDefault "none"; # flannel has no enforcement
    ingressController = lib.mkDefault "traefik";
    persistentStorage = lib.mkDefault true; # local-path-provisioner
    volumeSnapshots = lib.mkDefault false; # local-path has no snapshot support
  };
}
