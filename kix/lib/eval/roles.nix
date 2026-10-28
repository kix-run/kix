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

rec {
  registry = {
    "network-policy-enforcer" = {
      description = "NetworkPolicy enforcement engine (CNP-capable CNI). Consumed by the netpol plugin and the scope.networkPolicyEnforcer handle.";
      outContract = [ "netpol" ];
    };

    dns = {
      description = "Cluster DNS provider. Workloads take a store-path dependency on its root for readiness ordering; consumers read out.fqdn.";
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
      throw (
        "kix: unknown role '${role}' (${context}). ${knownRolesHint}. "
        + "Choose a supported role from this list. For dependency aliases, use meta.defaultAliases."
      );

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
      throw (
        "kix: '${providerLabel}' declares role '${role}' but its out is missing required fields. Add these fields to the provider package: "
        + "${builtins.concatStringsSep ", " missing}"
      )
    else
      out;
}
