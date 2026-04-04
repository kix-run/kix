# Flavor: Talos — immutable, API-driven Kubernetes OS.
#
# No SSH, no shell, no package manager. All OS config is declarative via
# machineconfig YAML applied through talosctl. Kernel modules (NVIDIA, etc.)
# require custom system extensions baked at image build time.
#
# Ships Flannel by default (commonly replaced with Cilium in production).
# No default StorageClass, LoadBalancer, or ingress controller.
#
# Platform imports: DNS (coredns, bundled). No default storage.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "talos";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "flannel"; # commonly replaced with Cilium
    networkPolicyAPI = lib.mkDefault "none"; # flannel has no enforcement
    persistentStorage = lib.mkDefault false; # no default StorageClass
    volumeSnapshots = lib.mkDefault false;
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
  };
}
