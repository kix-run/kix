# Flavor: k3s — lightweight K8s distribution by Rancher.
#
# Pre-installs: flannel CNI, local-path StorageClass, servicelb, traefik.
# Flannel does NOT enforce NetworkPolicy — replace with Cilium or Calico if needed.
#
# Platform imports: DNS (coredns, bundled), storage (local-path).

{ lib, kix, ... }:
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
          storageClassName = "local-path";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };
}
