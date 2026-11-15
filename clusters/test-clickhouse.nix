# clusters/test-clickhouse.nix: the bare ClickHouse package on kind
# (v2_discussions/148, phase 1).
#
# One server with its volume and its credentials, embedded Keeper included,
# so replicated DDL works. The probe is on by default, so a deploy proves
# login, that a passwordless login is refused, and that the {cluster} macro
# and Keeper answer.
#
# prometheus-operator gives both ClickHouse packages, the operator, and
# Keeper their scrape and their alert rules; test-clickhouse.rules-test.yaml
# beside this file tests the rules.
#
# Bring up (three workers, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-clickhouse --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Build:   kix build clickhouse
# Deploy:  kix deploy clickhouse --context kind-kix-clickhouse -y
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
          package = packages.experimental.cilium;
        };

        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

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
            package = packages.experimental.clickhouse;
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
            package = packages.experimental.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            deps.password = ref.apps.events-writer-password;
            config = {
              database = "events";
              user = "events_writer";
              privileges = [ "INSERT" ];
              schema."01-events.sql" = ''
                CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
                (ts DateTime, message String)
                ENGINE = ReplicatedMergeTree ORDER BY ts
                TTL ts + INTERVAL 7 DAY DELETE
              '';
            };
          };

          events-reader = {
            package = packages.experimental.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            deps.password = ref.apps.events-reader-password;
            config = {
              database = "events";
              user = "events_reader";
              privileges = [ "SELECT" ];
            };
          };
          events-writer-password = {
            package = packages.secret;
            config = {
              source = ./dev-secrets/clickhouse-writer.sops.yaml;
              keys = [ "password" ];
            };
          };
          events-reader-password = {
            package = packages.secret;
            config = {
              source = ./dev-secrets/clickhouse-reader.sops.yaml;
              keys = [ "password" ];
            };
          };
        };

        # Phase 3: every pod's logs into ClickHouse. The logs package hands
        # its table schema to logs-db by dep config injection; logs-reader is
        # what a dashboard would log in as.
        instances.logging = {
          logs = {
            package = packages.experimental.clickhouse-logs;
            config = {
              healthCheck.enabled = true;
              retentionDays = 3;
            };
          };

          logs-db = {
            package = packages.experimental.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            config = {
              database = "logs";
              user = "logs_writer";
              privileges = [ "INSERT" ];
            };
          };
          logs-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./dev-secrets/clickhouse-logs-writer.sops.yaml;
              keys = [ "password" ];
            };
          };
        };

        instances.dashboards.logs-reader = {
          package = packages.experimental.clickhouse-database;
          deps.clickhouse = ref.analytics.clickhouse;
          config = {
            database = "logs";
            user = "logs_reader";
            privileges = [ "SELECT" ];
          };
        };
        instances.dashboards.logs-reader-password = {
          package = packages.secret;
          aliases = [ "password" ];
          config = {
            source = ./dev-secrets/clickhouse-logs-reader.sops.yaml;
            keys = [ "password" ];
          };
        };

        # Phases 4 and 5: the operator, a Keeper quorum and a replicated
        # installation, the second implementation of the same contract.
        # `ha-events` is the same facade as `events-writer` above, pointed
        # at it: the swap the contract promises.
        instances.clickhouse-system = {
          clickhouse-operator.package = packages.experimental.clickhouse-operator;
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
            package = packages.experimental.clickhouse-keeper;
            config.storage.size = "1Gi";
          };
          ch = {
            package = packages.experimental.clickhouse-cluster;
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
          package = packages.experimental.clickhouse-database;
          deps.clickhouse = ref.analytics-ha.ch;
          config = {
            database = "events";
            user = "events_writer";
            privileges = [
              "INSERT"
              "SELECT"
            ];
            schema."01-events.sql" = ''
              CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
              (ts DateTime, message String)
              ENGINE = ReplicatedMergeTree ORDER BY ts
            '';
          };
        };
        instances.apps-ha.ha-events-password = {
          package = packages.secret;
          aliases = [ "password" ];
          config = {
            source = ./dev-secrets/clickhouse-ha-writer.sops.yaml;
            keys = [ "password" ];
          };
        };
      }
    )
  ];
}
