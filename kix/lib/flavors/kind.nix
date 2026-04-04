# Flavor: kind — Kubernetes in Docker, for local development and CI.
#
# Pre-installs: kindnet CNI, standard StorageClass (local, ephemeral).
# Volumes do not survive container restarts. No LoadBalancer support.
#
# Platform imports: DNS (coredns, bundled), storage (standard, ephemeral).

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "kind";

  cluster.capabilities = {
    multiNode = lib.mkDefault false;
    loadBalancer = lib.mkDefault false;
    cni = lib.mkDefault "kindnet";
    networkPolicyAPI = lib.mkDefault "none"; # kindnet has no enforcement
    persistentStorage = lib.mkDefault false; # volumes are ephemeral (docker container FS)
    rwxStorage = lib.mkDefault false;
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

    platform-storage = {
      package = kix.mkImport {
        out = {
          storageClassName = "standard";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };
}
