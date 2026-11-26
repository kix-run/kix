# Define the fixed set of cluster infrastructure roles that packages can claim
# via `meta.roles`. Each role name also serves as a dependency alias, populates
# the provider index, and is checked against environment role bindings
# (`cluster.roles.<name>.binding`) at evaluation time.
#
# Out-contracts check only top-level attribute presence on the provider's `out`
# and run lazily through `findRoleProvider` so provider instances are not
# forced out of fixpoint order. Consumers validate deeper interface shapes
# (such as `plugins/netpol/interface.nix`).

{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
in
rec {
  registry = {
    "network-policy-enforcer" = {
      description = "NetworkPolicy enforcement engine (CNP-capable CNI). Consumed by the netpol plugin and the scope.networkPolicyEnforcer handle.";
      outContract = [ "netpol" ];
    };

    dns = {
      description = "Cluster DNS provider. Workloads take a store-path dependency on its root for readiness ordering; consumers read out.fqdn. An import may set out.dnsPeers (core/dns-peers.nix), the endpoints the network policy enforcer opens DNS to; without it, and for a managed provider, the peers are the kube-dns pods in kube-system.";
      outContract = [ "fqdn" ];
    };

    storageClasses = {
      description = "StorageClass provider. Consumers (persistent-volume-claim, stackgres-cluster, ...) read out.storageClassName, the class a claim uses when it names none.";
      outContract = [ "storageClassName" ];
    };

    cni = {
      description = "Pod network owner. No out contract yet. The role exists for binding-mode conflicts: an exclusive environment CNI (kindnet on stock kind) refuses a managed one at eval instead of breaking the cluster at deploy. Under shadowable the environment installed the CNI, usually declared as a platform import claiming this role (rke2: platform-cilium), and a claimant such as the cilium package configures or uses it.";
      outContract = [ ];
    };

    loadBalancer = {
      description = "Service type=LoadBalancer implementation. Presence (managed provider or environment binding) gates LoadBalancer Services.";
      outContract = [ ];
    };

    metricsApi = {
      description = "The resource metrics API (metrics.k8s.io), one per cluster. Presence (managed provider or environment binding) gates HorizontalPodAutoscalers on resource metrics and the descheduler's KubernetesMetrics source. An environment that runs its own metrics-server binds the role exclusive, so a second APIService for metrics.k8s.io is refused at eval.";
      outContract = [ ];
    };

    registryMirror = {
      description = "Node-local OCI registry mirror that containerd on every node tries before the upstream registry (Spegel), one per cluster. No out contract: the role exists for binding-mode conflicts. k3s and RKE2 embed Spegel behind `embedded-registry: true`; a cluster that turns it on binds the role exclusive, so a spegel instance is refused at eval.";
      outContract = [ ];
    };

    gatewayApi = {
      description = "Kubernetes Gateway API CRDs (gateway.networking.k8s.io), one set per cluster. Gateway API controllers read CRD handles from out.crds. Environments that pre-install these CRDs set cluster.roles.gatewayApi.binding = \"exclusive\" so Kix rejects a duplicate managed set during evaluation.";
      outContract = [ "crds" ];
    };

    cloudIdentity = {
      description = "Configures pod cloud identities on AWS, Google Cloud, or Azure (EKS IRSA or Pod Identity, Workload Identity Federation for GKE, Microsoft Entra Workload ID on AKS, or a self-hosted webhook). The provider exposes a cloud identity mechanism at out.cloudIdentity, which renders kix.cloudIdentity.aws, kix.cloudIdentity.gcp, and kix.cloudIdentity.azure dependencies into ServiceAccount annotations and pod labels. The eks, gke, gke-autopilot, and aks flavors provide this role as an import; a managed package claiming the role overrides the import.";
      outContract = [ "cloudIdentity" ];
    };

    snapshotController = {
      description = "CSI snapshot controller and the snapshot.storage.k8s.io API, one per cluster. Consumers build VolumeSnapshotClass and VolumeSnapshot through out.crds. An environment that runs its own controller binds the role exclusive, so a second, managed controller is refused at eval.";
      outContract = [ "crds" ];
    };
  };

  roleNames = builtins.attrNames registry;

  knownRolesHint = "Known roles: ${builtins.concatStringsSep ", " roleNames}";

  # Validate that `role` is a registered role name.
  assertKnownRole =
    context: role:
    if registry ? ${role} then
      role
    else
      fail {
        message = "unknown role '${role}' (${context}). ${knownRolesHint}.";
        fix = "Choose a supported role from this list. For dependency aliases, use meta.defaultAliases.";
      };

  # Verify that `out` contains all attributes required by `role` and return `out`.
  checkOutContract =
    {
      role,
      providerLabel,
      out,
    }:
    let
      required = registry.${role}.outContract;
      missing = if out == null then required else builtins.filter (attr: !(out ? ${attr})) required;
    in
    if required != [ ] && missing != [ ] then
      fail {
        message = "'${providerLabel}' declares role '${role}' but its out is missing required fields.";
        fix = "Add these fields to the provider package: ${builtins.concatStringsSep ", " missing}.";
      }
    else
      out;
}
