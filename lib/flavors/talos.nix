# Flavor: Talos — immutable, API-driven Kubernetes OS.
#
# No SSH, no shell, no package manager. All OS config is declarative via
# machineconfig YAML applied through talosctl. Kernel modules (NVIDIA, etc.)
# require custom system extensions baked at image build time.
#
# Ships Flannel by default (commonly replaced with Cilium in production).
# No default StorageClass, LoadBalancer, or ingress controller.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "talos";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "flannel"; # commonly replaced with Cilium
    networkPolicyAPI = lib.mkDefault "none"; # flannel has no enforcement
    persistentStorage = lib.mkDefault false; # no default StorageClass
    volumeSnapshots = lib.mkDefault false;
  };
}
