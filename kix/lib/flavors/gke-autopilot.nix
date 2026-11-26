# GKE Autopilot flavor.
#
# Google manages both the control plane and worker nodes, and adds nodes as
# pods need them. GKE's own admission webhook, not Pod Security Admission
# labels, refuses privileged containers, host namespaces such as
# `hostNetwork`, writable `hostPath` volumes, and any workload in a
# GKE-managed namespace such as `kube-system`. Its policy covers every rule
# of the `baseline` Pod Security Standard. DaemonSets are allowed. Autopilot
# owns `cni` and `loadBalancer` exclusively, and its default StorageClass is
# `standard-rwo`.
#
# NodeLocal DNSCache is always on in Autopilot. The `platform-dns` import
# lists it among the DNS peers (`gke-dns-peers.nix`).
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
  cluster.provider = lib.mkDefault "gke-autopilot";
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
    # Autopilot adds a node when a pod does not fit on the existing ones.
    multiNode = lib.mkDefault true;
    managedControlPlane = lib.mkDefault true;
    nodeAutoscaling = lib.mkDefault true;
    privilegedContainers = lib.mkDefault false;
    podSecurityEnforcement = lib.mkDefault "baseline";
    daemonSets = lib.mkDefault true;
    # GKE admits the built-in critical PriorityClasses only in namespaces
    # with a ResourceQuota for them, and Autopilot refuses user workloads in
    # `kube-system`, the one such namespace a user could name.
    criticalPriorityNamespaces = lib.mkDefault [ ];
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

  # Place platform imports in `gke-managed` because Autopilot refuses user
  # objects in `kube-system`. Each import names the namespace of the object
  # it stands for.
  instances.gke-managed = {
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
      # Google documents that a VPC-native cluster, which Dataplane V2
      # requires, gives nodes the subnet's primary range and pods and
      # Services other ranges. On a live GKE cluster, leaving the node range
      # out of `0.0.0.0/0` kept internet egress working.
      nodeRangeHoldsOnlyNodes = true;
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
