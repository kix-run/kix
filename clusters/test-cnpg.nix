# clusters/test-cnpg.nix: the CloudNativePG packages under Cilium
# default-deny, with every option the packages read turned on.
#
# cnpg-operator and cnpg-barman-cloud run in cnpg-system, and cert-manager
# issues the plugin's certificates. In `data`, `pg` is a one-instance
# cnpg-cluster with metrics (a PodMonitor through prometheus-operator), an
# extraSpec parameter, and backups: WAL archiving and a weekly ScheduledBackup to
# an in-cluster S3 store (./s3-test-store.nix) wired as its endpointService,
# with retention and WAL compression. `pg-replicated` runs two instances,
# which turns on the operator's PodDisruptionBudgets. `pg-pooler` is a
# cnpg-pooler in front of `pg` with metrics and a PgBouncer parameter.
# `app-db` is a cnpg-database on that pooler, so its role and database are
# created on `pg` and its `out.host` is the pooler's Service; it has an
# extension by name and one by `{ name; version; }`. Metabase reads it
# through `deps.database`, which under default deny gives Metabase egress
# to the pooler and the pooler egress to the PostgreSQL pods on TCP 5432.
# `pg-imported` copies `pg`'s `app` database when it is created, as from a
# server Kix does not manage: `pg-source` is a service-ref for `pg-rw`, and
# `pg-app` and `pg-ca` are secret-refs for the Secrets the operator makes
# for `pg`, so the import signs in as `app` and checks `pg`'s certificate
# (verify-full). `pg` creates the table `import_check` with 100 rows, and
# after the deploy `pg-imported` should hold the same:
#   kubectl -n data exec pg-imported-1 -c postgres -- \
#     psql -At -d app -c 'select count(*) from import_check'
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
        instances.kube-system.cilium.package = packages.experimental.cilium;
        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
        instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;
        instances.cnpg-system = {
          cnpg-operator.package = packages.cnpg-operator;
          cnpg-barman-cloud.package = packages.experimental.cnpg-barman-cloud;
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
              # Rows for pg-imported to copy, owned by the role it signs in as.
              extraSpec.bootstrap.initdb.postInitApplicationSQL = [
                "CREATE TABLE import_check (id integer PRIMARY KEY)"
                "INSERT INTO import_check SELECT generate_series(1, 100)"
                "ALTER TABLE import_check OWNER TO app"
              ];
              backup = {
                destinationPath = "s3://cnpg/data";
                schedule = "@weekly";
                retention = "7d";
                extraSpec.configuration.wal.compression = "gzip";
              };
            };
          };
          pg-pooler = {
            package = packages.experimental.cnpg-pooler;
            deps.postgres = ref.data.pg;
            config = {
              metrics.enabled = true;
              extraSpec.pgbouncer.parameters.max_client_conn = "200";
            };
          };
          pg-source = {
            package = packages.experimental.service-ref;
            config = {
              name = "pg-rw";
              selector = {
                "cnpg.io/cluster" = "pg";
                "cnpg.io/podRole" = "instance";
              };
              ports = [ { port = 5432; } ];
            };
          };
          pg-app = {
            package = packages.secret-ref;
            config.keys = [ "password" ];
          };
          pg-ca = {
            package = packages.secret-ref;
            config.keys = [ "ca.crt" ];
          };
          pg-imported = {
            package = packages.cnpg-cluster;
            deps = {
              importSource = ref.data.pg-source;
              importPassword = ref.data.pg-app;
              importCa = ref.data.pg-ca;
            };
            config = {
              instances = 1;
              storage.size = "1Gi";
              import = {
                databases = [ "app" ];
                user = "app";
                sourceDatabase = "app";
              };
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
            package = packages.experimental.cnpg-database;
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
            };
          };
          app-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            # Test values only.
            config = {
              source = ./dev-secrets/cnpg-app-db.sops.yaml;
              hash = "sha256-M4b7ISu/Z6SShWDjhi3Hn8OAfI6U8VTLWyiI7J7vNvg=";
              keys = [ "password" ];
            };
          };
          metabase = {
            package = packages.experimental.metabase;
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
