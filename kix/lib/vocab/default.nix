# Shared helper namespace for cluster definitions, package evaluation, and tests.
# Import this module to include composition, availability, and pin helpers.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
  durations = import ./durations.nix { inherit lib; };
  storageClass = import ./storage-class.nix { inherit lib; };
  availability = import ../core/availability.nix { inherit lib; };
  scorecard = import ../scorecard.nix { inherit lib; };
  oidcProvider = import ./oidc-provider.nix { inherit lib; };
  smtp = import ./smtp.nix { inherit lib; };
  quotaUse = import ./quota-use.nix { inherit lib; };
in
compose
// {
  types =
    compose.types
    // durations.types
    // {
      # Define a StorageClass submodule option (`vocab/storage-class.nix`).
      storageClass = storageClass.type;
    };
  # Render StorageClasses from `kix.types.storageClass` values and pick the
  # default class for consumers that do not name one (`vocab/storage-class.nix`).
  storage.mkClasses = storageClass.mkClasses;
  # Validate and consume `database` provider outputs (`vocab/postgres-database.nix`).
  contracts.postgresDatabase = import ./postgres-database.nix { inherit lib; };
  # Validate and consume `otlp` provider outputs (`vocab/otlp-endpoint.nix`).
  contracts.otlpEndpoint = import ./otlp-endpoint.nix { inherit lib; };
  # Validate and consume `gateway` provider outputs (`vocab/gateway.nix`).
  contracts.gateway = import ./gateway.nix { inherit lib; };
  # Validate and consume `oidcProvider` outputs (`vocab/oidc-provider.nix`).
  contracts.oidcProvider = oidcProvider;
  # Validate and consume `smtp` outputs (`vocab/smtp.nix`).
  contracts.smtp = smtp;
  # Build the `oidc` option set for an application that signs users in through
  # an `oidcProvider`.
  options = compose.options // {
    oidc = oidcProvider.clientOptions;
    # The `mail.from` sender override for a package that takes `smtp`.
    mail = smtp.options;
  };
  # Map availability levels to replica counts, quorums, and topology spread
  # constraints (`core/availability.nix`). Single-replica workloads set a
  # ceiling of "none" via `availability.max` on the builder call or
  # `meta.availability.max` on the package.
  availability = {
    inherit (availability)
      levels
      pick
      atLeast
      rank
      spreadConstraints
      ;
  };
  # Resolve the effective severity of a scorecard rule for this cluster and
  # namespace, or return null when the scorecard or rule is disabled. Packages
  # use this to replace generic scorecard findings with option-specific advice.
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
  # Build the usage a CRD's `usesAtLeast` returns: one pod's usage from its
  # containers, a usage times a count, and the sum of several usages
  # (`vocab/quota-use.nix`).
  usage = quotaUse.helpers;
  # Convert Prometheus durations and compute staleness thresholds for scheduled
  # jobs (`vocab/durations.nix`).
  inherit (durations) durations schedules;
  pins = import ./pins.nix {
    inherit lib;
    inherit (compose) image;
  };
}
