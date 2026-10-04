# Tests for kix/packages/clickhouse-keeper, clickhouse-cluster, and
# clickhouse: the refusals of an even Keeper quorum and of a cluster with no
# memory limit, the health check's addresses for each replica, and the
# alert rules of both server packages and what each rule is gated on.
# The operator runs in `clickhouse-system`, Keeper and the servers in `db`,
# the prometheus stub in `monitoring`.
# tryEval drops a throw's message, so each refusal is checked with
# evalFails beside a passing control.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  alertRulesOf,
  allSelect,
  prometheusStub,
  storageClassImport,
  ...
}:

let
  operatorPackage = import ../../../packages/clickhouse-operator;
  keeperPackage = import ../../../packages/clickhouse-keeper;
  clusterPackage = import ../../../packages/clickhouse-cluster;
  secretPackage = import ../../../packages/secret;
  barePackage = import ../../../packages/clickhouse;
  pvcPackage = import ../../../packages/persistent-volume-claim;

  withPrometheus = {
    instances.monitoring.prometheus.package = prometheusStub;
  };

  # `modules` are added to the cluster, such as withPrometheus.
  replicated =
    {
      keeperConfig ? { },
      clusterConfig ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.clickhouse-system = {
            clickhouse-operator.package = operatorPackage;
            clickhouse-operator-credentials = {
              package = secretPackage;
              aliases = [ "credentials" ];
              config.stringData = {
                username = "clickhouse_operator";
                password = "test-operator";
              };
            };
          };
          instances.db = {
            keeper = {
              package = keeperPackage;
              config = keeperConfig;
            };
            ch = {
              package = clusterPackage;
              config = clusterConfig;
            };
            ch-credentials = {
              package = secretPackage;
              aliases = [ "credentials" ];
              config.stringData.password = "test-admin";
            };
          };
        }
      ]
      ++ modules
    );

  # The single-node package `ch` in `db`, with its claim and credentials.
  bare =
    {
      config ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.db = {
            ch = {
              package = barePackage;
              inherit config;
            };
            storage = {
              package = pvcPackage;
              config = {
                size = "1Gi";
                storageClassName = "standard";
              };
            };
            standard-class = storageClassImport "standard";
            credentials = {
              package = secretPackage;
              aliases = [ "credentials" ];
              config.stringData.password = "test-admin";
            };
          };
        }
      ]
      ++ modules
    );

  rulesOf = cluster: alertRulesOf "PrometheusRule" "ch" (manifests cluster);

  keeperReplicas =
    cluster:
    (builtins.head (ofKind "ClickHouseKeeperInstallation" (manifests cluster)))
    .spec.configuration.clusters;
in
{
  # One replica and odd counts render; an even count is refused.
  clickhouse-keeper-even-replicas =
    let
      withReplicas = n: replicated { keeperConfig.replicas = n; };
    in
    (
      (builtins.head (keeperReplicas (withReplicas 1))).layout.replicasCount == 1
      && (builtins.head (keeperReplicas (withReplicas 3))).layout.replicasCount == 3
      && evalFails (withReplicas 2)
      && evalFails (withReplicas 4)
    )
    || throw "clickhouse-keeper: an even replica count rendered, or an odd one was refused";

  # The default memory limit renders; removing it is refused.
  clickhouse-cluster-memory-limit =
    (
      ofKind "ClickHouseInstallation" (manifests (replicated { })) != [ ]
      && evalFails (replicated {
        clusterConfig.resources.limits.memory = null;
      })
    )
    || throw "clickhouse-cluster: a cluster with no memory limit rendered, or the default was refused";

  # The health check reaches each replica through the operator's
  # per-replica Service, and extraSpec may not rename those Services.
  clickhouse-cluster-replica-urls =
    let
      cluster = replicated {
        clusterConfig = {
          replicas = 3;
          clusterName = "analytics";
        };
      };
      job = byName "ch-health" (ofKind "Job" (manifests cluster));
      env = builtins.listToAttrs (
        map (e: {
          inherit (e) name;
          value = e.value or null;
        }) (builtins.head job.spec.template.spec.containers).env
      );
      urls = lib.splitString " " env.CLICKHOUSE_REPLICA_URLS;
    in
    (
      map (u: builtins.head (lib.splitString "." (lib.removePrefix "http://" u))) urls == [
        "chi-ch-analytics-0-0"
        "chi-ch-analytics-0-1"
        "chi-ch-analytics-0-2"
      ]
      && builtins.all (lib.hasSuffix ":8123") urls
      && evalFails (replicated {
        clusterConfig.extraSpec.templates.serviceTemplates = [ { name = "x"; } ];
      })
    )
    || throw "clickhouse-cluster replica urls: ${env.CLICKHOUSE_REPLICA_URLS or "unset"}";

  # The single-node rules select on the Service. They render only with a
  # prometheus dependency, metrics on, and the server's `prometheus`
  # fragment in place. ClickHouseMemoryNearLimit needs a memory cap above 0,
  # which a ratio of 0 removes, and the replication rules never render on
  # one replica.
  clickhouse-alerts =
    let
      on = rulesOf (bare {
        modules = [ withPrometheus ];
      });
      noCap = rulesOf (bare {
        config.serverConfig.memory.max_server_memory_usage_to_ram_ratio = 0;
        modules = [ withPrometheus ];
      });
    in
    (
      allSelect ''namespace="db",service="ch"'' on
      && on ? ClickHouseDown
      && on ? ClickHouseMemoryNearLimit
      && !(on ? ClickHouseReplicationLag)
      && noCap ? ClickHouseDown
      && !(noCap ? ClickHouseMemoryNearLimit)
      && rulesOf (bare { }) == null
      &&
        rulesOf (bare {
          config.metrics.enabled = false;
          modules = [ withPrometheus ];
        }) == null
      &&
        rulesOf (bare {
          config.serverConfig.prometheus = null;
          modules = [ withPrometheus ];
        }) == null
      &&
        rulesOf (bare {
          config.serverConfig.prometheus.prometheus = null;
          modules = [ withPrometheus ];
        }) == null
    )
    || throw "clickhouse alerts: ${builtins.toJSON (builtins.attrNames on)}";

  # The cluster's rules select on the PodMonitor's job. The lag and fetch
  # rules render only with more than one replica, and nothing renders
  # without a prometheus dependency, with metrics off, or with a null
  # `prometheus` fragment.
  clickhouse-cluster-alerts =
    let
      with' =
        clusterConfig:
        rulesOf (replicated {
          inherit clusterConfig;
          modules = [ withPrometheus ];
        });
      one = with' { replicas = 1; };
      two = with' { replicas = 2; };
    in
    (
      allSelect ''namespace="db",job="db/ch"'' two
      && two ? ClickHouseReplicationLag
      && two ? ClickHouseReplicatedFetchesFailing
      && lib.hasSuffix "> 300" two.ClickHouseReplicationLag.expr
      && one ? ClickHouseDown
      && !(one ? ClickHouseReplicationLag)
      && !(one ? ClickHouseReplicatedFetchesFailing)
      &&
        rulesOf (replicated {
          clusterConfig.replicas = 2;
        }) == null
      &&
        with' {
          replicas = 2;
          metrics.enabled = false;
        } == null
      &&
        with' {
          replicas = 2;
          serverConfig.prometheus = null;
        } == null
    )
    || throw "clickhouse-cluster alerts: one ${builtins.toJSON (builtins.attrNames one)}, two ${builtins.toJSON (builtins.attrNames two)}";
}
