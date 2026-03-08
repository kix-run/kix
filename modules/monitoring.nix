# modules/monitoring.nix — Level 3 of intent merging: cross-cutting monitoring.
#
# HISTORY & MOTIVATION (2026-03):
#
# Each chart currently creates its own ServiceMonitor independently (e.g.,
# valkey creates one when metrics.serviceMonitor.enabled = true). This means:
#
#   1. No single view of what's being monitored in the cluster
#   2. No way to add monitoring to a chart that doesn't implement it natively
#   3. No cluster-wide monitoring policies (e.g., "everything gets 15s interval")
#   4. Duplicate code — every chart re-implements the same ServiceMonitor pattern
#
# This module separates INTENT ("I have a metrics endpoint") from MATERIALIZATION
# ("create a ServiceMonitor resource"). Charts declare their scrape targets;
# this module creates the actual ServiceMonitor resources.
#
# HOW IT WORKS:
#
# Charts declare scrape targets in their config section:
#
#   config.monitoring.targets.valkey = lib.mkIf (cfg.enable && cfg.metrics.enabled) {
#     serviceName = "valkey-metrics";
#     namespace = cfg.namespace;
#     portName = "http-metrics";
#     selector = selectorLabels // { "app.kubernetes.io/component" = "metrics"; };
#   };
#
# When `monitoring.enabled = true`, this module collects all targets and
# materializes ServiceMonitor resources. When `monitoring.enabled = false`
# (the default), charts can still create their own ServiceMonitors for
# backward compatibility — but they should check `!config.monitoring.enabled`
# to avoid duplicates when the cross-cutting module is active.
#
# REPLACEMENT SEMANTICS:
#
# When monitoring.enabled = true, this module REPLACES per-chart ServiceMonitor
# creation. Charts gate their own ServiceMonitor with:
#   lib.optionalAttrs (!config.monitoring.enabled && cfg.metrics.serviceMonitor.enabled) { ... }
#
# This avoids duplicate ServiceMonitors targeting the same endpoints.
#
# PRIOR ART — KUBENIX:
#
# kubenix has NO cross-cutting monitoring. Each module creates resources
# directly. Our Level 3 is genuinely novel — it demonstrates intent merging
# where a module aggregates declarations from across the entire cluster config.
#
# ALTERNATIVES CONSIDERED:
#
# 1. Auto-discovering scrape targets from registry endpoints with protocol "http"
#    and port names containing "metrics".
#    Rejected: too implicit. Explicit target declaration is safer. Not every
#    HTTP endpoint is a Prometheus metrics endpoint.
#
# 2. Letting both chart-created and cross-cutting ServiceMonitors coexist.
#    Rejected: duplicate monitors would scrape the same endpoint twice,
#    doubling metrics ingestion. Clean replacement is better.
#
# CURRENT STATUS:
#
# All 3 migrated charts (coredns, valkey, cert-manager) declare monitoring
# targets. Charts ONLY declare targets — this module is the sole creator
# of ServiceMonitor resources. Per-chart ServiceMonitor creation was
# removed in Phase 5 of the nixification plan.
#
# This module writes raw attrsets to config.manifests (not derivations).
# Serialization is deferred to mkManifests in flake.nix — the output boundary.

{
  lib,
  config,
  kixlib,
  ...
}:

let
  types = lib.types;
  cfg = config.monitoring;

  scrapeTargetType = types.submodule {
    options = {
      enabled = lib.mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to create a ServiceMonitor for this target.
          Can be used to temporarily disable monitoring for a service
          without removing the target declaration.
        '';
      };

      serviceName = lib.mkOption {
        type = types.str;
        description = "Name of the Kubernetes Service to scrape.";
      };

      namespace = lib.mkOption {
        type = types.str;
        description = "Namespace of the Service to scrape.";
      };

      portName = lib.mkOption {
        type = types.str;
        description = ''
          Name of the port on the Service to scrape. Must match a named
          port in the Service spec (e.g., "http-metrics").
        '';
      };

      interval = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Scrape interval for this target. Null means use
          monitoring.defaultInterval. Override per-target for services
          that need more or less frequent scraping.
        '';
      };

      selector = lib.mkOption {
        type = types.attrsOf types.str;
        description = ''
          Label selector to match the target Service. Typically the
          chart's selector labels plus a component label.
        '';
      };
    };
  };
in
{
  options.monitoring = {
    enabled = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Master switch for the cross-cutting monitoring module.
        When enabled, materializes ServiceMonitors from declared targets
        and replaces per-chart ServiceMonitor creation.
        When disabled (default), charts create their own ServiceMonitors
        using their existing per-chart logic.
      '';
    };

    defaultInterval = lib.mkOption {
      type = types.str;
      default = "30s";
      description = ''
        Default scrape interval for all targets unless overridden
        per-target. Applies cluster-wide monitoring policy.
      '';
    };

    targets = lib.mkOption {
      type = types.attrsOf scrapeTargetType;
      default = { };
      description = ''
        Scrape targets declared by chart modules. Each chart adds its
        own entry (e.g., monitoring.targets.valkey). This module
        materializes ServiceMonitors from enabled targets when
        monitoring.enabled = true.
      '';
    };
  };

  config = lib.mkIf cfg.enabled {
    # Materialize a ServiceMonitor for each enabled target.
    # Uses kixlib.monitoring.mkServiceMonitor (same builder charts use internally),
    # ensuring consistent resource structure.
    # Store raw attrsets — serialization deferred to mkManifests in flake.nix.
    manifests = lib.mapAttrs' (
      name: target:
      lib.nameValuePair "monitoring-${name}-servicemonitor" (
        kixlib.monitoring.mkServiceMonitor {
          metadata = {
            name = "${name}-monitor";
            namespace = target.namespace;
            labels = config.cluster.labels // {
              "app.kubernetes.io/managed-by" = "kix";
              "app.kubernetes.io/part-of" = "monitoring";
            };
          };
          endpoints = [
            {
              port = target.portName;
              interval = if target.interval != null then target.interval else cfg.defaultInterval;
            }
          ];
          namespaceSelector.matchNames = [ target.namespace ];
          selector.matchLabels = target.selector;
        }
      )
    ) (lib.filterAttrs (_: t: t.enabled) cfg.targets);
  };
}
