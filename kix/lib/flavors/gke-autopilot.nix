# GKE Autopilot flavor.
#
# Google manages both the control plane and worker nodes. Autopilot forbids
# privileged containers, DaemonSets, and user deployments in `kube-system`,
# enforces the `baseline` Pod Security Standard, and owns `cni` and
# `loadBalancer` exclusively.

{
  config,
  lib,
  kix,
  ...
}:
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
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        roles = [ "dns" ];
        out = {
          name = "kube-dns";
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
          storageClassName = "premium-rwo";
          name = "premium-rwo";
        };
      };
    };
  };
}
