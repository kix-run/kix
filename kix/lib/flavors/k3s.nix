# k3s flavor.
#
# k3s bundles Flannel CNI, CoreDNS, the `local-path` StorageClass, ServiceLB,
# and metrics-server. Flannel does not enforce NetworkPolicy. To replace it
# with Cilium, start k3s with `--flannel-backend=none --disable-network-policy`
# and set `cluster.roles.cni.binding = "absent"`. If k3s is started with
# `--disable local-storage`, override `cluster.roles.storageClasses.binding`.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit kix;
    inherit (config) clusterDomain;
  };
in
{
  cluster.provider = lib.mkDefault "k3s";

  # Default `--cluster-cidr` in k3s.
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
    # Override to "absent" when k3s is started with `--disable=metrics-server`.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (k3s packaged component)";
    };
    # Leave `registryMirror` unset by default because k3s only enables its
    # embedded Spegel mirror when `embedded-registry: true` is configured.
  };

  # k3s manages its own containerd under `/var/lib/rancher/k3s/agent`, leaves
  # `discard_unpacked_layers` false, and preserves external `hosts.toml` files
  # across restarts.
  cluster.containerd = {
    socket = lib.mkDefault "/run/k3s/containerd/containerd.sock";
    registryConfigPath = lib.mkDefault "/var/lib/rancher/k3s/agent/etc/containerd/certs.d";
    contentPath = lib.mkDefault "/var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content";
    discardUnpackedLayers = lib.mkDefault false;
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault false;
    nodeAutoscaling = lib.mkDefault false;
    privilegedContainers = lib.mkDefault true;
    daemonSets = lib.mkDefault true;
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
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
