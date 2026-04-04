# Built-in scorecard rules: Governance
#
# Checks for ownership, descriptions, and label standards.
#
# See v2_discussions/60_scorecard_rules_design.md §Built-in rule library.

{ lib }:

let
  isWorkload =
    resource:
    builtins.elem (resource.kind or "") [
      "Deployment"
      "StatefulSet"
      "DaemonSet"
    ];
in
{
  hasOwner = {
    description = "Every package must declare an owner";
    level = "package";
    severity = "warning";
    tags = [
      "governance"
      "ownership"
    ];
    check =
      { meta, instanceName, ... }:
      if (meta.owner or null) == null then
        [ { message = "package '${instanceName}' has no meta.owner"; } ]
      else
        [ ];
  };

  hasDescription = {
    description = "Packages should have a description";
    level = "package";
    severity = "info";
    tags = [
      "governance"
      "documentation"
    ];
    check =
      { meta, instanceName, ... }:
      let
        desc = meta.description or null;
      in
      if desc == null || desc == "" then
        [ { message = "package '${instanceName}' has no meta.description"; } ]
      else
        [ ];
  };

  labelStandards = {
    description = "Resources should have standard Kubernetes labels";
    level = "manifest";
    severity = "info";
    tags = [
      "governance"
      "labels"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        labels = resource.metadata.labels or { };
        requiredLabels = [
          "app.kubernetes.io/name"
          "app.kubernetes.io/managed-by"
        ];
        missing = builtins.filter (l: !(labels ? ${l})) requiredLabels;
      in
      map (l: {
        message = "resource '${resource.metadata.name or "unnamed"}' missing label '${l}'";
      }) missing;
  };
}
