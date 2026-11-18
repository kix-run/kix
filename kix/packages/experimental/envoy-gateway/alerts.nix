# Alerts for the envoy-gateway package, over the PodMonitor of the
# Gateway's proxies.
# DI passes a build function only the arguments its formals name, so the
# formals name every argument kix.alerts reads.
{
  self,
  config,
  scope,
  lib,
  kix,
  envoyGateway ? null,
  prometheus ? null,
  ...
}@args:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
  proxySel = ''namespace="${ns}",job="${ns}/${name}-proxy"'';
  controllerNs = (envoyGateway.out or { }).namespace or ns;
  # The controller's Deployment has the name Envoy Gateway looks it up by.
  deployment = "Deployment ${controllerNs}/envoy-gateway";
in
kix.alerts {
  name = "${name}-proxy";
  rulesPart = "proxyPrometheusRules";
  alerts = {
    EnvoyProxyDown = {
      expr = "sum by (namespace, job) (up{${proxySel}}) == 0 or absent(up{${proxySel}})";
      "for" = "5m";
      severity = "critical";
      summary = "The Envoy proxies of a Gateway are down.";
      description = "No Envoy proxy pod for Gateway ${ns}/${name} has responded to metrics scrapes for 5 minutes, so the Gateway may not be serving traffic. Check proxy Deployment ${ns}/${name} and the controller logs from ${deployment}.";
    };
    # Envoy's control plane gauge is 1 while its xDS stream to the
    # controller is up.
    EnvoyProxyControlPlaneLost = {
      expr = "min by (namespace, job, pod) (envoy_control_plane_connected_state{${proxySel}}) == 0";
      "for" = "10m";
      severity = "warning";
      summary = "An Envoy proxy lost its connection to the controller.";
      description = "Proxy pod {{ $labels.pod }} for Gateway ${ns}/${name} has been disconnected from the Envoy Gateway control plane (xDS) for 10 minutes. The pod continues serving its last configuration, but route and certificate updates do not reach it. Check that controller ${deployment} is running and that the pod can reach Service ${controllerNs}/envoy-gateway on port 18000.";
    };
  };
} args
