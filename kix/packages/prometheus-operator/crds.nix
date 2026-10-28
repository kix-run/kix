# The ten monitoring.coreos.com CustomResourceDefinitions, vendored from the
# release's stripped-down-crds.yaml (crds/sources.txt).
#
# Prometheus, Alertmanager, PrometheusAgent, and ThanosRuler report an
# `Available` condition, True once every replica the resource asks for is
# ready, so a deploy waits for them. The other kinds report per-Prometheus
# `bindings` and no top-level conditions.

{ operandSelectors }:
{ scope, lib, ... }:
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

  # Return the minimum pod group for a prometheus-operator workload CR,
  # or an empty list when `spec.paused` is `true`. Pod resources merge
  # operator `defaults`, `spec.resources`, and any matching container
  # entry in `spec.containers`. Sidecars (`config-reloader`, Thanos) are
  # omitted because they are sized by the operator or by separate fields.
  runsAtLeast =
    {
      container,
      pods,
      defaults ? { },
    }:
    cr:
    let
      spec = cr.spec or { };
      patch = lib.findFirst (c: (c.name or null) == container) { } (spec.containers or [ ]);
    in
    lib.optional (!(spec.paused or false)) {
      pods = pods spec;
      resources = lib.recursiveUpdate (lib.recursiveUpdate defaults (spec.resources or { })) (
        patch.resources or { }
      );
    };

  replicasTimesShards = spec: (spec.replicas or 1) * lib.max 1 (spec.shards or 1);

  # Build the `runsAtLeast` config for Alertmanager and ThanosRuler,
  # where the operator defaults `requests.memory` to `200Mi` when unset.
  singleSet = container: {
    inherit container;
    pods = spec: spec.replicas or 1;
    defaults.requests.memory = "200Mi";
  };

in
{
  crds = {
    alertmanagerConfigs = scope.mkCRD (vendored "alertmanagerconfigs.monitoring.coreos.com.json");
    alertmanagers = scope.mkCRD (
      vendored "alertmanagers.monitoring.coreos.com.json"
      // {
        readiness = available;
        runsAtLeast = runsAtLeast (singleSet "alertmanager");
      }
    );
    podMonitors = scope.mkCRD (vendored "podmonitors.monitoring.coreos.com.json");
    probes = scope.mkCRD (vendored "probes.monitoring.coreos.com.json");
    prometheusAgents = scope.mkCRD (
      vendored "prometheusagents.monitoring.coreos.com.json"
      // {
        readiness = available;
        # Skip DaemonSet mode because the pod count depends on cluster nodes.
        runsAtLeast =
          cr:
          if (cr.spec.mode or "StatefulSet") == "DaemonSet" then
            [ ]
          else
            runsAtLeast {
              container = "prometheus";
              pods = replicasTimesShards;
            } cr;
      }
    );
    prometheuses = scope.mkCRD (
      vendored "prometheuses.monitoring.coreos.com.json"
      // {
        readiness = available;
        runsAtLeast = runsAtLeast {
          container = "prometheus";
          pods = replicasTimesShards;
        };
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
      vendored "thanosrulers.monitoring.coreos.com.json"
      // {
        readiness = available;
        runsAtLeast = runsAtLeast (singleSet "thanos-ruler");
      }
    );
  };
}
