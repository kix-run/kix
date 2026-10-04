# clusters/test-tempo.nix: Tempo with Grafana and Loki under Cilium
# default-deny.
#
# Tempo runs in `tracing` on its own claim, with metrics and a 72-hour
# retention. Loki runs in `logs`. prometheus-operator gives both a
# ServiceMonitor and their PrometheusRules, which
# test-tempo.rules-test.yaml tests with promtool.
# Grafana in `grafana` wires both through `ref`, so its datasources
# ConfigMap carries a Tempo datasource whose spans link to Loki, and the
# derived policies give Grafana egress to Tempo's query port. The assert
# below fails the build when the Tempo datasource is missing, points
# anywhere but Tempo's query port, or has no link to the Loki datasource.
#
# Build:  nix build ./clusters#cluster-tempo --extra-experimental-features pipe-operators
# Rules:  nix build ./clusters#checks.x86_64-linux.rules-cluster-tempo --extra-experimental-features pipe-operators
# Deploy: kix deploy tempo --flake ./clusters --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

let
  cluster = kix.buildCluster {
    name = "test-tempo";
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
          instances.kube-system.cilium.package = packages.cilium;
          instances.monitoring.prometheus-operator.package = packages.prometheus-operator;

          instances.tracing = {
            storage = {
              package = packages.persistent-volume-claim;
              config.size = "1Gi";
            };
            tempo = {
              package = packages.tempo;
              config = {
                retention = "72h";
                metrics.enabled = true;
              };
            };
          };

          instances.logs = {
            storage = {
              package = packages.persistent-volume-claim;
              config.size = "1Gi";
            };
            loki.package = packages.loki;
          };

          instances.grafana = {
            grafana = {
              package = packages.grafana;
              deps = {
                tempo = ref.tracing.tempo;
                loki = ref.logs.loki;
              };
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

  datasourcesConfigMap = builtins.head (
    builtins.filter (
      m: m.kind == "ConfigMap" && m.metadata.name == "grafana-datasources"
    ) cluster.rawManifests
  );
  datasources = (builtins.fromJSON datasourcesConfigMap.data."datasources.yaml").datasources;
  tempoDatasource = builtins.filter (d: d.type == "tempo") datasources;
  ds = builtins.head tempoDatasource;
in
assert
  builtins.length tempoDatasource == 1
  && ds.uid == "tempo"
  && builtins.match "http://tempo\\.tracing\\.svc\\..*:3200" ds.url != null
  && ds.jsonData.tracesToLogsV2.datasourceUid == "loki"
  || throw "test-tempo: grafana-datasources must hold one Tempo datasource with uid \"tempo\", Tempo's query URL on port 3200, and a tracesToLogsV2 link to uid \"loki\" (it holds: ${builtins.toJSON tempoDatasource}).";
cluster
