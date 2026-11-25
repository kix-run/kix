# GKE Autopilot flavor.
#
# Google manages both the control plane and worker nodes. Autopilot refuses
# privileged containers and workloads in GKE-managed namespaces such as
# `kube-system`. Its own admission policy includes every rule of the
# `baseline` Pod Security Standard. It owns `cni` and `loadBalancer`
# exclusively, and its default StorageClass is `standard-rwo`.
#
# NodeLocal DNSCache is always on in Autopilot. Kix does not model it.
#
# Pods get Google Cloud identities through Workload Identity Federation for
# GKE, which the `cloud-identity` import in `gke-managed` declares.
#
# No one has tested this flavor on a live Autopilot cluster. Its
# `daemonSets = false` does not come from Google's documentation.

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
  platformCloudIdentity = import ./cloud-identity.nix { inherit kix; };
  mechanisms = import ../vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  cluster.provider = lib.mkDefault "gke-autopilot";

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "gke-native (dataplane v2)";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "gcp-network-lb";
    };
    # GKE runs a managed metrics-server in kube-system.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (gke-managed)";
    };
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault true;
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "baseline";
    daemonSets = lib.mkDefault false;
  };

  # Place platform imports in `gke-managed` because Autopilot blocks user
  # resources in `kube-system`.
  instances.gke-managed = {
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
