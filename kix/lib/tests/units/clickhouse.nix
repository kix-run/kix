# Tests for kix/packages/clickhouse-keeper and clickhouse-cluster: the
# refusals of an even Keeper quorum and of a cluster with no memory limit,
# and the health check's addresses for each replica.
# The operator runs in `clickhouse-system`, Keeper and the servers in `db`.
# tryEval drops a throw's message, so each refusal is checked with
# evalFails beside a passing control.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  operatorPackage = import ../../../packages/clickhouse-operator;
  keeperPackage = import ../../../packages/clickhouse-keeper;
  clusterPackage = import ../../../packages/clickhouse-cluster;
  secretPackage = import ../../../packages/secret;

  replicated =
    {
      keeperConfig ? { },
      clusterConfig ? { },
    }:
    mkCluster [
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
    ];

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
}
