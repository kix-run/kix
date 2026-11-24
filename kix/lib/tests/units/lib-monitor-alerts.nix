# Tests for the rules kix.monitor renders from its `alerts` argument.

{ lib, kixlib, ... }:

let
  # The PrometheusRule arguments kix.monitor builds for `alerts`, with a
  # prometheus stub whose builders return the arguments they were given.
  rulesOf =
    alerts:
    let
      parts =
        kixlib.monitor
          {
            service = "metricsService";
            inherit alerts;
          }
          {
            inherit lib;
            self.metricsService.out.selector.app = "foo";
            config.metrics.enabled = true;
            scope = {
              instanceName = "foo";
              namespaceName = "foo";
            };
            prometheus.out = {
              mkServiceMonitor = _scope: args: args;
              mkPrometheusRule = _scope: args: args;
            };
          };
    in
    parts.prometheusRules;
in
{
  # severity defaults to warning; for and keep_firing_for pass through only
  # when given; the rule and its single group are named <instance>-alerts.
  lib-monitor-alerts-fields =
    let
      rules = rulesOf {
        FooDown = {
          expr = "up == 0";
          "for" = "10m";
          keep_firing_for = "5m";
          severity = "critical";
          summary = "Foo is down.";
        };
        FooSlow.expr = "foo > 1";
      };
      group = builtins.head rules.spec.groups;
      byAlert = lib.listToAttrs (map (r: lib.nameValuePair r.alert r) group.rules);
    in
    (
      rules.name == "foo-alerts"
      && group.name == "foo-alerts"
      && byAlert.FooDown."for" == "10m"
      && byAlert.FooDown.keep_firing_for == "5m"
      && byAlert.FooDown.labels.severity == "critical"
      && byAlert.FooDown.annotations.summary == "Foo is down."
      && byAlert.FooSlow.labels.severity == "warning"
      && !(byAlert.FooSlow ? "for")
      && !(byAlert.FooSlow ? keep_firing_for)
    )
    || throw "kix.monitor alerts: ${builtins.toJSON rules}";

  # kix.reconcileErrorsAlert alerts on the share of failed reconciles with a
  # floor, scopes both counters to the selector, and groups by the given
  # labels and `controller`.
  lib-monitor-reconcile-errors-alert =
    let
      alert = kixlib.reconcileErrorsAlert {
        selector = ''namespace="ops",job="op"'';
        by = [
          "namespace"
          "job"
        ];
        operator = "Foo operator ops/op";
        summary = "The Foo operator fails to reconcile.";
        impact = "objects may drift";
        nextStep = "Read the operator log.";
      };
      errors = ''sum by (namespace, job, controller) (increase(controller_runtime_reconcile_errors_total{namespace="ops",job="op"}[30m]))'';
      reconciles = ''sum by (namespace, job, controller) (increase(controller_runtime_reconcile_total{namespace="ops",job="op"}[30m]))'';
    in
    (
      alert.expr == "${errors} / ${reconciles} > 0.1 and ${errors} > 2.5"
      && alert."for" == "15m"
      && alert.severity == "warning"
      && alert.summary == "The Foo operator fails to reconcile."
      &&
        alert.description
        == "The {{ $labels.controller }} controller of the Foo operator ops/op has failed {{ $value | humanizePercentage }} of its reconciles over the last 30 minutes, so objects may drift. Read the operator log."
    )
    || throw "kix.reconcileErrorsAlert: ${builtins.toJSON alert}";
}
