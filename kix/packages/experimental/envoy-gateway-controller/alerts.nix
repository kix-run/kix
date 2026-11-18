# Alerts for the envoy-gateway-controller package, over the metrics Service.
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
  # The controller's Deployment has the name Envoy Gateway looks it up by.
  deployment = "Deployment ${ns}/envoy-gateway";
in
kix.monitor {
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
} args
