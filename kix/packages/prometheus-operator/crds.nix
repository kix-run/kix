# The ten monitoring.coreos.com CustomResourceDefinitions, vendored from the
# release's stripped-down-crds.yaml (crds/sources.txt).
#
# Prometheus, Alertmanager, PrometheusAgent, and ThanosRuler report an
# `Available` condition, True once every replica the resource asks for is
# ready, so a deploy waits for them. The other kinds report per-Prometheus
# `bindings` and no top-level conditions.

{ operandSelectors }:
{
  scope,
  lib,
  kix,
  ...
}:
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

  # Return the least a prometheus-operator workload CR uses, or nothing
  # when `spec.paused` is `true`. Each pod has the main `container`, sized by
  # `defaults` under `spec.resources` under its entry in `spec.containers`;
  # the `thanos-sidecar` container when `spec.thanos` is set (Prometheus
  # only), sized by `spec.thanos.resources` under its entry in
  # `spec.containers`; and every other `spec.containers` entry, which the
  # operator adds as it is. `config-reloader` is left out because the
  # operator sizes it. Each pod has one claim when
  # `spec.storage.volumeClaimTemplate` is set. The `-operated` Service is
  # shared by every CR of the kind in the namespace, so it is not counted.
  usesAtLeastFor =
    {
      container,
      pods,
      defaults ? { },
      thanos ? false,
    }:
    cr:
    let
      spec = cr.spec or { };
      patches = spec.containers or [ ];
      patchOf = name: (lib.findFirst (c: (c.name or null) == name) { } patches).resources or { };
      own = [
        container
      ]
      ++ lib.optional (thanos && spec ? thanos) "thanos-sidecar"
      ++ [ "config-reloader" ];
      main = lib.recursiveUpdate (lib.recursiveUpdate defaults (spec.resources or { })) (
        patchOf container
      );
      sidecar = lib.recursiveUpdate (spec.thanos.resources or { }) (patchOf "thanos-sidecar");
      extra = builtins.filter (c: !(builtins.elem (c.name or null) own)) patches;
      claim = spec.storage.volumeClaimTemplate or null;
    in
    if spec.paused or false then
      { }
    else
      kix.usage.times (pods spec) (
        kix.usage.add (
          [
            (kix.usage.ofPod (
              [ { resources = main; } ]
              ++ lib.optional (thanos && spec ? thanos) { resources = sidecar; }
              ++ extra
            ))
          ]
          ++ lib.optional (claim != null) {
            persistentvolumeclaims = 1;
            "requests.storage" = claim.spec.resources.requests.storage or null;
          }
        )
      );

  replicasTimesShards = spec: (spec.replicas or 1) * lib.max 1 (spec.shards or 1);

  # Build the `usesAtLeastFor` config for Alertmanager and ThanosRuler,
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
        usesAtLeast = usesAtLeastFor (singleSet "alertmanager");
      }
    );
    podMonitors = scope.mkCRD (vendored "podmonitors.monitoring.coreos.com.json");
    probes = scope.mkCRD (vendored "probes.monitoring.coreos.com.json");
    prometheusAgents = scope.mkCRD (
      vendored "prometheusagents.monitoring.coreos.com.json"
      // {
        readiness = available;
        # Skip DaemonSet mode because the pod count depends on cluster nodes.
        usesAtLeast =
          cr:
          if (cr.spec.mode or "StatefulSet") == "DaemonSet" then
            { }
          else
            usesAtLeastFor {
              container = "prometheus";
              pods = replicasTimesShards;
            } cr;
      }
    );
    prometheuses = scope.mkCRD (
      vendored "prometheuses.monitoring.coreos.com.json"
      // {
        readiness = available;
        usesAtLeast = usesAtLeastFor {
          container = "prometheus";
          pods = replicasTimesShards;
          thanos = true;
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
        usesAtLeast = usesAtLeastFor (singleSet "thanos-ruler");
      }
    );
  };
}
