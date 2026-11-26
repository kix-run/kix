# GKE Standard flavor.
#
# GKE Standard provides a managed control plane, GKE Dataplane V2 (exclusive
# `cni` role), `kube-dns`, GCP Network Load Balancer, and the PD CSI driver
# with `standard-rwo` as the default StorageClass.
#
# Dataplane V2 always enforces standard Kubernetes NetworkPolicy and does not
# serve CiliumNetworkPolicy. Kix generates only CiliumNetworkPolicy today, and
# no enforcer can claim the role here, so `networkPolicy.enable = true` fails
# evaluation on this flavor.
#
# Pods get Google Cloud identities through Workload Identity Federation for
# GKE, which the `cloud-identity` import declares.
#
# GKE enables NodeLocal DNSCache by default from version 1.34.1, so pods send
# DNS queries to a cache on their own node. The `platform-dns` import lists
# that cache among the DNS peers (`gke-dns-peers.nix`).
#
# Kix does not model these GKE features, so the flavor does not declare them:
# - Google Cloud Managed Service for Prometheus. It reads its own
#   `monitoring.googleapis.com` resources, not ServiceMonitor or
#   PrometheusRule.
# - The Service range. Since GKE 1.27 it defaults to a range that Google
#   owns, which is not a private RFC 1918 range.

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
  platformNetworkPolicy = import ./platform-network-policy.nix {
    inherit lib kix;
    inherit (config.cluster) network;
  };
  mechanisms = import ../vocab/cloud-identity-mechanisms.nix { inherit lib; };
in
{
  cluster.provider = lib.mkDefault "gke";
  # The cloud runs and upgrades the pods in kube-system, so Kix writes no
  # default deny there.
  networkPolicy.platformNamespaces = lib.mkDefault [ "kube-system" ];

  cluster.roles = {
    cni = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "gke-native (dataplane v2)";
    };
    # Dataplane V2 always enforces the standard NetworkPolicy, and a second
    # enforcer such as Cilium cannot run beside it.
    network-policy-enforcer = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "GKE Dataplane V2";
    };
    dns.binding = lib.mkDefault "shadowable";
    storageClasses.binding = lib.mkDefault "shadowable";
    loadBalancer = {
      binding = lib.mkDefault "shadowable";
      provider = lib.mkDefault "gcp-network-lb";
    };
    # GKE runs a managed metrics-server in kube-system.
    metricsApi = {
      binding = lib.mkDefault "exclusive";
      provider = lib.mkDefault "metrics-server (gke-managed)";
    };
  };

  # GKE nodes enable `discard_unpacked_layers` by default. Clusters that apply
  # a node startup script for Spegel set `discardUnpackedLayers = false`.
  # A default GKE node sets no registry `config_path` and has no
  # `/etc/containerd/hosts.d`, so containerd reads mirrors from this path only
  # when such a script or GKE's containerd configuration sets it.
  cluster.containerd = {
    registryConfigPath = lib.mkDefault "/etc/containerd/hosts.d";
    discardUnpackedLayers = lib.mkDefault true;
  };

  cluster.capabilities = {
    # A new GKE node pool has three nodes in each zone.
    multiNode = lib.mkDefault true;
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault false; # available per node pool, off by default
    daemonSets = lib.mkDefault true;
    gpu = lib.mkDefault false; # requires a GPU node pool
    privilegedContainers = lib.mkDefault true;
    podSecurityEnforcement = lib.mkDefault null;
    # GKE creates the ResourceQuota `gcp-critical-pods` for these classes in
    # `kube-system`, and its quota admission refuses them where no such
    # quota exists.
    criticalPriorityNamespaces = lib.mkDefault [ "kube-system" ];
  };

  cluster.network = {
    podCidr = lib.mkDefault null;
    serviceCidr = lib.mkDefault null;
  };

  # The API server calls admission webhooks and aggregated APIs through the
  # konnectivity-agent pods in kube-system, which a live GKE Standard
  # cluster showed. A private cluster or one without konnectivity is
  # untested.
  cluster.network.apiServer.sources = lib.mkDefault [
    {
      namespace = "kube-system";
      podSelector."k8s-app" = "konnectivity-agent";
    }
  ];

  instances.kube-system = {
    platform-dns = platformDns {
      name = "kube-dns";
      namespace = "kube-system";
      peers = import ./gke-dns-peers.nix;
    };

    cloud-identity = platformCloudIdentity { mechanism = mechanisms.gke { }; };

    # How Dataplane V2 matches an ipBlock, each tested on a live GKE cluster:
    # never against pod addresses, against node addresses when the ipBlock
    # covers the node range, and after Service address translation.
    platform-network-policy = platformNetworkPolicy {
      provider = "GKE Dataplane V2";
      ipBlockSelectsPods = false;
      ipBlockSelectsNodes = true;
      ipBlockSeesServiceAddress = false;
    };

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
