# Shared helper namespace for cluster definitions, package evaluation, and tests.
# Import this module to include composition, availability, and pin helpers.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
  storageClass = import ./storage-class.nix { inherit lib; };
  availability = import ../core/availability.nix { inherit lib; };
  scorecard = import ../scorecard.nix { inherit lib; };
  oidcProvider = import ./oidc-provider.nix { inherit lib; };
in
compose
// {
  types = compose.types // {
    # StorageClass fields as a submodule: kix.types.storageClass { }
    # (vocab/storage-class.nix).
    storageClass = storageClass.type;
  };
  # Renders StorageClasses from kix.types.storageClass values and picks the
  # class for consumers that name none (vocab/storage-class.nix).
  storage.mkClasses = storageClass.mkClasses;
  # The `out` a `database` provider publishes, with `check` for providers
  # and `assertions` for consumers (vocab/postgres-database.nix).
  contracts.postgresDatabase = import ./postgres-database.nix { inherit lib; };
  # The `out` an `otlp` provider publishes, its OTLP/gRPC and OTLP/HTTP
  # base URLs, with `check` and `assertions` (vocab/otlp-endpoint.nix).
  contracts.otlpEndpoint = import ./otlp-endpoint.nix { inherit lib; };
  # The `out` a `gateway` provider publishes, with `check` for providers;
  # kix.expose holds its gateway to it (vocab/gateway.nix).
  contracts.gateway = import ./gateway.nix { inherit lib; };
  # The `out` an `oidcProvider` publishes, its issuer and endpoints per
  # realm, with `check`, `assertions`, and `requireClient`
  # (vocab/oidc-provider.nix).
  contracts.oidcProvider = oidcProvider;
  # The `oidc` option of an application that signs users in through an
  # oidcProvider: kix.options.oidc { scopes; autoLogin; }.
  options = compose.options // {
    oidc = oidcProvider.clientOptions;
  };
  # Map availability levels to package replica counts and quorums:
  # kix.availability.pick level { none = 1; pod = 2; node = 2; zone = 3; }
  # kix.availability.atLeast "node" level
  # A workload that runs one pod at a time sets one replica and the ceiling
  # "none" (availability.max on its builder call, or meta.availability.max
  # for a limit of the program); more than one replica under it is an error.
  # A package with meta.availability.max receives an atLeast that refuses a
  # threshold above the ceiling (eval/instance.nix packageKix,
  # core/availability.nix underCeiling).
  # Spread for operator-placed operands: kix.availability.spreadConstraints
  # (core/availability.nix).
  availability = {
    inherit (availability)
      levels
      pick
      atLeast
      rank
      spreadConstraints
      ;
  };
  # The severity a scorecard rule resolves to for this cluster and
  # namespace, after overrides and the cluster's cap, as the scorecard
  # itself resolves it. null when the rule does not run: the scorecard is
  # off, the rule is not in its rule set, or an override disables it.
  # A package reads it to replace a finding its own option causes with
  # advice specific to that option:
  #   kix.scorecard.effectiveSeverity {
  #     inherit clusterConfig;
  #     rule = "security.nonRoot";
  #     namespaceName = scope.namespaceName;
  #     owner = "app-team";
  #   }
  scorecard.effectiveSeverity =
    {
      clusterConfig,
      rule,
      namespaceName,
      owner ? null,
    }:
    let
      sc = clusterConfig.scorecard or { };
      path = lib.splitString "." rule;
      ruleDef = lib.attrByPath path null (sc.rules or { });
    in
    if !(sc.enable or false) || ruleDef == null then
      null
    else
      scorecard.resolveEffectiveSeverity {
        ruleName = rule;
        rule = ruleDef;
        ruleDefaults = sc.ruleDefaults or { };
        ruleOverrides = sc.ruleOverrides or { };
        maxSeverity = sc.maxSeverity or "error";
        inherit namespaceName owner;
      };
  pins = import ./pins.nix {
    inherit lib;
    inherit (compose) image;
  };
}
