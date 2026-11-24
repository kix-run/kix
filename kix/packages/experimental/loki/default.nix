# loki: Grafana Loki as one single-binary pod on one volume.
#
# One StatefulSet pod runs every Loki component in one process. It keeps its
# write-ahead log, TSDB index, and chunks on the filesystem of the claim it
# gets through the `storage` dependency. root = the client Service.
#
#   instances.logs = {
#     storage = { package = packages.persistent-volume-claim; config.size = "20Gi"; };
#     loki.package = packages.experimental.loki;
#   };
#
# Limits: one replica (`availability.max = "none"`), filesystem storage only
# (no object store), and a single tenant.
#
# Upgrades: upstream asks users to upgrade one release at a time where
# possible and allows skipping releases after a test in a development
# environment. Upgrading from 3.7.8 to 3.7.10 in one deploy, which skips
# 3.7.9, kept the logs and the index, and Grafana's Loki data source stayed
# healthy. Upstream documents no way back. In a test, 3.7.8 started on a
# claim that 3.7.10 had written, reported ready, and read its logs. To go
# back, deploy the previous package version.
#
# Beside a workload whose own `storage` dependency is optional (Grafana),
# give Loki's claim another instance name and `aliases`, and wire
# `deps.storage = ref.<ns>.<claim>` as kix.modules.experimental.monitoring does.
# Otherwise both pods mount the one ReadWriteOnce claim.
#
# Dependencies:
#   storage (required)     a persistent-volume-claim instance, mounted at
#                          /var/loki
#   prometheus (optional)  ServiceMonitor on Loki's /metrics and the
#                          alerts below
#
# `out`:
#   out.serviceUrl  "http://<name>.<ns>.svc.<clusterDomain>:3100"
#   out.url { }     the same address, from the root Service
#   out.version     the Loki version `image.tag` names
#
# Both are the base of Loki's HTTP API; a consumer appends the path
# (`/loki/api/v1/push`, `/ready`). `auth_enabled` is locked to false, so
# consumers send no `X-Scope-OrgID` header.
#
# Escape hatches:
#   settings       Loki's `config.yaml` keys, merged over `builtinConfig`
#                  below. A null removes an unlocked key, a list replaces
#                  the package's list whole, and the paths in `lockedPaths`
#                  fail evaluation. Size the claim for the ingest rate times
#                  `settings.limits_config.retention_period` (7 days by
#                  default).
#   extraArgs      flags after the package's own. The flags in `ownedFlags`
#                  fail evaluation: Loki applies flags after the file, so
#                  each one would override a locked path.
#   env            container env, for `${NAME}` expansion in `settings`.
#   resources, partsOverlays, and each resource's `extra` for the rest.
#
# Alerts (PrometheusRule `<name>-alerts`, with metrics on and a prometheus
# dependency):
#   LokiDown                      critical  no target scraped, or the target down
#   LokiIngestionRefusedDiskFull  critical  volume at `ingester.wal.disk_full_threshold`
#                                           (default 90%), every push refused
#   LokiDiskNearlyFull            warning   volume 10 points below that threshold
#   LokiCompactionStale           warning   no successful compaction in twice
#                                           `compactor.compaction_interval`
#                                           plus an hour, at least 3h
#                                           (`metrics.maxCompactionAge`
#                                           overrides)
#   LokiRetentionStale            warning   the same for retention runs and
#                                           `compactor.apply_retention_interval`,
#                                           when `compactor.retention_enabled`
#   LokiChunkFlushFailing         warning   chunks fail to reach the volume
#   LokiWALCheckpointFailing      warning   write-ahead log checkpoints fail
#   LokiDiscardingLogs            warning   lines dropped at a rate or stream limit
#   LokiRequestErrors             warning   5xx share of a route above
#                                           `metrics.requestErrorRatio`
#   LokiPanics                    warning   a request panicked
#   LokiMemoryNearLimit           warning   resident memory above 90% of
#                                           `resources.limits.memory`, when set
# The disk rules read Loki's own gauge of the volume, which also works on
# hostPath-backed claims where the kubelet reports no volume stats. Loki
# updates that gauge only while `ingester.wal.disk_full_threshold` is above
# 0, so setting it to 0 removes both disk rules. Left to
# the generic rules: crash loops and restarts, a write-ahead log replay that
# keeps the pod unready, and a claim filling up where kubelet stats exist.
# Left to the site: query latency, lines dropped for client reasons (too
# old, out of order, too long), and senders that stop sending, which their
# own exporter alerts report.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  release = "3.7.10";

  httpPort = 3100;
  dataPath = "/var/loki";
  configDir = "/etc/loki";

  builtinConfig = {
    auth_enabled = false;
    server = {
      http_listen_port = httpPort;
      grpc_listen_port = 9095;
      log_level = "info";
    };
    common = {
      # The components reach each other over gRPC inside the one process.
      # On loopback that traffic never leaves the pod, so network policy
      # has no pod-to-itself rule to allow.
      instance_addr = "127.0.0.1";
      path_prefix = dataPath;
      replication_factor = 1;
      ring.kvstore.store = "inmemory";
      storage.filesystem = {
        chunks_directory = "${dataPath}/chunks";
        rules_directory = "${dataPath}/rules";
      };
    };
    schema_config.configs = [
      {
        from = "2024-04-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = {
          prefix = "index_";
          period = "24h";
        };
      }
    ];
    limits_config = {
      retention_period = "168h";
      allow_structured_metadata = true;
      volume_enabled = true;
    };
    compactor = {
      retention_enabled = true;
      delete_request_store = "filesystem";
    };
    query_range.results_cache.cache.embedded_cache = {
      enabled = true;
      max_size_mb = 100;
    };
    # Grafana's Logs Drilldown app reads detected patterns from here.
    pattern_ingester.enabled = true;
    analytics.reporting_enabled = false;
  };

  lockedPaths = [
    # Consumers send no X-Scope-OrgID header.
    [ "auth_enabled" ]
    # The Services, the probes, and `out` use httpPort.
    [
      "server"
      "http_listen_port"
    ]
    # The claim is the only writable path that survives a restart.
    [
      "common"
      "path_prefix"
    ]
    [
      "common"
      "storage"
      "filesystem"
    ]
    [
      "common"
      "instance_addr"
    ]
    # The ring defaults for every component: no memberlist Service exists
    # to gossip over, and the one pod holds every stream. A component's own
    # ring keys (`ingester.lifecycler.ring`) take precedence over `common`
    # in Loki and are not locked.
    [
      "common"
      "ring"
      "kvstore"
    ]
    [
      "common"
      "replication_factor"
    ]
  ];

  # Loki applies flags after the config file, so a flag that sets a locked
  # path overrides it.
  ownedFlags =
    let
      locks = path: names: {
        inherit names;
        reason = "it sets ${path}, which the package locks.";
      };
    in
    [
      {
        names = [ "-target" ];
        reason = "the package runs every Loki component in its one pod.";
      }
      (locks "auth_enabled" [ "-auth.enabled" ])
      (locks "server.http_listen_port" [ "-server.http-listen-port" ])
      (locks "common.path_prefix" [ "-common.path-prefix" ])
      (locks "common.storage.filesystem" [
        "-common.storage.filesystem.chunk-directory"
        "-common.storage.filesystem.rules-directory"
      ])
      (locks "common.instance_addr" [ "-common.storage.ring.instance-addr" ])
      (locks "common.ring.kvstore" [ "-common.storage.ring.store" ])
      (locks "common.replication_factor" [ "-common.storage.ring.replication-factor" ])
    ];

  # The rendered config.yaml: `settings` over `builtinConfig`, nulls removed.
  mergeSettings =
    config:
    lib.filterAttrsRecursive (_: v: v != null) (
      kix.mergeGuarded {
        inherit scope;
        option = "settings";
        locked = lockedPaths;
      } builtinConfig config.settings
    );
in
{
  meta = {
    version = release;
    description = "Grafana Loki log store, single binary on one volume";
    owner = "platform";
    defaultAliases = [ "loki" ];
    # One process owns the volume (WAL, TSDB index, chunks). A second
    # replica has no volume of its own and no shared store to read.
    availability.max = "none";
    # Upstream's Helm install page for Loki 3.7.10 says "Kubernetes 1.25 or
    # later" and states no newest version, so no maxVersion is set.
    k8s = {
      minVersion = "1.25";
      reason = "[K0459] loki ${release} requires Kubernetes 1.25 or later. Deploy a Kix release with an older loki package, or move the cluster to a supported Kubernetes version first";
    };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/grafana/loki";
      tag = release;
      digest = "sha256:b43c257ccfc925d4a50b8717cac61a3b51df8c48d01847936057e5c4075a24a7";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        limits_config.retention_period = "720h";
      };
      description = ''
        Loki configuration (`config.yaml` keys) merged over the package's
        own. A null removes a key the package sets. A list replaces the
        package's list whole, so a new `schema_config.configs` period
        restates the earlier ones. The package locks `auth_enabled`,
        `server.http_listen_port`, `common.path_prefix`,
        `common.storage.filesystem`, `common.instance_addr`,
        `common.ring.kvstore`, and `common.replication_factor`; setting
        one, or replacing a key above it, fails evaluation. A component's
        own key (for example `ingester.lifecycler.ring`) takes precedence
        over its `common` default in Loki and is not locked.

        Loki runs with `-config.expand-env=true`, so `''${NAME}` in a value
        reads the container's env var NAME (set it through `env`); an unset
        variable becomes an empty string. Write `$$` for a literal `$`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-log.format=json" ];
      description = ''
        Flags appended after the package's own. Loki applies flags after
        its config file, so the flags that would override a locked
        `settings` path (`-auth.enabled`, `-server.http-listen-port`,
        `-common.path-prefix`, `-common.storage.filesystem.*`,
        `-common.storage.ring.{instance-addr,store,replication-factor}`),
        `-config.file`, `-config.expand-env`, and `-target` fail
        evaluation.
      '';
    };

    env = kix.options.env;

    # Loki 3.7.8 with this config, run outside Kubernetes: about 140 MB
    # resident when idle, and a 484 MB peak over 21 minutes of 100 KB/s
    # ingest across 150 streams with 24-hour queries. Unflushed chunks stay
    # in memory for up to two hours, so heavier ingest needs a higher limit;
    # an OOM kill replays the write-ahead log on restart.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "1Gi";
      };
    };

    metrics = kix.options.monitor // {
      maxCompactionAge = lib.mkOption {
        type = lib.types.nullOr kix.types.promDuration;
        default = null;
        example = "6h";
        description = "How long Loki may go without a successful compaction, or with retention on, a successful retention run, before LokiCompactionStale or LokiRetentionStale fires, as a Prometheus duration. Null derives each rule's threshold from the merged settings: twice `compactor.compaction_interval` (or `compactor.apply_retention_interval` for retention) plus one hour, and at least 3h, the Loki mixin's threshold. At the default 10m interval both are 3h.";
      };
      requestErrorRatio = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 0.1;
        example = 0.05;
        description = "Share of a route's HTTP requests that may answer 5xx before LokiRequestErrors fires. The default is the Loki mixin's.";
      };
      requestErrorMinRate = lib.mkOption {
        type = lib.types.numbers.nonnegative;
        default = 0.1;
        example = 1;
        description = "Requests per second a route must serve before LokiRequestErrors considers its error ratio, so a few failures on a rarely used route do not fire it.";
      };
    };
    healthCheck = kix.options.healthCheck;
  };

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        storage,
        ...
      }:
      let
        mergedConfig = mergeSettings config;

        # Loki parses flags with Go's flag package (pkg/util/cfg/flag.go
        # upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "go";
          args = [
            {
              owned = [ "-config.file=${configDir}/config.yaml" ];
              reason = "the package renders the file from settings.";
              fix = "Change settings instead.";
            }
            {
              owned = [ "-config.expand-env=true" ];
              reason = "settings and env rely on variable expansion.";
            }
          ]
          ++ ownedFlags;
        } config.extraArgs;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."config.yaml" = builtins.toJSON mergedConfig;
        };

        dataMount = kix.mount.pvc storage {
          name = "data";
          mountPath = dataPath;
        };
        configMount = kix.mount.configMap self.configMap {
          name = "config";
          mountPath = configDir;
          readOnly = true;
        };
        tmpMount = kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
          sizeLimit = "256Mi";
        };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
          extra.automountServiceAccountToken = false;
        };

        statefulSet =
          {
            inherit name;
            labels."app.kubernetes.io/name" = "loki";
            spec = {
              headlessService = self.headlessService;
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/config" = self.configMap.out.contentHash;
                spec = {
                  serviceAccount = self.serviceAccount;
                  automountServiceAccountToken = false;
                  # Enough to close the write-ahead log. In-memory chunks are
                  # not flushed on shutdown; the next start replays them
                  # from the log.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 10001;
                    runAsGroup = 10001;
                    fsGroup = 10001;
                    fsGroupChangePolicy = "OnRootMismatch";
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "loki";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit args;
                      env = kix.mkEnvVars (kix.mergeEnv { inherit scope; } config.env);
                      # gRPC (9095) stays inside the pod.
                      ports = [ (kix.port "http" httpPort) ];
                      readinessProbe = {
                        httpGet = {
                          path = "/ready";
                          port = "http";
                        };
                        initialDelaySeconds = 15;
                        periodSeconds = 10;
                      };
                      # /ready answers 503 while the write-ahead log replays
                      # after a restart, which can take minutes, so liveness
                      # only asks whether the port is open.
                      livenessProbe = {
                        tcpSocket.port = "http";
                        periodSeconds = 20;
                        failureThreshold = 6;
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            self.dataMount
            self.configMount
            self.tmpMount
          ]
          |> scope.mkStatefulSet;

        # Governs the StatefulSet's pod DNS; nothing dials it. The component
        # label keeps its labels distinct from the client Service's.
        headlessService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-headless";
            labels."app.kubernetes.io/component" = "headless";
            spec.clusterIP = "None";
          }
          |> scope.mkResource;

        service =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "server";
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          out.serviceUrl = self.service.out.url { };
          out.version = kix.image.version config.image;
        };
      }
    )

    # The alerts read the merged settings and the options, so the wrapper
    # names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${scope.namespaceName}",service="${self.service.out.name}"'';
        by = "by (namespace, service)";
        instance = "Loki ${scope.namespaceName}/${name}";
        merged = mergeSettings config;

        # The alerts read these settings keys, so a value of the wrong type
        # fails here with the key's name rather than in a PromQL string.
        setting =
          path: default: check: expected:
          let
            v = lib.attrByPath path default merged;
          in
          if check v then
            v
          else
            scope.fail {
              option = "settings.${lib.concatStringsSep "." path}";
              message = "settings.${lib.concatStringsSep "." path} must be ${expected} (it is ${builtins.toJSON v}).";
            };
        isRatio = v: (builtins.isInt v || builtins.isFloat v) && v >= 0 && v <= 1;
        walEnabled = setting [ "ingester" "wal" "enabled" ] true builtins.isBool "true or false";
        # Loki's default. At this share of the volume the ingester refuses
        # every push; 0 turns the refusal off.
        fullAt = setting [ "ingester" "wal" "disk_full_threshold" ] 0.9 isRatio "a number from 0 to 1";
        nearlyFullAt = fullAt - 0.1;
        retentionEnabled = setting [
          "compactor"
          "retention_enabled"
        ] false builtins.isBool "true or false";

        percent = x: "${toString (builtins.floor (x * 100 + 0.5))}%";
        memoryLimit = config.resources.limits.memory or null;
        memoryBytes = if memoryLimit == null then null else kix.parseQuantity "memory" memoryLimit;
        # Go durations in whole hours, minutes, and seconds, such as "10m"
        # or "1h30m", which is how Loki's settings write intervals.
        intervalSeconds =
          path: default:
          kix.durations.toSeconds (
            setting path default (
              v: builtins.isString v && builtins.match "([0-9]+[hms])+" v != null
            ) "a duration in hours, minutes, and seconds, such as \"10m\" or \"1h30m\""
          );
        compactionInterval = intervalSeconds [ "compactor" "compaction_interval" ] "10m";
        # Loki's default of 0 applies retention on every compaction run.
        retentionInterval =
          let
            r = intervalSeconds [ "compactor" "apply_retention_interval" ] "0s";
          in
          if r > 0 then r else compactionInterval;
        # One missed run does not fire; the hour covers a slow run.
        staleAfter =
          interval:
          if config.metrics.maxCompactionAge != null then
            config.metrics.maxCompactionAge
          else
            kix.durations.fromSeconds (lib.max (3 * 3600) (2 * interval + 3600));
        compactionAge = staleAfter compactionInterval;
        retentionAge = staleAfter retentionInterval;

        # Loki creates a status="success" series at its first success, so
        # the alert compares the success counter with a target that was
        # scraped `age` ago and is up now.
        noSuccessFor =
          counter: age:
          "(max ${by} (up{${sel}} offset ${age}) and on (namespace, service) max ${by} (up{${sel}} == 1)) unless on (namespace, service) (sum ${by} (increase(${counter}{${sel},status=\"success\"}[${age}])) > 0)";

        requests =
          filter:
          "sum by (namespace, service, route) (rate(loki_request_duration_seconds_count{${sel}${filter}}[5m]))";
        failed = requests '',status_code=~"5.."'';
        total = requests "";
      in
      kix.monitor {
        service = "service";
        port = "http";
        alerts = {
          LokiDown = {
            expr = "sum ${by} (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "Loki is down.";
            description = "Prometheus has scraped no running ${instance} for 10 minutes, so it accepts no logs and answers no queries. Check statefulset/${name} and its pod's events.";
          };
          LokiCompactionStale = {
            expr = noSuccessFor "loki_boltdb_shipper_compact_tables_operation_total" compactionAge;
            "for" = "15m";
            severity = "warning";
            summary = "Loki has not compacted its index recently.";
            description = "${instance} has completed no index compaction in ${compactionAge}. Queries slow down as index files accumulate. Check its log for \"failed to run compaction\".";
          };
          LokiChunkFlushFailing = {
            expr = "sum ${by} (increase(loki_ingester_chunks_flush_failures_total{${sel}}[10m])) > 0";
            "for" = "15m";
            severity = "warning";
            summary = "Loki fails to flush chunks to storage.";
            description = "${instance} has failed to write chunks to its volume for 15 minutes. Unflushed chunks stay in memory and in the write-ahead log, so memory use grows. Check its log for \"failed to flush\" and the volume's free space.";
          };
          LokiWALCheckpointFailing = {
            expr = "sum ${by} (increase(loki_ingester_checkpoint_creations_failed_total{${sel}}[15m])) > 0";
            "for" = "15m";
            severity = "warning";
            summary = "Loki fails to checkpoint its write-ahead log.";
            description = "${instance} has failed to write a write-ahead log checkpoint for 15 minutes. The log grows, and the next restart replays more of it. Check the volume's free space and the pod's log.";
          };
          LokiDiscardingLogs = {
            expr = ''sum by (namespace, service, reason) (rate(loki_discarded_samples_total{${sel},reason=~"rate_limited|per_stream_rate_limit|stream_limit"}[5m])) > 0'';
            "for" = "15m";
            severity = "warning";
            summary = "Loki drops log lines at a configured limit.";
            description = "${instance} has dropped log lines for 15 minutes with reason {{ $labels.reason }}, {{ $value | humanize }} lines per second. Raise the matching limit in settings.limits_config, or reduce what the senders ship.";
          };
          LokiRequestErrors = {
            expr = "${failed} / ${total} > ${toString config.metrics.requestErrorRatio} and ${total} > ${toString config.metrics.requestErrorMinRate}";
            "for" = "15m";
            severity = "warning";
            summary = "Loki answers many requests with a server error.";
            description = "{{ $value | humanizePercentage }} of ${instance}'s requests on route {{ $labels.route }} have failed with a 5xx status for 15 minutes. Check the pod's log for the route's errors.";
          };
          # A recovered panic is a single event; the 15-minute window keeps
          # the alert active for 15 minutes after it, so `for` is omitted.
          LokiPanics = {
            expr = "sum ${by} (increase(loki_panic_total{${sel}}[15m])) > 0";
            severity = "warning";
            summary = "Loki recovered from a panic.";
            description = "${instance} panicked while serving a request in the last 15 minutes and failed that request. The pod's log holds the stack trace.";
          };
        }
        # Loki updates loki_ingester_wal_disk_usage_percent only while
        # disk_full_threshold is above 0, so both disk rules need it.
        // lib.optionalAttrs (walEnabled && fullAt > 0) {
          LokiDiskNearlyFull = {
            expr = "max ${by} (loki_ingester_wal_disk_usage_percent{${sel}}) > ${toString nearlyFullAt}";
            "for" = "15m";
            severity = "warning";
            summary = "Loki's volume is nearly full.";
            description = "${instance}'s volume is {{ $value | humanizePercentage }} full; at ${percent fullAt} Loki refuses every push. Shorten settings.limits_config.retention_period or grow the claim.";
          };
          LokiIngestionRefusedDiskFull = {
            expr = "max ${by} (loki_ingester_wal_disk_usage_percent{${sel}}) >= ${toString fullAt}";
            "for" = "5m";
            severity = "critical";
            summary = "Loki refuses all pushes because its volume is full.";
            description = "${instance}'s volume is {{ $value | humanizePercentage }} full, at or above settings.ingester.wal.disk_full_threshold (${percent fullAt}), so Loki refuses every push and senders hold or drop the logs. Free space: shorten retention, delete data, or grow the claim.";
          };
        }
        // lib.optionalAttrs retentionEnabled {
          LokiRetentionStale = {
            expr = noSuccessFor "loki_compactor_apply_retention_operation_total" retentionAge;
            "for" = "15m";
            severity = "warning";
            summary = "Loki has not applied retention recently.";
            description = "${instance} has completed no retention run in ${retentionAge}, so it deletes no expired logs and its volume keeps growing. Check its log for \"failed to apply retention\".";
          };
        }
        // lib.optionalAttrs (memoryBytes != null && memoryBytes > 0) {
          LokiMemoryNearLimit = {
            expr = "max ${by} (process_resident_memory_bytes{${sel}}) / ${toString memoryBytes} > 0.9";
            "for" = "15m";
            severity = "warning";
            summary = "Loki is near its memory limit.";
            description = "${instance} uses {{ $value | humanizePercentage }} of its ${toString memoryLimit} memory limit. Unflushed chunks are held in memory; an OOM kill replays the write-ahead log on restart. Raise resources.limits.memory.";
          };
        };
      } args
    )

    (kix.healthCheck {
      env =
        { self, ... }:
        {
          LOKI_URL = self.root.out.serviceUrl;
        };
      script = builtins.readFile ./health-check.py;
    })
  ];
}
