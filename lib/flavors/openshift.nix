# Flavor: OpenShift — Red Hat's enterprise Kubernetes platform.
#
# Significant security posture: SCC (Security Context Constraints) enforce
# restricted-v2 by default — all containers run as random non-root UIDs.
# Images that hardcode USER root will fail without explicit SCC grants.
#
# Uses OVN-Kubernetes CNI, HAProxy-based Router (not Ingress) for external
# access, and cri-o (not containerd) as container runtime.
#
# On cloud providers: LoadBalancer and persistent storage work via cloud CSI.
# On bare metal: no default LoadBalancer or StorageClass.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "openshift";

  cluster.capabilities = {
    loadBalancer = lib.mkDefault false; # true on cloud, false on bare metal — override as needed
    cni = lib.mkDefault "ovn-kubernetes";
    networkPolicyAPI = lib.mkDefault "k8s"; # OVN-Kubernetes enforces k8s NetworkPolicy
    ingressController = lib.mkDefault "openshift-router"; # HAProxy-based, uses Route objects
    persistentStorage = lib.mkDefault false; # depends on platform — override for cloud
    volumeSnapshots = lib.mkDefault false; # available on cloud with CSI, not on bare metal

    # OpenShift's defining characteristic: restricted security by default
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "restricted"; # SCC restricted-v2
  };
}
