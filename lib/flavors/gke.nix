# Flavor: GKE Standard — Google Kubernetes Engine (standard mode).
#
# Managed control plane. GKE dataplane v2 (eBPF/Cilium-based) is the
# default CNI but exposes only k8s-standard NetworkPolicy, not CiliumNetworkPolicy.
# Built-in GCE ingress controller. PD CSI with volume snapshot support.
#
# Note: GKE ships with GCE ingress controller (L7 HTTP(S) Load Balancer)
# but most production clusters deploy ingress-nginx instead for more control
# over routing and TLS. Override with:
#   cluster.capabilities.ingressController = "nginx";

{ lib, ... }:
{
  cluster.provider = lib.mkDefault "gke";

  cluster.capabilities = {
    # --- Topology ---
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, not on by default

    # --- Networking ---
    loadBalancer = lib.mkDefault true; # GCP Network Load Balancer
    cni = lib.mkDefault "gke-native"; # dataplane v2 (eBPF, Cilium internals)
    networkPolicyAPI = lib.mkDefault "k8s"; # CiliumNetworkPolicy not exposed to users
    ingressController = lib.mkDefault "gce"; # GCP HTTP(S) Load Balancer

    # --- Storage ---
    persistentStorage = lib.mkDefault true; # pd-balanced / pd-ssd via PD CSI driver
    volumeSnapshots = lib.mkDefault true; # snapshot CRDs + controller pre-installed
    rwxStorage = lib.mkDefault false; # requires Filestore CSI addon

    # --- Compute ---
    daemonSets = lib.mkDefault true;
    gpu = lib.mkDefault false; # requires GPU node pool

    # --- Security ---
    privilegedContainers = lib.mkDefault true; # restricted on Autopilot, not Standard
    podSecurityEnforcement = lib.mkDefault null; # no cluster-wide PSA by default
  };

  cluster.network = {
    podCidr = lib.mkDefault null; # varies by VPC-native vs routes-based
    serviceCidr = lib.mkDefault null; # varies by cluster configuration
    dnsDomain = lib.mkDefault "cluster.local";
  };
}
