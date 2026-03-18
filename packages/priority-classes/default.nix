# PriorityClass package — NW1 cluster priority classes.
#
# Defines scheduling priority classes for workloads. Each PriorityClass is
# cluster-scoped (no namespace). The `default-priority` class is the
# globalDefault, applied to pods that don't specify a priorityClassName.
#
# Config allows full customization of the priority class list.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    classes = {
      kubevirt-cluster-critical = {
        value = 1000000000;
        description = "KubeVirt cluster-critical workloads";
      };
      openebs-cluster-critical = {
        value = 1000000000;
        description = "OpenEBS cluster-critical workloads";
      };
      monitoring-prometheus = {
        value = 1100;
        description = "Prometheus monitoring stack";
      };
      monitoring-loki = {
        value = 1000;
        description = "Loki logging stack";
      };
      high-priority = {
        value = 1000;
        description = "High priority workloads (shopfront-prod, ledgerly-prod)";
      };
      default-priority = {
        value = 500;
        globalDefault = true;
        description = "Default priority for all workloads";
      };
      reloader-priority-class = {
        value = 2000;
        description = "Reloader controller";
      };
      arc-runners = {
        value = 100;
        description = "GitHub Actions runner controller runners";
      };
    };
  };

  mkPriorityClass =
    name: spec:
    scope.mkClusterResource {
      apiVersion = "scheduling.k8s.io/v1";
      kind = "PriorityClass";
      inherit name;
      extra = {
        value = spec.value;
        globalDefault = spec.globalDefault or false;
        description = spec.description or "";
      };
    };

  classResources = lib.mapAttrs mkPriorityClass cfg.classes;
  classList = builtins.attrValues classResources;

in
self:
classResources
// {
  main = {
    resource = self.default-priority;
    requires = classList;
  };
}
