# Descheduler: evicts pods to rebalance cluster utilization.
#
# Wraps the upstream Kubernetes Descheduler Helm chart.
# Runs as a Deployment with periodic descheduling.
#
# Chart:   https://kubernetes-sigs.github.io/descheduler
# Name:    descheduler
# Version: 0.32.2

{
  scope,
  lib,
  kix,
  availability,
}:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://kubernetes-sigs.github.io/descheduler";
    name = "descheduler";
    version = "0.32.2";
    hash = "sha256-ARIFySRZdUP+k79s5m11ozvGp9GgKe7dTAOQoW5X4mQ=";
  };

  defaultValues = {
    # Deployment mode (not CronJob), matching the live cluster.
    kind = "Deployment";
    # One replica, and it does not follow the availability level. The
    # descheduler is a background rebalancer whose own downtime is not the
    # cluster's downtime, and this chart's leader election is not turned on
    # here, so a second replica would be a second controller evicting pods
    # against the same policy. The ceiling is declared in
    # `meta.availability.max` so a cluster at "node" or above gets no
    # shortfall warning for it.
    #
    # This was `0` until 2026-09-20, which made the package render a
    # Deployment that could never run: instantiating it did nothing and
    # said nothing. A package is on when a cluster asks for it.
    replicas = 1;

    deschedulingInterval = "5m";

    cmdOptions = {
      v = 3;
    };

    resources = {
      requests = {
        cpu = "10m";
        memory = "256Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };

    priorityClassName = "system-cluster-critical";

    deschedulerPolicyAPIVersion = "descheduler/v1alpha2";

    deschedulerPolicy = {
      profiles = [
        {
          name = "default";
          pluginConfig = [
            {
              name = "DefaultEvictor";
              args = {
                evictLocalStoragePods = true;
                ignorePvcPods = true;
              };
            }
            { name = "RemoveDuplicates"; }
            {
              name = "RemovePodsHavingTooManyRestarts";
              args = {
                includingInitContainers = true;
                podRestartThreshold = 100;
              };
            }
            {
              name = "RemovePodsViolatingNodeAffinity";
              args = {
                nodeAffinityType = [
                  "requiredDuringSchedulingIgnoredDuringExecution"
                ];
              };
            }
            { name = "RemovePodsViolatingNodeTaints"; }
            { name = "RemovePodsViolatingInterPodAntiAffinity"; }
            { name = "RemovePodsViolatingTopologySpreadConstraint"; }
            {
              name = "LowNodeUtilization";
              args = {
                targetThresholds = {
                  cpu = 50;
                  memory = 50;
                  pods = 50;
                };
                thresholds = {
                  cpu = 20;
                  memory = 20;
                  pods = 20;
                };
              };
            }
          ];
          plugins = {
            balance = {
              enabled = [
                "RemoveDuplicates"
                "RemovePodsViolatingTopologySpreadConstraint"
                "LowNodeUtilization"
              ];
            };
            deschedule = {
              enabled = [
                "RemovePodsHavingTooManyRestarts"
                "RemovePodsViolatingNodeTaints"
                "RemovePodsViolatingNodeAffinity"
                "RemovePodsViolatingInterPodAntiAffinity"
              ];
            };
          };
        }
      ];
    };
  };
in
{
  meta.version = "0.32.2";
  meta.owner = "platform";
  meta.description = "Descheduler: evicts pods to rebalance cluster utilization";
  # No leader election in the values below, so a second replica would
  # evict against the same policy twice. See the `replicas` comment.
  meta.availability.max = "pod";

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = "descheduler";
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "descheduler";
    };
}
