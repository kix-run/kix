# Scaleway Kapsule flavor.
#
# Scaleway Kapsule provides a managed control plane, Kapsule-managed Cilium CNI
# (exclusive), CoreDNS, and an optional paid Scaleway Load Balancer.
#
# Storage:
#   - Block CSI (`csi.scaleway.com`): pre-installed on all nodes with RWO
#     classes `scw-bssd`, `sbs-default` (the cluster default), `sbs-5k`, and
#     `sbs-15k` (plus `*-retain` variants).
#   - File Storage CSI (`filestorage.csi.scaleway.com`): provides RWX
#     `sfs-standard` (and `sfs-standard-retain`) when the cluster is tagged
#     `scw-filestorage-csi`. Its `filestorage-csi-node` DaemonSet nodeAffinity
#     excludes `DEV1` and `PLAY2` nodes, so RWX volumes require `BASIC3` or
#     higher instance types.

{
  config,
  lib,
  kix,
  ...
}:
let
  platformDns = import ./platform-dns.nix {
    inherit lib kix;
    inherit (config) clusterDomain;
  };
in
{
  cluster.provider = lib.mkDefault "scaleway";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "cilium (kapsule-managed)";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "scaleway-lb (paid add-on)";
    };
  };

  # Kapsule node images keep unpacked containerd layers so Spegel peers can
  # serve them.
  cluster.containerd.discardUnpackedLayers = lib.mkDefault false;

  cluster.capabilities = {
    multiNode = lib.mkDefault true;
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
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
          # Default StorageClass on Kapsule. Override per cluster for other
          # block classes or `sfs-standard`.
          storageClassName = "sbs-default";
          name = "sbs-default";
        };
      };
    };
  };
}
