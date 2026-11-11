# clusters/test-tempo-generator.nix: Tempo's metrics generator writing to
# VictoriaMetrics, with Grafana's service graph reading it back.
#
# victoria-metrics-operator and victoria-metrics-cluster run in
# `monitoring`; the cluster answers `prometheusServer`. Tempo in `tracing`
# turns on `metricsGenerator`, so its generator remote-writes span metrics
# and service-graph series to the cluster's `out.remoteWriteUrl`. Grafana
# binds the same instance as its Prometheus datasource and wires Tempo
# through `ref`, so its Tempo datasource carries a service map that reads
# the Prometheus datasource. The asserts below fail the build when Tempo's
# config has no generator writing to vminsert, or the Tempo datasource has
# no service map on the Prometheus datasource's uid.
# Everything runs under Cilium default deny.
#
# Build:  nix build ./clusters#cluster-tempo-generator --extra-experimental-features pipe-operators

{ kix, packages }:

let
  cluster = kix.buildCluster {
    name = "test-tempo-generator";
    modules = [
      kix.flavors.kind
      (
        { ref, ... }:
        {
          networkPolicy.enable = true;

          # kind runs with the default CNI disabled, so the managed cilium
          # instance fills the cni role.
          cluster.roles.cni = {
            binding = "absent";
            provider = null;
          };
          instances.kube-system.cilium.package = packages.experimental.cilium;

          instances.monitoring = {
            vm-operator.package = packages.victoria-metrics-operator;
            vm-cluster.package = packages.victoria-metrics-cluster;
          };

          instances.tracing = {
            storage = {
              package = packages.persistent-volume-claim;
              config.size = "1Gi";
            };
            tempo = {
              package = packages.experimental.tempo;
              config.metricsGenerator.enabled = true;
            };
          };

          instances.grafana = {
            grafana = {
              package = packages.grafana;
              deps.tempo = ref.tracing.tempo;
            };
            # Test values only.
            grafana-admin = {
              package = packages.secret;
              aliases = [ "grafanaAdmin" ];
              config.stringData = {
                admin-user = "admin";
                admin-password = "test-only";
              };
            };
          };
        }
      )
    ];
  };

  configMap =
    name:
    builtins.head (
      builtins.filter (m: m.kind == "ConfigMap" && m.metadata.name == name) cluster.rawManifests
    );

  tempoConfig = builtins.fromJSON (configMap "tempo-config").data."tempo.yaml";
  generator = tempoConfig.metrics_generator.storage or { };

  datasources =
    (builtins.fromJSON (configMap "grafana-datasources").data."datasources.yaml").datasources;
  ofType = type: builtins.filter (d: d.type == type) datasources;
  tempoDs = builtins.head (ofType "tempo");
  promDs = builtins.head (ofType "prometheus");
in
assert
  builtins.match "http://vminsert-vm-cluster\\.monitoring\\.svc\\..*:8480/insert/0/prometheus/api/v1/write" (
    (builtins.head generator.remote_write).url
  ) != null
  && generator.path == "/var/tempo/generator/wal"
  &&
    tempoConfig.overrides.defaults.metrics_generator.processors == [
      "service-graphs"
      "span-metrics"
    ]
  || throw "test-tempo-generator: Tempo's metrics generator must remote-write to vm-cluster's vminsert with both processors on (metrics_generator.storage holds: ${builtins.toJSON generator}).";
assert
  builtins.length (ofType "tempo") == 1
  && builtins.length (ofType "prometheus") == 1
  && tempoDs.jsonData.serviceMap.datasourceUid == promDs.uid
  || throw "test-tempo-generator: the Tempo datasource's serviceMap must name the Prometheus datasource's uid (datasources: ${builtins.toJSON datasources}).";
cluster
