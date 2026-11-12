# Tests for kix/packages/experimental/clickhouse-keeper, clickhouse-cluster, and
# clickhouse: the contract's replicas and replicaHosts fields, the refusals of an even Keeper
# quorum and of a cluster with no memory limit, the health check's
# addresses for each replica, Keeper's metrics endpoint, and the alert
# rules of the operator, Keeper, and both server packages and what each
# rule is gated on, and clickhouse-database's refusal of the removed
# password options and its two routes for the `password` dependency.
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
  kixKeys,
  alertRulesOf,
  allSelect,
  prometheusStub,
  storageClassImport,
  ...
}:

let
  operatorPackage = import ../../../packages/experimental/clickhouse-operator;
  keeperPackage = import ../../../packages/experimental/clickhouse-keeper;
  clusterPackage = import ../../../packages/experimental/clickhouse-cluster;
  secretPackage = import ../../../packages/stable/secret;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  barePackage = import ../../../packages/experimental/clickhouse;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;
  databasePackage = import ../../../packages/experimental/clickhouse-database;

  withPrometheus = {
    instances.monitoring.prometheus.package = prometheusStub;
  };

  # `modules` are added to the cluster, such as withPrometheus.
  replicated =
    {
      operatorConfig ? { },
      keeperConfig ? { },
      clusterConfig ? { },
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.clickhouse-system = {
            clickhouse-operator = {
              package = operatorPackage;
              config = operatorConfig;
            };
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

  # `bare` with a clickhouse-database `app-db` in `apps` on `ch`, with
  # `password` as its password dependency `app-db-password` unless that is
  # null.
  withDatabase =
    {
      config ? { },
      password ? {
        package = secretPackage;
        config = {
          source = ./clickhouse.nix;
          hash = "hash";
          keys = [ "password" ];
        };
      },
    }:
    bare {
      modules = [
        (
          { ref, ... }:
          {
            instances.apps = {
              app-db = {
                package = databasePackage;
                deps = {
                  clickhouse = ref.db.ch;
                }
                // lib.optionalAttrs (password != null) {
                  password = ref.apps.app-db-password;
                };
                inherit config;
              };
            }
            // lib.optionalAttrs (password != null) {
              app-db-password = password;
            };
          }
        )
      ];
    };

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

  # The contract requires `replicas` as a string of digits from 1: missing,
  # an integer, and "0" each give one problem; "2" gives none.
  clickhouse-contract-replicas =
    let
      contract = (import ../../../contracts { inherit lib; }).experimental.clickhouse;
      replicasProblems = out: builtins.filter (p: lib.hasPrefix "replicas " p) (contract.problems out);
    in
    (
      builtins.length (replicasProblems { }) == 1
      &&
        builtins.length (replicasProblems {
          replicas = 1;
        }) == 1
      &&
        builtins.length (replicasProblems {
          replicas = "0";
        }) == 1
      && replicasProblems { replicas = "2"; } == [ ]
    )
    || throw "clickhouse contract replicas: ${builtins.toJSON (replicasProblems { })}";

  # The contract requires `replicaHosts` as a non-empty list of strings:
  # missing, empty, and a non-string entry each give one problem.
  clickhouse-contract-replica-hosts =
    let
      contract = (import ../../../contracts { inherit lib; }).experimental.clickhouse;
      hostProblems = out: builtins.filter (p: lib.hasPrefix "replicaHosts " p) (contract.problems out);
    in
    (
      builtins.length (hostProblems { }) == 1
      &&
        builtins.length (hostProblems {
          replicaHosts = [ ];
        }) == 1
      &&
        builtins.length (hostProblems {
          replicaHosts = [ 1 ];
        }) == 1
      &&
        hostProblems {
          replicaHosts = [
            "a"
            "b"
          ];
        } == [ ]
    )
    || throw "clickhouse contract replicaHosts: ${builtins.toJSON (hostProblems { })}";

  # The operator's rules select its metrics Service and need a prometheus
  # dependency and metrics.enabled.
  clickhouse-operator-alerts =
    let
      operatorRules = cluster: alertRulesOf "PrometheusRule" "clickhouse-operator" (manifests cluster);
      rules = operatorRules (replicated {
        modules = [ withPrometheus ];
      });
    in
    (
      allSelect ''namespace="clickhouse-system",service="clickhouse-operator-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "ClickHouseOperatorDown"
          "ClickHouseOperatorReconcileAborted"
        ]
      && operatorRules (replicated { }) == null
      &&
        operatorRules (replicated {
          operatorConfig.metrics.enabled = false;
          modules = [ withPrometheus ];
        }) == null
    )
    || throw "clickhouse-operator alerts: ${
      builtins.toJSON (if rules == null then null else builtins.attrNames rules)
    }";

  # Keeper serves metrics on 7000 through its CHK settings. Its rules select
  # the PodMonitor's job; the follower rule and the follower branch of the
  # quorum rule need more than one replica; nothing renders without a
  # prometheus dependency or with metrics off.
  clickhouse-keeper-alerts =
    let
      keeperOf =
        keeperConfig: modules:
        manifests (replicated {
          inherit keeperConfig modules;
        });
      keeperRules = ms: alertRulesOf "PrometheusRule" "keeper" ms;
      three = keeperOf { } [ withPrometheus ];
      one = keeperOf { replicas = 1; } [ withPrometheus ];
      rules3 = keeperRules three;
      rules1 = keeperRules one;
      chk = builtins.head (ofKind "ClickHouseKeeperInstallation" three);
      podMonitor = byName "keeper" (ofKind "PodMonitor" three);
    in
    (
      chk.spec.configuration.settings."prometheus/port" == "7000"
      && (builtins.head podMonitor.spec.podMetricsEndpoints).portNumber == 7000
      && allSelect ''namespace="db",job="db/keeper"'' rules3
      &&
        builtins.attrNames rules3 == [
          "ClickHouseKeeperDown"
          "ClickHouseKeeperFollowersNotSynced"
          "ClickHouseKeeperMemorySoftLimit"
          "ClickHouseKeeperQuorumLost"
        ]
      && lib.hasInfix "KeeperSyncedFollowers{namespace=\"db\",job=\"db/keeper\"}) < 1 " rules3.ClickHouseKeeperQuorumLost.expr
      && lib.hasInfix ") < 2 " rules3.ClickHouseKeeperFollowersNotSynced.expr
      && !(rules1 ? ClickHouseKeeperFollowersNotSynced)
      && !(lib.hasInfix "KeeperSyncedFollowers" rules1.ClickHouseKeeperQuorumLost.expr)
      && keeperRules (keeperOf { } [ ]) == null
      && ofKind "PodMonitor" (keeperOf { } [ ]) == [ ]
      && keeperRules (keeperOf { metrics.enabled = false; } [ withPrometheus ]) == null
    )
    || throw "clickhouse-keeper alerts: three ${
      builtins.toJSON (if rules3 == null then null else builtins.attrNames rules3)
    }, one ${builtins.toJSON (if rules1 == null then null else builtins.attrNames rules1)}";

  # The removed `password`, `passwordSource`, and `passwordHash` options
  # fail the build, and so does a database with no `password` dependency.
  # A packages.secret with a SOPS source fills both Secrets from that file
  # at deploy.
  clickhouse-database-password-refused =
    let
      secretIn = name: byName name (ofKind "Secret" (manifests (withDatabase { })));
      fromSops =
        name:
        let
          secret = secretIn name;
        in
        secret.metadata.annotations ? ${kixKeys.sopsSource} && !(secret.stringData or { } ? password);
    in
    (
      evalFails (withDatabase {
        config.password = "pw";
      })
      && evalFails (withDatabase {
        config = {
          passwordSource = ./clickhouse.nix;
          passwordHash = "hash";
        };
      })
      && evalFails (withDatabase {
        password = null;
      })
      && fromSops "app-db-credentials"
      && fromSops "app-db-apps-bootstrap-password"
    )
    || throw "clickhouse-database password: ${builtins.toJSON (secretIn "app-db-credentials")}";

  # A password from a secret-ref holding `username` and `password` is the
  # credentials Secret. The package renders no Secret of its own, and the
  # Job reads the password from `<instance>-<namespace>-bootstrap-password`
  # in the server's namespace, which the site writes. A secret-ref without
  # `username` fails.
  clickhouse-database-password-secret-ref =
    let
      withRef =
        keys:
        withDatabase {
          password = {
            package = secretRefPackage;
            config = { inherit keys; };
          };
        };
      cluster = withRef [
        "username"
        "password"
      ];
      ms = manifests cluster;
      secrets = map (m: "${m.metadata.namespace}/${m.metadata.name}") (ofKind "Secret" ms);
      imported = map (m: "${m.metadata.namespace}/${m.metadata.annotations.${kixKeys.importName}}") (
        builtins.filter (m: (m.metadata.annotations or { }).${kixKeys.importKind} or null == "Secret") (
          ofKind "PackageInstance" ms
        )
      );
      job = builtins.head (
        builtins.filter (m: lib.hasPrefix "app-db-apps-bootstrap-" m.metadata.name) (ofKind "Job" ms)
      );
      newPassword =
        (lib.findFirst (e: e.name == "NEW_PASSWORD") null
          (builtins.head job.spec.template.spec.containers).env
        ).valueFrom.secretKeyRef;
      credentialsName = builtins.unsafeDiscardStringContext cluster.instances.apps.app-db.raw.root.out.credentials.out.name;
    in
    (
      newPassword == {
        name = "app-db-apps-bootstrap-password";
        key = "password";
      }
      && job.metadata.namespace == "db"
      && builtins.elem "db/app-db-apps-bootstrap-password" imported
      && builtins.elem "apps/app-db-password" imported
      && credentialsName == "app-db-password"
      && !(builtins.elem "apps/app-db-credentials" secrets)
      && !(builtins.elem "db/app-db-apps-bootstrap-password" secrets)
      && evalFails (withRef [ "password" ])
    )
    || throw "clickhouse-database secret-ref password: ${
      builtins.toJSON {
        inherit
          secrets
          imported
          newPassword
          credentialsName
          ;
      }
    }";
}
