# clusters/test-tempo.nix: Tempo with Grafana and Loki under Cilium
# default-deny.
#
# Tempo runs in `tracing` on its own claim, with metrics (a ServiceMonitor
# through prometheus-operator) and a 72-hour retention. Its trace blocks go
# to an in-cluster S3 store (./s3-test-store.nix) wired as its
# endpointService, so the derived policy gives Tempo egress to the store.
# Loki runs in `logs`.
# Grafana in `grafana` wires both through `ref`, so its datasources
# ConfigMap carries a Tempo datasource whose spans link to Loki, and the
# derived policies give Grafana egress to Tempo's query port. The assert
# below fails the build when the Tempo datasource is missing, points
# anywhere but Tempo's query port, or has no link to the Loki datasource,
# and when Tempo's config does not name the store's Service. The metrics
# generator is evaluated in ./test-tempo-generator.nix.
#
# Build:  nix build ./clusters#cluster-tempo --extra-experimental-features pipe-operators
# Deploy: kix deploy tempo --flake ./clusters --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

let
  # Test keys for the in-cluster store, which reads them as its root user
  # and Tempo as its S3 credentials.
  s3Credentials = {
    accessKeyId = "tempo-test";
    secretAccessKey = "tempo-test-secret";
  };

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
            s3-credentials = {
              package = packages.secret;
              aliases = [
                "storageCredentials"
                "s3RootCredentials"
              ];
              # Test values only.
              config.stringData = s3Credentials;
            };
            s3.package = import ./s3-test-store.nix {
              buckets = [ "traces" ];
              description = "S3 test store for the Tempo blocks";
            };
            tempo = {
              package = packages.tempo;
              deps.endpointService = ref.tracing.s3;
              config = {
                retention = "72h";
                metrics.enabled = true;
                objectStorage.bucket = "traces";
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

  tempoConfigMap = builtins.head (
    builtins.filter (m: m.kind == "ConfigMap" && m.metadata.name == "tempo-config") cluster.rawManifests
  );
  trace = (builtins.fromJSON tempoConfigMap.data."tempo.yaml").storage.trace;
in
assert
  builtins.length tempoDatasource == 1
  && ds.uid == "tempo"
  && builtins.match "http://tempo\\.tracing\\.svc\\..*:3200" ds.url != null
  && ds.jsonData.tracesToLogsV2.datasourceUid == "loki"
  || throw "test-tempo: grafana-datasources must hold one Tempo datasource with uid \"tempo\", Tempo's query URL on port 3200, and a tracesToLogsV2 link to uid \"loki\" (it holds: ${builtins.toJSON tempoDatasource}).";
assert
  trace.backend == "s3"
  && trace.s3.bucket == "traces"
  && builtins.match "s3\\.tracing\\.svc\\..*:7070" trace.s3.endpoint != null
  && trace.s3.insecure
  || throw "test-tempo: Tempo must write blocks to bucket \"traces\" on the s3 Service's address over http (storage.trace holds: ${builtins.toJSON trace}).";
cluster
