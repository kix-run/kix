# GKE Autopilot flavor.
#
# Google manages both the control plane and worker nodes. Autopilot forbids
# privileged containers, DaemonSets, and user deployments in `kube-system`,
# enforces the `baseline` Pod Security Standard, and owns `cni` and
# `loadBalancer` exclusively.
#
# Pods get Google Cloud identities through Workload Identity Federation for
# GKE, which the `cloud-identity` import in `gke-managed` declares.

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
          storageClassName = "premium-rwo";
          name = "premium-rwo";
        };
      };
    };
  };
}
