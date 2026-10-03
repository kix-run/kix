# clusters/test-cnpg.nix: the CloudNativePG packages under Cilium
# default-deny, with every option the packages read turned on.
#
# cnpg-operator and cnpg-barman-cloud run in cnpg-system, and cert-manager
# issues the plugin's certificates. In `data`, `pg` is a one-instance
# cnpg-cluster with metrics (a PodMonitor through prometheus-operator), an
# extraSpec parameter, and backups: WAL archiving and a ScheduledBackup to
# an in-cluster S3 store (./s3-test-store.nix) wired as its endpointService,
# with retention and WAL compression. `pg-replicated` runs two instances,
# which turns on the operator's PodDisruptionBudgets. `pg-pooler` is a
# cnpg-pooler in front of `pg` with metrics and a PgBouncer parameter.
# `app-db` is a cnpg-database on that pooler, so its role and database are
# created on `pg` and its `out.host` is the pooler's Service; it has an
# extension by name and one by `{ name; version; }`. Metabase reads it
# through `deps.database`, which under default deny gives Metabase egress
# to the pooler and the pooler egress to the PostgreSQL pods on TCP 5432.
#
# Build:  nix build .#cluster-cnpg --extra-experimental-features pipe-operators
# Deploy: kix deploy cnpg --flake ./clusters --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

let
  # Test keys for the in-cluster store, which reads them as its root user
  # and pg's backups as their S3 credentials.
  s3Credentials = {
    accessKeyId = "cnpg-test";
    secretAccessKey = "cnpg-test-secret";
  };
in
kix.buildCluster {
  name = "test-cnpg";
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
        instances.cert-manager.cert-manager.package = packages.cert-manager;
        instances.cnpg-system = {
          cnpg-operator.package = packages.cnpg-operator;
          cnpg-barman-cloud.package = packages.cnpg-barman-cloud;
        };

        instances.data = {
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
            buckets = [ "cnpg" ];
            description = "S3 test store for the CloudNativePG backups";
          };
          pg = {
            package = packages.cnpg-cluster;
            deps.endpointService = ref.data.s3;
            config = {
              storage.size = "1Gi";
              metrics.enabled = true;
              extraSpec.postgresql.parameters.max_connections = "50";
              backup = {
                destinationPath = "s3://cnpg/data";
                schedule = "0 0 3 * * *";
                retention = "7d";
                extraSpec.configuration.wal.compression = "gzip";
              };
            };
          };
          pg-pooler = {
            package = packages.cnpg-pooler;
            deps.postgres = ref.data.pg;
            config = {
              metrics.enabled = true;
              extraSpec.pgbouncer.parameters.max_client_conn = "200";
            };
          };
          pg-replicated = {
            package = packages.cnpg-cluster;
            config = {
              instances = 2;
              storage.size = "1Gi";
            };
          };
          app-db = {
            package = packages.cnpg-database;
            deps.postgres = ref.data.pg-pooler;
            config = {
              database = "app";
              user = "app_user";
              extensions = [
                "citext"
                {
                  name = "vector";
                  version = null;
                }
              ];
              # Test values only.
              password = "test-cnpg-password";
            };
          };
          metabase = {
            package = packages.metabase;
            deps.database = ref.data.app-db;
          };
          metabase-encryption-key = {
            package = packages.secret;
            aliases = [ "encryptionKey" ];
            # Test values only.
            config.stringData.key = "0123456789abcdef0123456789abcdef";
          };
        };
      }
    )
  ];
}
