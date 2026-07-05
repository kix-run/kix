# Flavor: GKE Standard — Google Kubernetes Engine (standard mode).
#
# Managed control plane. GKE dataplane v2 (eBPF/Cilium-based) is the
# default CNI but exposes only k8s-standard NetworkPolicy, not
# CiliumNetworkPolicy — the cni role is environment-owned (exclusive).
# Built-in GCE ingress controller. PD CSI with volume snapshot support.
#
# Platform imports: DNS (kube-dns), storage (standard-rwo via PD CSI).
# These participate in DI so packages can resolve against them. If the
# cluster installs its own storage-classes or DNS package, it takes
# priority automatically (managed shadows import in DI resolution).

{ lib, kix, ... }:
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
  };

  cluster.capabilities = {
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, not on by default
    daemonSets = lib.mkDefault true;
    gpu = lib.mkDefault false; # requires GPU node pool
    privilegedContainers = lib.mkDefault true; # restricted on Autopilot, not Standard
    podSecurityEnforcement = lib.mkDefault null; # no cluster-wide PSA by default
  };

  cluster.network = {
    podCidr = lib.mkDefault null; # varies by VPC-native vs routes-based
    serviceCidr = lib.mkDefault null; # varies by cluster configuration
  };

  # --- Platform-provided imports ---
  # GKE manages these services; they exist in the cluster but are not
  # kix-managed. Exposed as imports so packages can depend on them via DI.

  instances.kube-system = {
    platform-dns = {
      package = kix.mkImport {
        kind = "Deployment";
        apiVersion = "apps/v1";
        roles = [ "dns" ];
        out = {
          name = "kube-dns";
          fqdn = "kube-dns.kube-system.svc.cluster.local";
        };
      };
      optional = true;
    };

    platform-storage = {
      package = kix.mkImport {
        roles = [ "storageClasses" ];
        out = {
          storageClassName = "standard-rwo";
          rwx = false; # requires Filestore CSI addon
          snapshots = true; # snapshot CRDs + controller pre-installed
        };
      };
      optional = true;
    };
  };
}
