# Pod logs into ClickHouse, shipped by Vector (v2_discussions/149).
#
# A Vector agent on every node tails the kubelet's pod log files, shapes
# each line into one flat row and inserts it over ClickHouse's HTTP
# interface. The first consumer of the clickhouse contract
# (v2_discussions/148), and written only against `clickhouse-database`, so
# it runs unchanged on the bare single node and on an operator-run cluster.
#
# The package owns the table. It hands its schema to the database instance
# it depends on through dep config injection, the same way immich hands
# stackgres-database its extensions, so the cluster definition declares a
# `clickhouse-database` instance and nothing about logs:
#
#   instances.logging = {
#     logs      = { package = packages.clickhouse-logs; };
#     logs-db   = { package = packages.clickhouse-database;
#                   config = { privileges = [ "INSERT" ]; password = ...; }; };
#   };
#
# A dashboard reads through a second clickhouse-database instance on the
# same database with [ "SELECT" ].
#
# Vector's configuration is Vector's own vocabulary: `vectorConfig` is
# merged over the package's (`builtinVectorConfig` below), null removes.
#
# DI deps:
#   clickhouseDatabase (required)  the database and the inserting user
#   prometheus (optional)          ServiceMonitor on Vector's own metrics
#
# Exposes:
#   out.database, out.table   where the rows land
#
# The agent runs as uid 0, because the kubelet writes pod logs as root with
# mode 0640, and with nothing else: no capabilities, a read-only root, the
# log directory mounted read-only. A cluster that enforces the scorecard's
# security.nonRoot rule has to accept that for the agent's namespace
# (scorecard.ruleOverrides.byNamespace.<ns>."security.nonRoot").
#
# root = metrics Service.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  table = "logs";
  metricsPort = 9598;

  schemaFor = retentionDays: {
    # Replicated DDL throughout, so it is the same on one node and on many.
    # Sorted for the question people ask ("this pod's logs, newest first"),
    # partitioned by day so retention drops whole parts.
    "10-logs-table.sql" = ''
      CREATE TABLE IF NOT EXISTS {database:Identifier}.${table} ON CLUSTER '{cluster}'
      (
        timestamp DateTime64(9) CODEC(Delta, ZSTD),
        namespace LowCardinality(String),
        pod String,
        container LowCardinality(String),
        node LowCardinality(String),
        stream LowCardinality(String),
        message String CODEC(ZSTD),
        labels Map(LowCardinality(String), String)
      )
      ENGINE = ReplicatedMergeTree
      PARTITION BY toDate(timestamp)
      ORDER BY (namespace, pod, container, timestamp)
      TTL toDateTime(timestamp) + INTERVAL ${toString retentionDays} DAY DELETE
    '';
    # CREATE IF NOT EXISTS leaves an existing table's TTL alone, so a
    # changed retention is applied here. Not materialised: old parts age
    # out under the new rule at their next merge, and nothing is rewritten.
    "20-logs-retention.sql" = ''
      ALTER TABLE {database:Identifier}.${table} ON CLUSTER '{cluster}'
      MODIFY TTL toDateTime(timestamp) + INTERVAL ${toString retentionDays} DAY DELETE
      SETTINGS materialize_ttl_after_modify = 0
    '';
  };
in
{
  meta = {
    version = "0.58.0";
    description = "Pod logs into ClickHouse, shipped by a Vector agent on every node";
    defaultAliases = [ "clusterLogs" ];
  };

  deps = {
    clickhouseDatabase.config = consumerConfig: {
      schema = schemaFor consumerConfig.retentionDays;
    };
    clickhouseDatabase.assertions =
      dep:
      let
        privileges = dep.out.privileges or [ ];
      in
      lib.optional (!(builtins.elem "INSERT" privileges || builtins.elem "ALL" privileges)) {
        assertion = false;
        message = "clickhouse-logs '${name}' inserts rows, and the clickhouse-database instance it resolved to grants its user: ${lib.concatStringsSep ", " privileges}. Add \"INSERT\" to that instance's privileges.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/timberio/vector";
      tag = "0.58.0-distroless-libc";
      digest = "sha256:6c93dfe2554cc7e38316d618961cd657d5271c7a7aa727e0007502b28cb82c2e";
    };

    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days a log row is kept. Becomes the table's TTL.";
    };

    vectorConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        sources.kubernetes_logs.extra_namespace_label_selector = "logs!=off";
      };
      description = ''
        Vector configuration merged over the package's own (sources
        `kubernetes_logs` and `internal_metrics`, transform `row`, sinks
        `clickhouse` and `metrics`). Set a key to null to remove it.
      '';
    };

    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "50m";
          memory = "96Mi";
        };
        limits = {
          cpu = "500m";
          memory = "256Mi";
        };
      };
    };

    metrics = kix.options.monitor;
    healthCheck = kix.options.healthCheck;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        clickhouseDatabase,
        ...
      }:
      let
        db = clickhouseDatabase.out;
        credentialsPath = "/etc/vector-credentials";

        inherit (scope.rbac)
          core
          grant
          watch
          mkClusterRoleSet
          ;

        builtinVectorConfig = {
          data_dir = "/var/lib/vector";

          # Vector no longer expands environment variables in its config
          # (0.58 puts that behind --dangerously-allow-env-var-interpolation).
          # Its secrets backend reads the credentials Secret, mounted as a
          # directory of one file per key, and `SECRET[credentials.<key>]`
          # refers to it.
          secret.credentials = {
            type = "directory";
            path = credentialsPath;
          };

          sources = {
            kubernetes_logs = {
              type = "kubernetes_logs";
              self_node_name = "\${VECTOR_SELF_NODE_NAME}";
            };
            internal_metrics.type = "internal_metrics";
          };

          # One flat row per line, in the table's column names. The source's
          # event carries far more than the table keeps.
          transforms.row = {
            type = "remap";
            inputs = [ "kubernetes_logs" ];
            source = ''
              . = {
                "timestamp": .timestamp,
                "namespace": .kubernetes.pod_namespace,
                "pod": .kubernetes.pod_name,
                "container": .kubernetes.container_name,
                "node": .kubernetes.pod_node_name,
                "stream": .stream,
                "message": .message,
                "labels": object(.kubernetes.pod_labels) ?? {}
              }
            '';
          };

          sinks = {
            clickhouse = {
              type = "clickhouse";
              inputs = [ "row" ];
              # The address goes into the file as a value, so the edge to
              # the ClickHouse Service (ordering, network policy) travels
              # through the ConfigMap like any other. Only the password is
              # looked up at run time, through the secrets backend above.
              endpoint = db.httpUrl;
              inherit (db) database;
              inherit table;
              auth = {
                strategy = "basic";
                user = db.username;
                password = "SECRET[credentials.password]";
              };
              compression = "gzip";
              # The timestamp arrives as RFC 3339 text.
              date_time_best_effort = true;
              batch.timeout_secs = 5;
              # The inserting user may not be allowed the SELECT Vector's
              # health check runs; a failed insert is loud enough.
              healthcheck.enabled = false;
            };
            metrics = {
              type = "prometheus_exporter";
              inputs = [ "internal_metrics" ];
              address = "0.0.0.0:${toString metricsPort}";
            };
          };
        };

        vectorConfig = lib.filterAttrsRecursive (_: v: v != null) (
          lib.recursiveUpdate builtinVectorConfig config.vectorConfig
        );
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."vector.yaml" = builtins.toJSON vectorConfig;
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        configMount = kix.mount.configMap self.configMap {
          mountPath = "/etc/vector";
          readOnly = true;
        };

        credentialsMount = kix.mount.secret db.credentials {
          mountPath = credentialsPath;
          items = [
            {
              key = "password";
              path = "password";
            }
          ];
          defaultMode = 256; # 0400
        };

        daemonSet =
          {
            inherit name;
            labels."app.kubernetes.io/name" = "vector";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/config" = self.configMap.out.identityHash;
                spec = {
                  serviceAccountName = self.serviceAccount.out.name;
                  # Every node's logs, the control plane's included.
                  tolerations = [
                    {
                      operator = "Exists";
                      effect = "NoSchedule";
                    }
                  ];
                  securityContext.seccompProfile.type = "RuntimeDefault";
                  # Long enough to flush the batch in hand.
                  terminationGracePeriodSeconds = 30;
                  containers = [
                    {
                      name = "vector";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      args = [
                        "--config"
                        "/etc/vector/vector.yaml"
                      ];
                      env = kix.mkEnv { } [
                        {
                          name = "VECTOR_SELF_NODE_NAME";
                          valueFrom.fieldRef.fieldPath = "spec.nodeName";
                        }
                      ];
                      ports = [ (kix.port "metrics" metricsPort) ];
                      # The exporter is served by the same topology as the
                      # pipeline, so it answers only once the config loaded.
                      readinessProbe = {
                        httpGet = {
                          path = "/metrics";
                          port = "metrics";
                        };
                        periodSeconds = 10;
                      };
                      livenessProbe = {
                        tcpSocket.port = "metrics";
                        periodSeconds = 20;
                        failureThreshold = 6;
                      };
                      inherit (config) resources;
                      # The kubelet writes pod logs as root, mode 0640, so
                      # reading them takes uid 0. Nothing else is granted:
                      # no capabilities, a read-only root, and the log
                      # directory itself mounted read-only.
                      securityContext = {
                        runAsUser = 0;
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                      volumeMounts = [
                        {
                          name = "var-log";
                          mountPath = "/var/log";
                          readOnly = true;
                        }
                        {
                          name = "data";
                          mountPath = "/var/lib/vector";
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "var-log";
                      hostPath.path = "/var/log";
                    }
                    # Read positions. On the node so a restarted agent
                    # resumes where it stopped and neither drops nor
                    # re-sends what it had already read.
                    {
                      name = "data";
                      hostPath = {
                        path = "/var/lib/vector/${scope.namespaceName}-${name}";
                        type = "DirectoryOrCreate";
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            self.configMount
            self.credentialsMount
          ]
          |> scope.mkDaemonSet;

        service =
          self.daemonSet
          |> kix.service.fromWorkload { name = "${name}-metrics"; }
          |> (
            svc:
            svc
            // {
              spec = svc.spec // {
                clusterIP = "None";
              };
            }
          )
          |> scope.mkResource;

        root = {
          resource = self.service;
          out = {
            inherit (db) database;
            inherit table;
            metricsUrl = "http://${self.service.out.fqdn}:${toString metricsPort}/metrics";
          };
        };
      }
      # What the kubernetes_logs source reads to put a namespace, labels and
      # a node on each line.
      // (mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        labels = scope.selectorLabels;
        roles.${"${scope.namespaceName}-${name}"} = grant [
          (core.pods |> watch)
          (core.namespaces |> watch)
          (core.nodes |> watch)
        ];
      })
    )

    (kix.monitor {
      service = "service";
      port = "metrics";
    })

    (kix.healthCheck {
      env =
        { self, ... }:
        {
          VECTOR_METRICS_URL = self.root.out.metricsUrl;
        };
      script = builtins.readFile ./health-check.py;
    })
  ];
}
