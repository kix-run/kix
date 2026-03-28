# Flavor: GKE Standard — Google Kubernetes Engine (standard mode).
#
# Managed control plane. GKE dataplane v2 (eBPF/Cilium-based) is the
# default CNI but exposes only k8s-standard NetworkPolicy, not CiliumNetworkPolicy.
# Built-in GCE ingress controller. PD CSI with volume snapshot support.

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "gke";

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    loadBalancer = lib.mkDefault true;
    cni = lib.mkDefault "gke-native"; # dataplane v2 (eBPF, Cilium internals)
    networkPolicyAPI = lib.mkDefault "k8s"; # CiliumNetworkPolicy not exposed to users
    ingressController = lib.mkDefault "gce"; # GCP HTTP(S) Load Balancer
    persistentStorage = lib.mkDefault true; # pd-balanced / pd-ssd
    volumeSnapshots = lib.mkDefault true; # snapshot CRDs + controller pre-installed
    nodeAutoscaling = lib.mkDefault false; # available per node pool, not on by default
  };
}
