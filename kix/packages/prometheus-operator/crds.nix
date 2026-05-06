# Prometheus Operator CRD definitions — monitoring.coreos.com.
#
# Defines the core CRDs that the operator reconciles:
#   ServiceMonitor, PodMonitor, PrometheusRule — consumed by app packages via DI
#   Prometheus, Alertmanager — consumed by the prometheus/alertmanager packages
#   Probe, ScrapeConfig — additional scrape config CRDs
#   ThanosRuler — Thanos ruler instances
#   AlertmanagerConfig — namespace-scoped alertmanager routing

{
  self,
  config,
  scope,
  lib,
  ...
}:
let
  labels = {
    "app.kubernetes.io/part-of" = "prometheus-operator";
    "app.kubernetes.io/version" = config.image.tag;
  };

  # Mirror the chart-rendered CRD provenance annotations so kix CRDs diff
  # cleanly against helm-managed clusters. controllerGen tracks the
  # controller-gen version that originally generated the schemas.
  annotations = {
    "controller-gen.kubebuilder.io/version" = config.controllerGenVersion;
    "operator.prometheus.io/version" = lib.removePrefix "v" config.image.tag;
  };

  mkMonitoringCRD =
    attrs:
    scope.mkCRD (
      attrs
      |> scope.crd.withLabels labels
      |> scope.crd.withAnnotations annotations
      |> scope.crd.withCategories [ "prometheus-operator" ]
    );
in
{
  crds = {
    # ── Consumer-facing CRDs (exposed via out.mk*) ────────────────────

    serviceMonitors = mkMonitoringCRD (
      scope.crd.fromKind "ServiceMonitor" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "smon" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    podMonitors = mkMonitoringCRD (
      scope.crd.fromKind "PodMonitor" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "pmon" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    prometheusRules = mkMonitoringCRD (
      scope.crd.fromKind "PrometheusRule" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "promrule" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    probes = mkMonitoringCRD (
      scope.crd.fromKind "Probe" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "prb" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    # ── Operator-managed instance CRDs ─────────────────────────────────

    prometheuses = mkMonitoringCRD (
      scope.crd.fromKind "Prometheus" {
        spec = {
          group = "monitoring.coreos.com";
          names.plural = "prometheuses";
        };
      }
      |> scope.crd.withShortNames [ "prom" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".spec.version";
          name = "Version";
          type = "string";
        }
        {
          jsonPath = ".spec.replicas";
          name = "Desired";
          type = "integer";
        }
        {
          jsonPath = ".status.availableReplicas";
          name = "Ready";
          type = "integer";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Reconciled\")].status";
          name = "Reconciled";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Available\")].status";
          name = "Available";
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    alertmanagers = mkMonitoringCRD (
      scope.crd.fromKind "Alertmanager" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "am" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".spec.version";
          name = "Version";
          type = "string";
        }
        {
          jsonPath = ".spec.replicas";
          name = "Replicas";
          type = "integer";
        }
        {
          jsonPath = ".status.availableReplicas";
          name = "Ready";
          type = "integer";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Reconciled\")].status";
          name = "Reconciled";
          type = "string";
        }
        {
          jsonPath = ".status.conditions[?(@.type==\"Available\")].status";
          name = "Available";
          type = "string";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );

    alertmanagerConfigs = mkMonitoringCRD (
      scope.crd.fromKind "AlertmanagerConfig" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withVersion "v1alpha1"
      |> scope.crd.withShortNames [ "amcfg" ]
    );

    prometheusAgents = mkMonitoringCRD (
      scope.crd.fromKind "PrometheusAgent" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withVersion "v1alpha1"
      |> scope.crd.withShortNames [ "promagent" ]
    );

    scrapeConfigs = mkMonitoringCRD (
      scope.crd.fromKind "ScrapeConfig" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withVersion "v1alpha1"
      |> scope.crd.withShortNames [ "scfg" ]
    );

    thanosRulers = mkMonitoringCRD (
      scope.crd.fromKind "ThanosRuler" { spec.group = "monitoring.coreos.com"; }
      |> scope.crd.withShortNames [ "ruler" ]
      |> scope.crd.withPrinterColumns [
        {
          jsonPath = ".spec.replicas";
          name = "Replicas";
          type = "integer";
        }
        {
          jsonPath = ".metadata.creationTimestamp";
          name = "Age";
          type = "date";
        }
      ]
    );
  };
}
