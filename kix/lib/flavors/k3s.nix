# k3s flavor.
#
# Pre-installs: flannel CNI, local-path StorageClass, servicelb, traefik.
# Flannel does not enforce NetworkPolicy. To replace it with Cilium, run
# k3s with `--flannel-backend=none --disable-network-policy` and override
# `cluster.roles.cni.binding = "absent"` (see ludo/cluster.nix). The
# cilium package takes its IPAM pool from cluster.network.podCidr, which
# defaults here to k3s's cluster-cidr.
#
# Platform imports: DNS (coredns, bundled), storage (local-path). k3s
# creates the local-path StorageClass on every new cluster
# (https://docs.k3s.io/storage). A server started with
# `--disable local-storage` has no such class, and the import below is then
# wrong for that cluster.

{
  config,
  lib,
  kix,
  ...
}:
{
  cluster.provider = lib.mkDefault "k3s";

  # k3s's default --cluster-cidr.
  cluster.network.podCidr = lib.mkDefault "10.42.0.0/16";

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
    # k3s deploys metrics-server as a packaged component. A server started
    # with `--disable=metrics-server` sets the binding to "absent" and runs a
    # metrics-server instance.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (k3s packaged component)";
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
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "local-path";
          name = "local-path";
        };
      };
    };
  };
}
