# The ten monitoring.coreos.com CustomResourceDefinitions, vendored from the
# release's stripped-down-crds.yaml (crds/sources.txt).
#
# Prometheus, Alertmanager, PrometheusAgent, and ThanosRuler report an
# `Available` condition, True once every replica the resource asks for is
# ready, so a deploy waits for them. The other kinds report per-Prometheus
# `bindings` and no top-level conditions.

{ operandSelectors }:
{ scope, ... }:
let
  # The CRD's spec and upstream's provenance annotations
  # (controller-gen.kubebuilder.io/version, operator.prometheus.io/version).
  vendored =
    file:
    let
      crd = builtins.fromJSON (builtins.readFile ./crds/${file});
    in
    {
      inherit (crd) spec;
      annotations = crd.metadata.annotations or { };
    };

  available.condition = {
    type = "Available";
    status = "True";
  };

in
{
  crds = {
    alertmanagerConfigs = scope.mkCRD (vendored "alertmanagerconfigs.monitoring.coreos.com.json");
    alertmanagers = scope.mkCRD (
      vendored "alertmanagers.monitoring.coreos.com.json" // { readiness = available; }
    );
    podMonitors = scope.mkCRD (vendored "podmonitors.monitoring.coreos.com.json");
    probes = scope.mkCRD (vendored "probes.monitoring.coreos.com.json");
    prometheusAgents = scope.mkCRD (
      vendored "prometheusagents.monitoring.coreos.com.json" // { readiness = available; }
    );
    prometheuses = scope.mkCRD (
      vendored "prometheuses.monitoring.coreos.com.json"
      // {
        readiness = available;
        # The netpol plugin's operand egress and its scrape policies
        # (kix/lib/plugins/netpol/scrape.nix) read this selector to name the
        # pods that dial the resource's endpoints and its scrape targets.
        factBehavior = {
          endpoint = "terminate";
          podSelector = cr: operandSelectors.prometheus cr.metadata.name;
        };
      }
    );
    prometheusRules = scope.mkCRD (vendored "prometheusrules.monitoring.coreos.com.json");
    scrapeConfigs = scope.mkCRD (vendored "scrapeconfigs.monitoring.coreos.com.json");
    serviceMonitors = scope.mkCRD (vendored "servicemonitors.monitoring.coreos.com.json");
    thanosRulers = scope.mkCRD (
      vendored "thanosrulers.monitoring.coreos.com.json" // { readiness = available; }
    );
  };
}
