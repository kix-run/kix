# Tests for the rules kix.monitor renders from its `alerts` argument.

{ lib, kixlib, ... }:

let
  # The PrometheusRule arguments kix.monitor builds for `alerts`, with a
  # prometheus stub whose builders return the arguments they were given.
  rulesOf =
    alerts:
    let
      parts = kixlib.monitor {
        service = "metricsService";
        inherit alerts;
      } {
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
}
