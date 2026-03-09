# modules/implementations/monitoring-prometheus.nix — Prometheus implementation for monitoring capability.
#
# Creates ServiceMonitor resources from capabilities.monitoring.* input fields.
# This module ONLY reads from capabilities.monitoring and writes to config.manifests.
#
# Output writeback (labels, annotations) is handled inside the capability submodule
# itself (modules/capabilities/monitoring.nix) to avoid infinite recursion.
# See the architecture comment in that file for why.
#
# CRITICAL RULES (from doc 12):
# - This module NEVER writes to capabilities.monitoring.*.output.* (infinite recursion)
# - This module NEVER reads config.manifests to produce config.manifests (fixpoint cycle)
# - Flow is: capabilities → this module → manifests (one-directional)

{
  lib,
  config,
  kixlib,
  ...
}:

let
  cfg = config.monitoring;
  caps = config.capabilities.monitoring;
in
{
  config = lib.mkIf (cfg.enabled && cfg.provider == "prometheus") {

    # One ServiceMonitor per capability target.
    # Key format: "monitoring-${name}-servicemonitor".
    #
    # No filterAttrs needed: when mkIf false suppresses a target, the key doesn't
    # exist in the attrset — there's nothing to filter.
    manifests = lib.mapAttrs' (name: target:
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
          endpoints = [{
            port = target.portName;
            interval =
              if target.interval != null then target.interval
              else cfg.defaultInterval;
          }];
          namespaceSelector.matchNames = [ target.namespace ];
          selector.matchLabels = target.selector;
        }
      )
    ) caps;
  };
}
