# PriorityClass package: cluster scheduling priority classes.
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
      extra = {
        value = spec.value;
        preemptionPolicy = spec.preemptionPolicy or "PreemptLowerPriority";
      }
      // (
        if spec ? description && spec.description != "" then { description = spec.description; } else { }
      )
      // (if spec ? globalDefault && spec.globalDefault then { globalDefault = true; } else { });
    };

in
{
  meta = {
    version = "1.0.0";
    description = "Cluster-scoped PriorityClasses that set workload scheduling priority";
    owner = "platform";
  };

  options = {
    classes = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };
  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      classResources = lib.mapAttrs mkPriorityClass config.classes;
      classList = builtins.attrValues classResources;

      # Pick a main resource: first globalDefault, or first class alphabetically
      mainName =
        let
          globalDefaults = lib.filterAttrs (
            _: spec: spec ? globalDefault && spec.globalDefault
          ) config.classes;
          globalNames = builtins.attrNames globalDefaults;
        in
        if globalNames != [ ] then
          builtins.head globalNames
        else if config.classes != { } then
          builtins.head (builtins.attrNames config.classes)
        else
          throw "priority-classes '${scope.instanceName}': `classes` is empty. Set at least one class, for example `config.classes.high.value = 1000;`.";

    in
    classResources
    // {
      root = {
        resource = self.${mainName};
        requires = classList;
      };
    };
}
