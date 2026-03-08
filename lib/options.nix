# Shared option submodules for kixpkgs chart modules.
#
# Every chart declares the same boilerplate options (image, resources, probes,
# enable/namespace/clusterDomain). This module extracts them into reusable
# type constructors so chart options.nix files stay DRY.
#
# These are TYPE constructors (returning types.submodule values), not option
# declarations. Each chart still declares its own options — it just uses these
# as the `type` argument. This means chart-specific defaults (e.g., different
# image tags, different probe timings) are still set per-chart.
#
# Usage in a chart's options.nix:
#   { lib, kixlib, ... }:
#   let opts = kixlib.options; in {
#     options.services.myChart = {
#       image = lib.mkOption {
#         type = opts.imageSubmodule { repository = "my/image"; tag = "1.0"; };
#         default = {};
#       };
#       resources = lib.mkOption {
#         type = opts.resourcesSubmodule { defaultRequests = { cpu = "100m"; }; };
#         default = {};
#       };
#     } // opts.mkChartOptions { description = "my chart"; };
#   }

{ lib }:

let
  types = lib.types;
in
{
  # Reusable image option submodule — every chart has at least one image.
  # Takes default values so each chart can specify its own default repo/tag.
  imageSubmodule = { repository, tag, pullPolicy ? "IfNotPresent" }: types.submodule {
    options = {
      repository = lib.mkOption { type = types.str; default = repository; };
      tag = lib.mkOption { type = types.str; default = tag; };
      pullPolicy = lib.mkOption { type = types.str; default = pullPolicy; };
    };
  };

  # Reusable resources (requests/limits) submodule.
  # Charts pass their Helm-matching defaults; users override per-deployment.
  resourcesSubmodule = { defaultRequests ? {}, defaultLimits ? {} }: types.submodule {
    options = {
      requests = lib.mkOption { type = types.attrsOf types.str; default = defaultRequests; };
      limits = lib.mkOption { type = types.attrsOf types.str; default = defaultLimits; };
    };
  };

  # Reusable probe timing submodule (for liveness/readiness probes).
  # Every chart has nearly identical probe options — only the defaults differ
  # (CoreDNS uses 60s initial delay for liveness, Valkey might use 20s, etc.).
  probeSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or true; };
      initialDelaySeconds = lib.mkOption { type = types.int; default = defaults.initialDelaySeconds or 10; };
      periodSeconds = lib.mkOption { type = types.int; default = defaults.periodSeconds or 10; };
      timeoutSeconds = lib.mkOption { type = types.int; default = defaults.timeoutSeconds or 5; };
      failureThreshold = lib.mkOption { type = types.int; default = defaults.failureThreshold or 3; };
      successThreshold = lib.mkOption { type = types.int; default = defaults.successThreshold or 1; };
    };
  };

  # Reusable ServiceMonitor option submodule.
  # Most charts that support metrics have identical serviceMonitor options.
  # CoreDNS is an exception (different shape: interval is nullable, no namespace).
  serviceMonitorSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or false; };
      namespace = lib.mkOption { type = types.nullOr types.str; default = defaults.namespace or null; };
      interval = lib.mkOption { type = types.str; default = defaults.interval or "30s"; };
    };
  };

  # Reusable PodMonitor option submodule.
  podMonitorSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or false; };
      interval = lib.mkOption { type = types.str; default = defaults.interval or "30s"; };
    };
  };

  # Reusable PrometheusRule option submodule.
  prometheusRuleSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or false; };
      rules = lib.mkOption {
        type = types.listOf types.anything;
        default = defaults.rules or [];
        description = "Alerting/recording rules passed through to spec.groups[].rules.";
      };
    };
  };

  # Reusable PodDisruptionBudget option submodule.
  # CoreDNS PDB has a different shape (no `enabled` flag, nullable min/max),
  # so it keeps its inline def.
  pdbSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or true; };
      maxUnavailable = lib.mkOption { type = types.nullOr types.int; default = defaults.maxUnavailable or null; };
      minAvailable = lib.mkOption { type = types.nullOr types.int; default = defaults.minAvailable or null; };
    };
  };

  # Reusable HPA option submodule.
  # CoreDNS HPA has a different shape (metrics passthrough, no targetCPU/targetMemory),
  # so it keeps its inline def.
  hpaSubmodule = { defaults ? {} }: types.submodule {
    options = {
      enabled = lib.mkOption { type = types.bool; default = defaults.enabled or false; };
      minReplicas = lib.mkOption { type = types.int; default = defaults.minReplicas or 1; };
      maxReplicas = lib.mkOption { type = types.int; default = defaults.maxReplicas or 11; };
      targetCPU = lib.mkOption { type = types.nullOr types.int; default = defaults.targetCPU or null; };
      targetMemory = lib.mkOption { type = types.nullOr types.int; default = defaults.targetMemory or null; };
    };
  };

  # Common options every chart declares (enable, namespace, clusterDomain).
  # Returns an attrset of option declarations that can be merged into
  # options.services.<name> with `//`.
  mkChartOptions = { description }: {
    enable = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Enable ${description}.";
    };
    namespace = lib.mkOption {
      type = types.str;
      default = "default";
      description = "Kubernetes namespace for all ${description} resources.";
    };
    clusterDomain = lib.mkOption {
      type = types.str;
      default = "cluster.local";
      description = "Kubernetes cluster domain for DNS resolution.";
    };
  };
}
