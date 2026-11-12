# Tests for the smartctl-exporter package's monitoring: the ServiceMonitor
# over the chart's Service and the alert rules, and what they are gated
# on. The chart is not rendered: a Helm stub stands in for importChart and
# emits the chart's Service under the part name importChart gives it.

{
  lib,
  k8s,
  manifests,
  ofKind,
  byName,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  smartctlPackage = import ../../../packages/experimental/smartctl-exporter;
  serviceName = "smartctl-exporter-prometheus-smartctl-exporter";
  labels."app.kubernetes.io/name" = "prometheus-smartctl-exporter";

  # Stands in for kix/lib/helm.nix, whose renders only `kix` can produce.
  stubHelm = {
    fetchHelmChart = _: "smartctl-exporter-chart";
    importChart =
      { scope, ... }:
      let
        # The package's root; a ConfigMap, since a stub DaemonSet would
        # need the workload builders.
        daemonSet = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = serviceName;
          inherit labels;
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = serviceName;
          inherit labels;
          # No pod selector: the stub renders no pods for it to match.
          spec = {
            ports = [
              {
                name = "http";
                port = 80;
                targetPort = "http";
              }
            ];
          };
        };
      in
      {
        byKind = kind: if kind == "DaemonSet" then [ daemonSet ] else [ ];
        mkParts =
          { root, ... }:
          {
            "service-${serviceName}" = service;
            daemonset = root;
            root.resource = root;
          };
      };
  };
  stubEval = import ../../eval {
    inherit lib k8s;
    helm = stubHelm;
  };

  rulesOf =
    {
      config ? { },
      prometheus ? true,
    }:
    alertRulesOf "PrometheusRule" "smartctl-exporter" (
      manifests (
        stubEval.buildCluster {
          name = "test";
          modules = [
            {
              instances.monitoring = {
                smartctl-exporter = {
                  package = smartctlPackage;
                  inherit config;
                };
              }
              // lib.optionalAttrs prometheus { prometheus.package = prometheusStub; };
            }
          ];
        }
      )
    );
in
{
  # With a prometheus provider the alerts render under
  # `smartctl-exporter-alerts`, every expression selects the chart's
  # Service, and the temperature threshold follows metrics.maxTemperature.
  # Nothing renders without a provider or with metrics.enabled = false.
  smartctl-exporter-alerts =
    let
      rules = rulesOf { };
      cool = rulesOf { config.metrics.maxTemperature = 60; };
    in
    (
      allSelect ''namespace="monitoring",service="${serviceName}"'' rules
      &&
        builtins.attrNames rules == [
          "SmartDeviceCriticalWarning"
          "SmartDeviceHealthFailed"
          "SmartDeviceMediaErrors"
          "SmartDeviceTemperatureHigh"
          "SmartctlExporterDown"
        ]
      && lib.hasSuffix "> 70" rules.SmartDeviceTemperatureHigh.expr
      && lib.hasSuffix "> 60" cool.SmartDeviceTemperatureHigh.expr
      && rulesOf { prometheus = false; } == null
      && rulesOf { config.metrics.enabled = false; } == null
    )
    || throw "smartctl-exporter alerts: ${builtins.toJSON (builtins.attrNames rules)}";

  # The ServiceMonitor selects the chart's Service by its labels, on the
  # chart's port name.
  smartctl-exporter-service-monitor =
    let
      monitor = byName "smartctl-exporter" (
        ofKind "ServiceMonitor" (
          manifests (
            stubEval.buildCluster {
              name = "test";
              modules = [
                {
                  instances.monitoring = {
                    smartctl-exporter.package = smartctlPackage;
                    prometheus.package = prometheusStub;
                  };
                }
              ];
            }
          )
        )
      );
    in
    (
      monitor.spec.selector.matchLabels."app.kubernetes.io/name" == "prometheus-smartctl-exporter"
      && (builtins.head monitor.spec.endpoints).port == "http"
    )
    || throw "smartctl-exporter monitor: ${builtins.toJSON monitor}";
}
