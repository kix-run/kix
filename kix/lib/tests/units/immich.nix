# Tests for the kix/lib behaviour the immich rework relies on: kix.monitor
# gives each extra endpoint the instance's scrape interval and the default
# scheme and path.

{
  lib,
  kixlib,
  ...
}:

let
  # The ServiceMonitor endpoints kix.monitor builds for `metrics`, with a
  # prometheus stub whose builder returns the arguments it was given.
  endpointsOf =
    metrics:
    let
      parts =
        kixlib.monitor
          {
            service = "service";
            port = "metrics-api";
            extraEndpoints = [ { port = "metrics-ms"; } ];
          }
          {
            inherit lib;
            self.service.out.selector.app = "immich";
            config.metrics = metrics;
            scope = {
              instanceName = "immich";
              namespaceName = "photos";
            };
            prometheus.out.mkServiceMonitor = _scope: monitorArgs: monitorArgs;
          };
    in
    parts.serviceMonitor.spec.endpoints;

  endpoint = port: {
    inherit port;
    path = "/metrics";
    scheme = "http";
  };
in
{
  # metrics.interval = "30s" renders interval, scheme and path on both
  # endpoints; without an interval neither endpoint has one.
  immich-monitor-extra-endpoint-interval =
    let
      timed = endpointsOf {
        enabled = true;
        interval = "30s";
      };
      untimed = endpointsOf {
        enabled = true;
        interval = null;
      };
    in
    (
      timed == [
        (endpoint "metrics-api" // { interval = "30s"; })
        (endpoint "metrics-ms" // { interval = "30s"; })
      ]
      &&
        untimed == [
          (endpoint "metrics-api")
          (endpoint "metrics-ms")
        ]
    )
    || throw "kix.monitor extra endpoints: with interval ${builtins.toJSON timed}, without ${builtins.toJSON untimed}";
}
