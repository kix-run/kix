# PriorityClass package — cluster scheduling priority classes.
#
# Defines scheduling priority classes for workloads. Each PriorityClass is
# cluster-scoped (no namespace).
#
# Config allows full customization of the priority class list. Each class
# supports: value (required), description, globalDefault, preemptionPolicy.

{
  scope,
  lib,
}:

let
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

in
{
  options = {
    classes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };
  build =
    { self, config, clusterConfig }:
    let
      classResources = lib.mapAttrs mkPriorityClass config.classes;
      classList = builtins.attrValues classResources;

      # Pick a main resource: first globalDefault, or first class alphabetically
      mainName =
        let
          globalDefaults = lib.filterAttrs (_: spec: spec ? globalDefault && spec.globalDefault) config.classes;
          globalNames = builtins.attrNames globalDefaults;
        in
        if globalNames != [ ] then builtins.head globalNames
        else builtins.head (builtins.attrNames config.classes);

    in
    classResources
    // {
      main = {
        resource = self.${mainName};
        requires = classList;
      };
    };
}
