# clusters/test-clickhouse.nix: the bare ClickHouse package on kind
# (v2_discussions/148, phase 1).
#
# One server with its volume and its credentials, embedded Keeper included,
# so replicated DDL works. The probe is on by default, so a deploy proves
# login, that a passwordless login is refused, and that the {cluster} macro
# and Keeper answer.
#
# prometheus-operator gives both ClickHouse packages their scrape and their
# alert rules; test-clickhouse.rules-test.yaml beside this file tests the
# rules.
#
# Bring up (three workers, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-clickhouse --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Build:   nix build .#cluster-clickhouse --extra-experimental-features pipe-operators
# Deploy:  kix --flake ./clusters --context kind-kix-clickhouse deploy clickhouse -y
#
{ kix, packages }:

kix.buildCluster {
  name = "test-clickhouse";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        # kind created with the default CNI disabled and several workers
        # (see the header); Cilium fills the cni role and enforces the
        # policies Kix derives, so everything below runs under default-deny.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        instances.kube-system.cilium = {
          package = packages.cilium;
        };

        instances.monitoring.prometheus-operator.package = packages.prometheus-operator;

        # Every rule set, so the package is held to all of them.
        scorecard = {
          enable = true;
          rules = kix.rules;
          # The CNI is privileged, host-networked and root by nature. The
          # rules stay errors everywhere the packages under test run.
          ruleOverrides.byNamespace.kube-system."*".severity = "info";
        };

        instances.analytics = {
          clickhouse = {
            package = packages.clickhouse;
            config = {
              # The package's 2Gi default stands: at 1Gi the server's own
              # background merges hit the cap once logs start arriving.
              resources.requests.cpu = "250m";
            };
          };

          clickhouse-data = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "5Gi";
          };

          clickhouse-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "clickhouse-dev-password";
          };
        };

        # Phase 2: two users on one database, in a namespace that is not the
        # server's. The writer brings the schema; the reader only selects.
        instances.apps = {
          events-writer = {
            package = packages.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            config = {
              database = "events";
              user = "events_writer";
              privileges = [ "INSERT" ];
              password = "writer-dev-password";
              schema."01-events.sql" = ''
                CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
                (ts DateTime, message String)
                ENGINE = ReplicatedMergeTree ORDER BY ts
                TTL ts + INTERVAL 7 DAY DELETE
              '';
            };
          };

          events-reader = {
            package = packages.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            config = {
              database = "events";
              user = "events_reader";
              privileges = [ "SELECT" ];
              password = "reader-rotated-password";
            };
          };
        };

        # Phase 3: every pod's logs into ClickHouse. The logs package hands
        # its table schema to logs-db by dep config injection; logs-reader is
        # what a dashboard would log in as.
        instances.logging = {
          logs = {
            package = packages.clickhouse-logs;
            config = {
              healthCheck.enabled = true;
              retentionDays = 3;
            };
          };

          logs-db = {
            package = packages.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            config = {
              database = "logs";
              user = "logs_writer";
              privileges = [ "INSERT" ];
              password = "logs-writer-dev-password";
            };
          };
        };

        instances.dashboards.logs-reader = {
          package = packages.clickhouse-database;
          deps.clickhouse = ref.analytics.clickhouse;
          config = {
            database = "logs";
            user = "logs_reader";
            privileges = [ "SELECT" ];
            password = "logs-reader-dev-password";
          };
        };

        # Phases 4 and 5: the operator, a Keeper quorum and a replicated
        # installation, the second implementation of the same contract.
        # `ha-events` is the same facade as `events-writer` above, pointed
        # at it: the swap the contract promises.
        instances.clickhouse-system = {
          clickhouse-operator.package = packages.clickhouse-operator;
          clickhouse-operator-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData = {
              username = "clickhouse_operator";
              password = "operator-dev-password";
            };
          };
        };

        instances.analytics-ha = {
          keeper = {
            package = packages.clickhouse-keeper;
            config.storage.size = "1Gi";
          };
          ch = {
            package = packages.clickhouse-cluster;
            config = {
              storage.size = "5Gi";
              resources.requests.cpu = "250m";
            };
          };
          ch-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "ha-dev-password";
          };
        };

        instances.apps-ha.ha-events = {
          package = packages.clickhouse-database;
          deps.clickhouse = ref.analytics-ha.ch;
          config = {
            database = "events";
            user = "events_writer";
            privileges = [
              "INSERT"
              "SELECT"
            ];
            password = "ha-writer-dev-password";
            schema."01-events.sql" = ''
              CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
              (ts DateTime, message String)
              ENGINE = ReplicatedMergeTree ORDER BY ts
            '';
          };
        };
      }
    )
  ];
}
