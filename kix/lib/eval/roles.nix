# The compiler's closed vocabulary of infrastructure roles. A package claims
# a role through `meta.roles`; everything else derives from it: the role
# name doubles as a DI alias, the provider index is built from peeked roles,
# and binding-mode conflicts against environment-provided roles
# (`cluster.roles.<name>.binding`) are refused at eval.
#
# The vocabulary is closed on purpose: the old `meta.provides` was
# free-form, so a typo'd capability silently never matched. Adding a role
# here requires a consumer. `meta.unsafe` is the closed vocabulary for
# structural-rule escapes, while `meta.annotationDomains` is the open
# vocabulary for operator-owned annotation prefixes.
#
# Out-contracts are shallow (attribute presence on the provider's `out`).
# They are enforced lazily on the findRoleProvider path because eager checking
# would force provider instances out of fixpoint order. Deep contracts
# (e.g. the 13-attr enforcer interface) stay with their consumer
# (plugins/netpol/interface.nix).

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
      description = "Default StorageClass provider. Consumers (persistent-volume-claim, stackgres-cluster, ...) read out.storageClassName.";
      outContract = [ "storageClassName" ];
    };

    cni = {
      description = "Pod network owner. No out contract yet. The role exists for binding-mode conflicts: an exclusive environment CNI (kindnet on stock kind) refuses a managed one at eval instead of breaking the cluster at deploy.";
      outContract = [ ];
    };

    loadBalancer = {
      description = "Service type=LoadBalancer implementation. Presence (managed provider or environment binding) gates LoadBalancer Services.";
      outContract = [ ];
    };
  };

  roleNames = builtins.attrNames registry;

  knownRolesHint = "Known roles: ${builtins.concatStringsSep ", " roleNames}";

  # Validate a role name; `context` names the declaration site for the error.
  assertKnownRole =
    context: role:
    if registry ? ${role} then
      role
    else
      throw (
        "kix: unknown role '${role}' (${context}). ${knownRolesHint}. "
        + "Choose a supported role from this list. For dependency aliases, use meta.defaultAliases."
      );

  # Shallow out-contract check. Returns `out` so callers can wrap lazily;
  # throws naming both sides when a required attribute is missing.
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
