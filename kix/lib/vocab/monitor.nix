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
      metricsEnabled = (config.metrics.enabled or true) && prometheus != null;
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
  # multiple Services. `scheme`, `tlsConfig`, `params`, and `honorLabels`
  # apply only to the primary endpoint. `extraEndpoints` inherit `scheme = "http"`,
  # `path = "/metrics"`, and `config.metrics.interval`.
  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      scheme ? "http",
      tlsConfig ? null,
      params ? null,
      honorLabels ? null,
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
          honorLabels
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

  # Return the alert definition for a controller-runtime operator whose
  # reconciles fail, for use as one entry of `alerts`.
  #
  # controller-runtime counts an optimistic-lock conflict as an error and
  # retries at once, so a busy healthy controller shows a few errors. The rule
  # fires on the share of reconciles that fail over 30 minutes, above 10% and
  # with more than two errors. increase() extrapolates to the edges of the
  # window, so two errors can read as slightly more than 2. The floor sits
  # halfway between two and three for that reason. `selector` scopes both counters to the
  # instance, and `by` lists the labels that name it. `operator` names the
  # instance in the description, `impact` completes "so ...", and `nextStep`
  # is the sentence that says what to check.
  reconcileErrorsAlert =
    {
      selector,
      by ? [
        "namespace"
        "service"
      ],
      operator,
      summary,
      impact,
      nextStep,
    }:
    let
      labels = lib.concatStringsSep ", " (by ++ [ "controller" ]);
      increase = metric: "sum by (${labels}) (increase(${metric}{${selector}}[30m]))";
      errors = increase "controller_runtime_reconcile_errors_total";
      reconciles = increase "controller_runtime_reconcile_total";
    in
    {
      expr = "${errors} / ${reconciles} > 0.1 and ${errors} > 2.5";
      "for" = "15m";
      severity = "warning";
      inherit summary;
      description = "The {{ $labels.controller }} controller of the ${operator} has failed {{ $value | humanizePercentage }} of its reconciles over the last 30 minutes, so ${impact}. ${nextStep}";
    };

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
