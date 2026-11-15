# clickhouse-logs: every pod's logs into ClickHouse, shipped by a Vector
# agent on every node.
#
# A DaemonSet tails the kubelet's pod log files, shapes each line into one
# flat row (timestamp, namespace, pod, container, node, stream, message, pod
# labels), and inserts it over ClickHouse's HTTP interface. It is written
# only against `clickhouse-database`, so it runs the same on a single
# ClickHouse node and on an operator-run cluster.
#
# The package owns the table. It hands the schema to the database instance it
# depends on through dep config injection, so the cluster definition declares
# a `clickhouse-database` instance and nothing about logs:
#
#   instances.logging = {
#     logs      = { package = packages.experimental.clickhouse-logs; };
#     logs-db   = { package = packages.experimental.clickhouse-database;
#                   config = { privileges = [ "INSERT" ]; password = ...; }; };
#   };
#
# A dashboard reads through a second clickhouse-database instance on the
# same database with [ "SELECT" ].
#
# Dependencies:
#   clickhouseDatabase (required)  the database and the inserting user
#   prometheus (optional)          ServiceMonitor on Vector's own metrics
#
# `out`:
#   out.database, out.table   where the rows land
#   out.metricsUrl            every agent's Prometheus endpoint, through the
#                             headless metrics Service (root)
#   out.version               the Vector version `image.tag` names
#
# Escape hatches: `settings` (Vector's own config, merged over the
# package's; a null removes an unlocked key), `extraArgs`, `env`, and the
# instance's `partsOverlays` for tolerations, extra volumes and the rest.
#
# The agent runs as uid 0 to read the kubelet's log files and mounts host
# paths, so the package declares the `run-as-root` grant and the namespace
# runs at the `privileged` Pod Security level.
#
# The Vector agent itself (image, options, pod spec, RBAC, health check)
# comes from ./vector-agent.nix, which loki-logs shares.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "clickhouse-logs ${scope.namespaceName}/${name}";
  table = "logs";
  vectorAgent = import ./vector-agent.nix { inherit lib kix; };
  credentialsPath = "/etc/vector-credentials";

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
    inherit (vectorAgent) version;
    description = "Pod logs into ClickHouse, shipped by a Vector agent on every node";
    owner = "platform";
    # The kubelet writes pod logs as root with mode 0640, so the agent reads
    # them as uid 0, with no capabilities and a read-only root filesystem.
    unsafe = [ "run-as-root" ];
    # hostPath volumes (the node's /var/log and the read positions), which
    # the baseline Pod Security level forbids.
    podSecurity = "privileged";
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
        message = "deps.clickhouseDatabase resolved to a clickhouse-database instance whose user has ${
          if privileges == [ ] then "no privileges" else "only ${lib.concatStringsSep ", " privileges}"
        }, and the agent inserts rows. Add \"INSERT\" to that instance's privileges.";
      };
  };

  options = vectorAgent.options // {
    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days a log row is kept. Becomes the table's TTL.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        sources.kubernetes_logs.extra_namespace_label_selector = "logs!=off";
        sinks.clickhouse.batch.timeout_secs = 10;
      };
      description = ''
        Vector configuration merged over the package's own: sources
        `kubernetes_logs` and `internal_metrics`, transform `row`, sinks
        `clickhouse` and `metrics`, and the `credentials` secrets backend. A
        null removes a key the package sets. The package locks `data_dir`,
        `sources.internal_metrics.type`, and
        `sinks.metrics.{type,inputs,address}` (probes, metrics Service, and
        health check), `sinks.clickhouse.type`, `.endpoint`,
        `.database`, and `.auth` (from `deps.clickhouseDatabase`),
        `sinks.clickhouse.table` (the table this package creates), and
        `secret.credentials` (the mounted password); setting one, or
        replacing a key above it, fails evaluation.
      '';
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

        builtinSettings = lib.recursiveUpdate vectorAgent.baseConfig {
          # Vector no longer expands environment variables in its config
          # (0.58 puts that behind --dangerously-allow-env-var-interpolation).
          # Its secrets backend reads the credentials Secret, mounted as a
          # directory of one file per key, and `SECRET[credentials.<key>]`
          # refers to it.
          secret.credentials = {
            type = "directory";
            path = credentialsPath;
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

          sinks.clickhouse = {
            type = "clickhouse";
            inputs = [ "row" ];
            # The address goes into the file as a value, so the edge to the
            # ClickHouse Service (ordering, network policy) travels through
            # the ConfigMap like any other. Only the password is looked up
            # at run time, through the secrets backend above.
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
        };

        mergedSettings = vectorAgent.mergeConfig {
          inherit who;
          sink = "clickhouse";
          locked = [
            [
              "secret"
              "credentials"
            ]
            [
              "sinks"
              "clickhouse"
              "database"
            ]
            [
              "sinks"
              "clickhouse"
              "table"
            ]
            [
              "sinks"
              "clickhouse"
              "auth"
            ]
          ];
        } builtinSettings config.settings;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data.${vectorAgent.configFile} = builtins.toJSON mergedSettings;
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        configMount = kix.mount.configMap self.configMap {
          mountPath = vectorAgent.configDir;
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
          lib.pipe
            {
              inherit name;
              spec = {
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.annotations."checksum/config" = self.configMap.out.contentHash;
                  spec = vectorAgent.podSpec {
                    inherit
                      scope
                      who
                      name
                      config
                      self
                      ;
                  };
                };
              };
            }
            [
              (kix.withMounts [
                self.configMount
                self.credentialsMount
              ])
              scope.mkDaemonSet
            ];

        service = lib.pipe self.daemonSet [
          (kix.service.fromWorkload {
            name = "${name}-metrics";
            spec.clusterIP = "None";
          })
          scope.mkResource
        ];

        root = {
          resource = self.service;
          out = {
            inherit (db) database;
            inherit table;
            metricsUrl = "${self.service.out.url { }}/metrics";
            version = kix.image.version config.image;
          };
        };
      }
      // vectorAgent.rbac { inherit scope self name; }
    )

    (kix.monitor {
      service = "service";
      port = "metrics";
    })

    (vectorAgent.healthCheck { sink = "clickhouse"; })
  ];
}
