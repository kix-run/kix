# Flavor: GKE Autopilot — fully managed GKE with hard platform restrictions.
#
# Google manages both control plane and worker nodes. Significant restrictions:
# - No privileged pods, hostNetwork, hostPID, hostIPC, hostPath volumes
# - No DaemonSets (platform manages node-level daemons)
# - Minimum resource requests enforced (0.25 vCPU, 0.5 GiB per container)
# - Cannot deploy to kube-system
# - Baseline PSA enforcement
# - Mutating admission webhooks have restrictions
#
# Platform imports: DNS (kube-dns), storage (premium-rwo via PD CSI).
# Note: kube-system imports use gke-managed namespace since Autopilot
# blocks user deployments to kube-system.

{ lib, kix, ... }:
{
  cluster.provider = lib.mkDefault "gke-autopilot";

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault true; # fully automatic, not configurable
    loadBalancer = lib.mkDefault true;
    cni = lib.mkDefault "gke-native";
    networkPolicyAPI = lib.mkDefault "k8s"; # CiliumNetworkPolicy not available
    ingressController = lib.mkDefault "gce";
    persistentStorage = lib.mkDefault true;
    volumeSnapshots = lib.mkDefault true;

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
        out = {
          name = "kube-dns";
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      aliases = [ "dns" ];
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        out = {
          storageClassName = "premium-rwo";
        };
      };
      aliases = [ "storageClasses" ];
      optional = true;
    };
  };
}
