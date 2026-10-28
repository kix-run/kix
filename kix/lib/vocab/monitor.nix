# Build ServiceMonitor and PrometheusRule parts (`kix.monitor`, `kix.alerts`).
{ lib }:

let
  # Build the PrometheusRule part shared by `alerts` and `monitor`. Kept
  # separate because `monitor` takes an `alerts` argument that would shadow the
  # public `alerts` helper.
  alertsPart =
    {
      alerts,
      name,
      extraLabels,
      rulesPart,
    }:
    {
      config,
      scope,
      prometheus ? null,
      ...
    }:
    let
      ruleName = if name != null then name else scope.instanceName;
      metricsEnabled = ((config.metrics or { }).enabled or true) && prometheus != null;
      alertRules = lib.mapAttrsToList (
        alertName: alertDef:
        {
          alert = alertName;
          expr = alertDef.expr;
          labels = {
            severity = alertDef.severity or "warning";
          }
          // (alertDef.labels or { });
          annotations =
            { }
            // lib.optionalAttrs (alertDef ? description) {
              description = alertDef.description;
            }
            // lib.optionalAttrs (alertDef ? summary) {
              summary = alertDef.summary;
            }
            // lib.optionalAttrs (alertDef ? runbook_url) {
              runbook_url = alertDef.runbook_url;
            }
            // (alertDef.annotations or { });
        }
        // lib.optionalAttrs (alertDef ? "for") {
          "for" = alertDef."for";
        }
        // lib.optionalAttrs (alertDef ? keep_firing_for) {
          inherit (alertDef) keep_firing_for;
        }
      ) alerts;
    in
    {
      ${rulesPart} =
        if metricsEnabled && alerts != { } then
          prometheus.out.mkPrometheusRule scope {
            name = "${ruleName}-alerts";
            labels = extraLabels;
            spec = {
              groups = [
                {
                  name = "${ruleName}-alerts";
                  rules = alertRules;
                }
              ];
            };
          }
        else
          null;
    };
in
{
  # Build a ServiceMonitor and optional PrometheusRule for a Service.
  #
  # Override `name`, `monitorPart`, and `rulesPart` when a package monitors
  # multiple Services. `scheme`, `tlsConfig`, and `params` apply only to the
  # primary endpoint. `extraEndpoints` inherit `scheme = "http"`,
  # `path = "/metrics"`, and `config.metrics.interval`.
  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      scheme ? "http",
      tlsConfig ? null,
      params ? null,
      alerts ? { },
      extraEndpoints ? [ ],
      extraLabels ? { },
      name ? null,
      monitorPart ? "serviceMonitor",
      rulesPart ? "prometheusRules",
    }:
    {
      self,
      config,
      scope,
      lib,
      prometheus ? null,
      ...
    }@args:
    let
      monitorName = if name != null then name else scope.instanceName;
      svc = self.${service};

      metricsConfig = config.metrics or { };
      metricsEnabled = (metricsConfig.enabled or true) && prometheus != null;
      scrapeInterval = (metricsConfig.interval or null);

      intervalAttrs = lib.optionalAttrs (scrapeInterval != null) {
        interval = scrapeInterval;
      };
      primaryEndpoint = {
        port = if builtins.isInt port then null else port;
        targetPort = if builtins.isInt port then port else null;
        inherit
          scheme
          path
          tlsConfig
          params
          ;
      }
      // intervalAttrs;
      extraEndpoint =
        e:
        {
          scheme = "http";
          path = "/metrics";
        }
        // intervalAttrs
        // e;
      endpoints = [
        (lib.filterAttrs (_: v: v != null) primaryEndpoint)
      ]
      ++ map extraEndpoint extraEndpoints;
    in
    {
      ${monitorPart} =
        if metricsEnabled then
          prometheus.out.mkServiceMonitor scope {
            name = monitorName;
            labels = extraLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = svc.out.selector;
              inherit endpoints;
            };
          }
        else
          null;
    }
    // alertsPart {
      inherit alerts extraLabels rulesPart;
      name = monitorName;
    } args;

  # Build a `<name>-alerts` PrometheusRule part for packages that do not use a
  # single `kix.monitor` ServiceMonitor. Renders only when `prometheus` is
  # wired, `metrics.enabled` is not false, and `alerts` is non-empty.
  alerts =
    {
      alerts,
      name ? null,
      extraLabels ? { },
      rulesPart ? "prometheusRules",
    }:
    alertsPart {
      inherit
        alerts
        name
        extraLabels
        rulesPart
        ;
    };
}
