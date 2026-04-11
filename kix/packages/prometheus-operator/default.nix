# prometheus-operator — Kubernetes operator for Prometheus monitoring stack.
#
# Manages monitoring.coreos.com CRDs: Prometheus, Alertmanager, ServiceMonitor,
# PodMonitor, PrometheusRule, Probe, ScrapeConfig, ThanosRuler, AlertmanagerConfig.
#
# Exposes CRD builder functions via `out`:
#   out.mkServiceMonitor  — create ServiceMonitor CRs
#   out.mkPodMonitor      — create PodMonitor CRs
#   out.mkPrometheusRule  — create PrometheusRule CRs
#   out.mkPrometheus      — create Prometheus CRs (used by packages/prometheus)
#   out.mkAlertmanager    — create Alertmanager CRs (used by packages/alertmanager)
#   out.mkProbe           — create Probe CRs
#
# This replaces the `partsOverlays` CRDRef hack in cluster monitoring configs.

{
  scope,
  lib,
}:

{
  meta = {
    version = "v0.79.2";
    description = "Prometheus Operator — monitoring.coreos.com CRD controller";
    provides = [
      "monitoring"
      "prometheus-operator"
    ];
    defaultAliases = [
      "prometheus"
      "prometheusOperator"
    ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus-operator/prometheus-operator";
        tag = "v0.79.2";
        pullPolicy = "IfNotPresent";
      };
    };
    prometheusConfigReloader = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/prometheus-operator/prometheus-config-reloader";
          tag = "v0.79.2";
        };
      };
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };
    enableAdmissionWebhook = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  build = [
    ./crds.nix
    ./operator.nix
    (
      {
        self,
        config,
        lib,
        ...
      }:
      {
        root = {
          resource = self.operatorDeployment;
          requires =
            # CRDs (deployed in early waves before operator starts)
            [
              self.crds.serviceMonitors
              self.crds.podMonitors
              self.crds.prometheusRules
              self.crds.probes
              self.crds.prometheuses
              self.crds.alertmanagers
              self.crds.alertmanagerConfigs
              self.crds.prometheusAgents
              self.crds.scrapeConfigs
              self.crds.thanosRulers
            ]
            # Operator resources
            ++ [
              self.operatorServiceAccount
              self.operatorService
            ];

          # Expose CRD builders — packages depend on these via DI
          # Usage: prometheus.out.mkServiceMonitor scope { ... }
          out = {
            inherit (self.crds.serviceMonitors.out) mkCR;
            mkServiceMonitor = self.crds.serviceMonitors.out.mkCR;
            mkPodMonitor = self.crds.podMonitors.out.mkCR;
            mkPrometheusRule = self.crds.prometheusRules.out.mkCR;
            mkProbe = self.crds.probes.out.mkCR;
            mkPrometheus = self.crds.prometheuses.out.mkCR;
            mkAlertmanager = self.crds.alertmanagers.out.mkCR;
            # The operator injects a config-reloader sidecar into Prometheus
            # and Alertmanager pods — not in any kix-generated manifest.
            extraImages = [
              "${config.prometheusConfigReloader.image.repository}:${config.prometheusConfigReloader.image.tag}"
            ];
          };
        };
      }
    )
  ];
}
