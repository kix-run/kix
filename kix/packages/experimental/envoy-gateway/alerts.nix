# Alerts for the envoy-gateway package: the controller's, over the metrics
# Service, and the proxies', over the PodMonitor.
{
  self,
  config,
  scope,
  lib,
  kix,
  prometheus ? null,
  ...
}@args:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
  controller = "Envoy Gateway ${ns}/${name}";
  sel = ''namespace="${ns}",service="${name}-metrics"'';
  proxySel = ''namespace="${ns}",job="${ns}/${name}-proxy"'';
  # The controller's Deployment has the name Envoy Gateway looks it up by.
  deployment = "Deployment ${ns}/envoy-gateway";
in
(kix.monitor {
  service = "metricsService";
  port = "metrics";
  alerts = {
    EnvoyGatewayDown = {
      expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
      "for" = "10m";
      severity = "warning";
      summary = "Envoy Gateway controller is down.";
      description = "No replica of ${controller} has responded to metrics scrapes for 10 minutes. Running Envoy proxies continue serving their last configuration, so changes to Gateways, routes, and policies do not take effect. Check ${deployment} and its pod events.";
    };
    # xds_nack_total counts each configuration a proxy refused, by node
    # and resource type (internal/xds/cache/snapshotcache.go).
    EnvoyGatewayConfigRejected = {
      expr = "sum by (namespace, service) (increase(xds_nack_total{${sel}}[${config.metrics.nackWindow}])) > 0";
      severity = "warning";
      summary = "Envoy proxy rejected a configuration update.";
      description = "Envoy proxies managed by ${controller} rejected {{ $value | humanize }} configuration updates in the last ${config.metrics.nackWindow}. Proxies that reject an update keep serving their previous configuration, so recent changes to Gateways, routes, or policies have not taken effect. Check the logs of ${deployment} and the status conditions on recently changed Gateways, routes, and policies.";
    };
    # resource_apply_total counts the controller's writes of the proxy
    # Deployments, Services, and other objects it owns
    # (internal/infrastructure/kubernetes/infra_resource.go).
    EnvoyGatewayProxyApplyFailing = {
      expr = ''sum by (namespace, service) (increase(resource_apply_total{${sel},status="failure"}[15m])) > 0'';
      "for" = "15m";
      severity = "warning";
      summary = "Envoy Gateway failed to apply proxy resources.";
      description = "${controller} failed {{ $value | humanize }} times in the last 15 minutes to create or update a proxy Deployment, Service, or related resource. New Gateways will not get proxy pods, and EnvoyProxy changes will not reach running proxies. Check the logs of ${deployment} for Kubernetes API errors.";
    };
  };
} args)
// (kix.alerts {
  name = "${name}-proxy";
  rulesPart = "proxyPrometheusRules";
  alerts = {
    EnvoyProxyDown = {
      expr = "sum by (namespace, job) (up{${proxySel}}) == 0 or absent(up{${proxySel}})";
      "for" = "5m";
      severity = "critical";
      summary = "The Envoy proxies of a Gateway are down.";
      description = "No Envoy proxy pod for Gateway ${ns}/${name} has responded to metrics scrapes for 5 minutes, so the Gateway may not be serving traffic. Check the proxy Deployment in ${ns} (label gateway.envoyproxy.io/owning-gateway-name=${name}) and the logs of ${deployment}.";
    };
    # Envoy's control plane gauge is 1 while its xDS stream to the
    # controller is up.
    EnvoyProxyControlPlaneLost = {
      expr = "min by (namespace, job, pod) (envoy_control_plane_connected_state{${proxySel}}) == 0";
      "for" = "10m";
      severity = "warning";
      summary = "An Envoy proxy lost its connection to the controller.";
      description = "Proxy pod {{ $labels.pod }} for Gateway ${ns}/${name} has been disconnected from the Envoy Gateway control plane (xDS) for 10 minutes. The pod continues serving its last configuration, so route and certificate updates do not reach it. Check that ${deployment} is running and that the pod can reach Service ${ns}/envoy-gateway on port 18000.";
    };
  };
} args)
