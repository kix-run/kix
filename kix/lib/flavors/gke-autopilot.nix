# GKE Autopilot flavor with managed platform restrictions.
#
# Google manages both control plane and worker nodes. Significant restrictions:
# - No privileged pods, hostNetwork, hostPID, hostIPC, hostPath volumes
# - No DaemonSets (platform manages node-level daemons)
# - Minimum resource requests enforced (0.25 vCPU, 0.5 GiB per container)
# - Cannot deploy to kube-system
# - Baseline PSA enforcement
# - Mutating admission webhooks have restrictions
#
# cni and loadBalancer are environment-owned exclusively because Autopilot does
# not permit user-run network infrastructure.
#
# Platform imports: DNS (kube-dns), storage (premium-rwo via PD CSI). GKE
# creates the standard-rwo and premium-rwo StorageClasses with the PD CSI
# driver (https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/gce-pd-csi-driver).
# Note: kube-system imports use gke-managed namespace since Autopilot
# blocks user deployments to kube-system.

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
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault true; # fully automatic, not configurable

    # Hard restrictions
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "baseline";
    daemonSets = lib.mkDefault false;
  };

  # Platform-provided imports. Use gke-managed namespace since Autopilot
  # blocks user deployments to kube-system.
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
