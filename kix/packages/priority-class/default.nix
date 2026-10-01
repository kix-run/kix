# priority-class: one Kubernetes PriorityClass, named after the instance.
#
# The class is cluster-scoped. The instance's namespace holds only its
# PackageInstance record, so put it in any namespace the cluster deploys, such as
# the namespace of its main consumer. Requires `value`.
#
#   instances.platform.batch-low = { package = packages.priority-class; config.value = -10; };
#
# A package takes the class as an optional dependency and reads its name, which
# also orders the workload after the class:
#   build = { priorityClass ? null, ... }: ...
#     lib.optionalAttrs (priorityClass != null) { priorityClassName = priorityClass.out.name; }
# and the cluster wires it explicitly:
#   deps.priorityClass = ref.platform.batch-low;
#
# out: the PriorityClass's `out` (`out.name`). Labels and annotations go through
# partsOverlays. `value` and `preemptionPolicy` cannot change after creation.

{
  scope,
  lib,
}:

{
  meta = {
    description = "One PriorityClass, named after the instance";
    owner = "platform";
    # No defaultAliases: an alias would bind every package's unwired optional
    # `priorityClass` dependency to this class. Consumers wire it explicitly.
  };

  options = {
    value = lib.mkOption {
      type = lib.types.ints.between (-2147483648) 1000000000;
      example = 1000;
      description = ''
        Scheduling priority, from -2147483648 to 1000000000. Higher values are
        reserved for the `system-` classes. Kubernetes refuses a change after
        creation: create a class under a new instance name and move workloads
        to it.
      '';
    };
    description = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Text shown by `kubectl describe`. Omitted when null.";
    };
    globalDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use this class for pods that name none. At most one class in a cluster
        may set it; the build fails when two do. Pods that already exist keep
        their priority.
      '';
    };
    preemptionPolicy = lib.mkOption {
      type = lib.types.enum [
        "PreemptLowerPriority"
        "Never"
      ];
      default = "PreemptLowerPriority";
      description = ''
        `Never` queues pods ahead of lower-priority pods without evicting them.
        Kubernetes refuses a change after creation.
      '';
    };
  };

  build =
    {
      self,
      config,
      ...
    }:
    let
      name = scope.instanceName;
    in
    assert lib.assertMsg (!lib.hasPrefix "system-" name)
      "priority-class ${scope.namespaceName}/${name}: the instance name becomes the PriorityClass name, and Kubernetes reserves the 'system-' prefix for its built-in classes (system-cluster-critical, system-node-critical). Rename the instance. A workload that needs a built-in class names it in its pod spec; those classes exist in every cluster.";
    {
      priorityClass = scope.mkClusterResource {
        apiVersion = "scheduling.k8s.io/v1";
        kind = "PriorityClass";
        inherit name;
        # globalDefault is omitempty in the API, so the live object has no
        # `globalDefault: false` to compare. The apiserver stores a default
        # preemptionPolicy, so it is always rendered.
        extra = {
          inherit (config) value preemptionPolicy;
        }
        // lib.optionalAttrs (config.description != null) { inherit (config) description; }
        // lib.optionalAttrs config.globalDefault { globalDefault = true; };
      };
      root = self.priorityClass;
    };
}
