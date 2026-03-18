# PriorityClass package — cluster scheduling priority classes.
#
# Defines scheduling priority classes for workloads. Each PriorityClass is
# cluster-scoped (no namespace).
#
# Config allows full customization of the priority class list. Each class
# supports: value (required), description, globalDefault, preemptionPolicy.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    classes = { };
  };

  mkPriorityClass =
    name: spec:
    scope.mkClusterResource {
      apiVersion = "scheduling.k8s.io/v1";
      kind = "PriorityClass";
      inherit name;
      extra =
        { value = spec.value; }
        // (if spec ? description && spec.description != "" then { description = spec.description; } else { })
        // (if spec ? globalDefault && spec.globalDefault then { globalDefault = true; } else { })
        // (if spec ? preemptionPolicy then { preemptionPolicy = spec.preemptionPolicy; } else { });
    };

  classResources = lib.mapAttrs mkPriorityClass cfg.classes;
  classList = builtins.attrValues classResources;

  # Pick a main resource: first globalDefault, or first class alphabetically
  mainName =
    let
      globalDefaults = lib.filterAttrs (_: spec: spec ? globalDefault && spec.globalDefault) cfg.classes;
      globalNames = builtins.attrNames globalDefaults;
    in
    if globalNames != [ ] then builtins.head globalNames
    else builtins.head (builtins.attrNames cfg.classes);

in
self:
classResources
// {
  main = {
    resource = self.${mainName};
    requires = classList;
  };
}
