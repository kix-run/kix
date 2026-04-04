# Monitoring — uses the shared monitoring module.
#
# The module provides: prometheus-operator, prometheus, alertmanager,
# node-exporter, kube-state-metrics, grafana, and optionally loki/promtail.

{ kix, ... }:
{
  imports = [ kix.modules.monitoring ];

  monitoring = {
    enabled = true;
    loki.enabled = true; # Also enables promtail
    defaultRules.enabled = true; # Standard K8s alerts + recording rules
  };
}
