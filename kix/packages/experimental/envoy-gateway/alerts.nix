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
  deployment = "the Deployment envoy-gateway in ${ns}";
in
(kix.monitor {
  service = "metricsService";
  port = "metrics";
  alerts = {
    EnvoyGatewayDown = {
      expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
      "for" = "10m";
      severity = "warning";
      summary = "The Envoy Gateway controller is down.";
      description = "No replica of ${controller} has answered a scrape for 10 minutes. The proxies keep serving their last configuration, and no change to a Gateway, route, or policy reaches them. Check ${deployment} and its pods' events.";
    };
    # xds_nack_total counts each configuration a proxy refused, by node
    # and resource type (internal/xds/cache/snapshotcache.go).
    EnvoyGatewayConfigRejected = {
      expr = "sum by (namespace, service) (increase(xds_nack_total{${sel}}[${config.metrics.nackWindow}])) > 0";
      severity = "warning";
      summary = "An Envoy proxy refused its configuration.";
      description = "Proxies of ${controller} refused {{ $value | humanize }} configuration updates in the last ${config.metrics.nackWindow}. A proxy that refuses an update keeps serving the previous configuration, so recent changes to Gateways, routes, or policies are not in effect. Read the controller's log for the rejected resource, and the status of the routes and policies changed last.";
    };
    # resource_apply_total counts the controller's writes of the proxy
    # Deployments, Services, and other objects it owns
    # (internal/infrastructure/kubernetes/infra_resource.go).
    EnvoyGatewayProxyApplyFailing = {
      expr = ''sum by (namespace, service) (increase(resource_apply_total{${sel},status="failure"}[15m])) > 0'';
      "for" = "15m";
      severity = "warning";
      summary = "Envoy Gateway cannot update the proxies' Kubernetes objects.";
      description = "${controller} failed to create or update a proxy Deployment, Service, or other object it owns {{ $value | humanize }} times in the last 15 minutes. A new Gateway gets no proxy, and a changed EnvoyProxy does not reach the running proxies. Read the controller's log for the API error.";
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
      summary = "No Envoy proxy of a Gateway answers.";
      description = "No proxy pod of the Gateway ${ns}/${name} has answered a scrape for 5 minutes, so requests to its listeners get no answer. Check the proxy Deployment the controller created in ${ns} (label gateway.envoyproxy.io/owning-gateway-name=${name}) and the controller's log.";
    };
    # Envoy's control plane gauge is 1 while its xDS stream to the
    # controller is up.
    EnvoyProxyControlPlaneLost = {
      expr = "min by (namespace, job, pod) (envoy_control_plane_connected_state{${proxySel}}) == 0";
      "for" = "10m";
      severity = "warning";
      summary = "An Envoy proxy has lost its controller.";
      description = "Proxy {{ $labels.pod }} of the Gateway ${ns}/${name} has had no xDS connection to the controller for 10 minutes. It serves its last configuration, and new routes and certificates do not reach it. Check that ${controller} runs and that the proxy can reach the Service envoy-gateway on port 18000.";
    };
  };
} args)
