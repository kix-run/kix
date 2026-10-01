# Tests for the kix/lib behaviour the descheduler rework relies on:
# kix.monitor scrapes the primary endpoint over HTTPS when asked.

{
  lib,
  kixlib,
  ...
}:

let
  # The ServiceMonitor endpoints kix.monitor builds for `args`, with a
  # prometheus stub whose builder returns the arguments it was given.
  endpointsOf =
    args:
    let
      parts = kixlib.monitor ({ service = "metricsService"; } // args) {
        inherit lib;
        self.metricsService.out.selector.app = "descheduler";
        config.metrics.enabled = true;
        scope = {
          instanceName = "descheduler";
          namespaceName = "kube-system";
        };
        prometheus.out.mkServiceMonitor = _scope: monitorArgs: monitorArgs;
      };
    in
    parts.serviceMonitor.spec.endpoints;
in
{
  # scheme = "https" and a tlsConfig render on the primary endpoint. Left
  # out, the endpoint is `scheme: http` with no tlsConfig.
  descheduler-monitor-https =
    let
      https = endpointsOf {
        scheme = "https";
        tlsConfig.insecureSkipVerify = true;
      };
      plain = endpointsOf { };
    in
    (
      https == [
        {
          port = "metrics";
          path = "/metrics";
          scheme = "https";
          tlsConfig.insecureSkipVerify = true;
        }
      ]
      &&
        plain == [
          {
            port = "metrics";
            path = "/metrics";
            scheme = "http";
          }
        ]
    )
    || throw "kix.monitor scheme/tlsConfig: https ${builtins.toJSON https}, default ${builtins.toJSON plain}";
}
