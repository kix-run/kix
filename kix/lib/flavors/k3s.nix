# k3s flavor.
#
# Pre-installs: flannel CNI, local-path StorageClass, servicelb, traefik.
# Flannel does not enforce NetworkPolicy. To replace it with Cilium, run
# k3s with `--flannel-backend=none --disable-network-policy` and override
# `cluster.roles.cni.binding = "absent"` (see ludo/cluster.nix).
#
# Platform imports: DNS (coredns, bundled), storage (local-path).

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "k3s";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "flannel";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "servicelb (klipper)";
    };
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
          fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}";
        };
      };
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "local-path";
        };
      };
      optional = true;
    };
  };
}
