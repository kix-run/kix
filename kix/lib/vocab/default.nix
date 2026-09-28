# Shared helper namespace for cluster definitions, package evaluation, and tests.
# Import this module to include composition, availability, and pin helpers.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
  availability = import ../core/availability.nix { inherit lib; };
  scorecard = import ../scorecard.nix { inherit lib; };
in
compose
// {
  # Map availability levels to package replica counts and quorums:
  # kix.availability.pick level { none = 1; pod = 2; node = 2; zone = 3; }
  # kix.availability.atLeast "node" level
  availability = {
    inherit (availability)
      levels
      pick
      atLeast
      rank
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
