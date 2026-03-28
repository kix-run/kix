# Flavor: GKE Autopilot — fully managed GKE with hard platform restrictions.
#
# Google manages both control plane and worker nodes. Significant restrictions:
# - No privileged pods, hostNetwork, hostPID, hostIPC, hostPath volumes
# - No DaemonSets (platform manages node-level daemons)
# - Minimum resource requests enforced (0.25 vCPU, 0.5 GiB per container)
# - Cannot deploy to kube-system
# - Baseline PSA enforcement
# - Mutating admission webhooks have restrictions

{ lib, ... }:
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
}
