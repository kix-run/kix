# clusters/test-otel-collector.nix: an OpenTelemetry Collector gateway and
# node agent under Cilium default-deny.
#
# - `gateway` runs in deployment mode with `events.enabled`, so it watches
#   Kubernetes Events at one replica, and forwards traces to `tempo`, a
#   kix.mkImport stand-in that publishes the OTLP endpoint fields
#   (`otlpGrpcUrl`, `otlpHttpUrl`, `tls`).
# - `agent` runs in daemonset mode and forwards traces to the gateway's
#   `out.otlpGrpcUrl`, so the agent's egress to the gateway is derived.
# prometheus-operator gives both a metrics port and a ServiceMonitor.
#
# Build:  nix build ./clusters#cluster-otel-collector --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "test-otel-collector";
  modules = [
    kix.flavors.kind
    (
      { config, ref, ... }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

        instances.observability = {
          # A trace backend Kix does not manage, listening for OTLP. A
          # kix.mkImport carries no Service facts, so no egress from the
          # gateway to it is derived; on a real cluster the backend is a
          # Kix package, or the instance adds that egress.
          tempo.package = kix.mkImport {
            out = {
              otlpGrpcUrl = "http://tempo.observability.svc.${config.clusterDomain}:4317";
              otlpHttpUrl = "http://tempo.observability.svc.${config.clusterDomain}:4318";
              tls = false;
            };
          };

          gateway = {
            package = packages.experimental.otel-collector;
            config.events.enabled = true;
            deps.otlp = ref.observability.tempo;
          };

          agent = {
            package = packages.experimental.otel-collector;
            config.mode = "daemonset";
            deps.otlp = ref.observability.gateway;
          };
        };
      }
    )
  ];
}
