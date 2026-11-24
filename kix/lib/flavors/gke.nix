# GKE Standard flavor.
#
# GKE Standard provides a managed control plane, GKE Dataplane V2 (exclusive
# `cni` role that exposes standard Kubernetes NetworkPolicy rather than
# CiliumNetworkPolicy), `kube-dns`, GCP Network Load Balancer, and the PD CSI
# driver with `standard-rwo` as the default StorageClass.
#
# Pods get Google Cloud identities through Workload Identity Federation for
# GKE, which the `cloud-identity` import declares.

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
  platformCloudIdentity = import ./cloud-identity.nix { inherit kix; };
  mechanisms = import ../vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  cluster.provider = lib.mkDefault "gke";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "gke-native (dataplane v2)";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "gcp-network-lb";
    };
    # GKE runs a managed metrics-server in kube-system.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (gke-managed)";
    };
  };

  # GKE nodes enable `discard_unpacked_layers` by default. Clusters that apply
  # a node startup script for Spegel set `discardUnpackedLayers = false`.
  cluster.containerd = {
    registryConfigPath = lib.mkDefault "/etc/containerd/hosts.d";
    discardUnpackedLayers = lib.mkDefault true;
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
    daemonSets = lib.mkDefault true;
    gpu = lib.mkDefault false; # requires a GPU node pool
    privilegedContainers = lib.mkDefault true;
    podSecurityEnforcement = lib.mkDefault null;
  };

  cluster.network = {
    podCidr = lib.mkDefault null;
    serviceCidr = lib.mkDefault null;
  };

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
    };

    cloud-identity = platformCloudIdentity { mechanism = mechanisms.gke { }; };

    platform-storage = {
      package = kix.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "standard-rwo";
          name = "standard-rwo";
        };
      };
    };
  };
}
