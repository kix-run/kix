# tempo: Grafana Tempo as one single-binary pod on one volume.
#
# One StatefulSet pod runs every Tempo component (`-target=all`) in one
# process: the distributor with OTLP receivers, the live store, the query
# frontend and querier, and the backend scheduler and worker that compact
# blocks and apply retention. It keeps its write-ahead logs and trace blocks
# on the filesystem of the claim it gets through the `storage` dependency.
# The `<name>` Service serves the query API and metrics on 3200, and the
# `<name>-otlp` Service the OTLP receivers on 4317 (gRPC) and 4318 (HTTP).
# root = the `<name>` Service.
#
#   instances.tracing = {
#     storage = { package = packages.persistent-volume-claim; config.size = "20Gi"; };
#     tempo.package = packages.tempo;
#   };
#
# DI deps:
#   storage (required)     a persistent-volume-claim instance, mounted at
#                          /var/tempo
#   prometheus (optional)  ServiceMonitor on Tempo's /metrics and the
#                          alerts below
#
# Exposes (root.out, checked by kix.contracts.otlpEndpoint):
#   out.otlpGrpcUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4317"
#   out.otlpHttpUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4318"
#   out.tls          false
#   out.queryUrl     "http://<name>.<ns>.svc.<clusterDomain>:3200", the base
#                    of Tempo's query API, for a Grafana datasource
#
# `multitenancy_enabled` is locked to false, so senders and Grafana send no
# `X-Scope-OrgID` header. The instance answers `tempo` only. A sender's
# `otlp` dependency names it with `deps.otlp = ref.<ns>.<instance>`, or the
# cluster adds `aliases = [ "otlp" ]` to the instance.
#
# Escape hatches:
#   settings       Tempo's `tempo.yaml` keys, merged over `builtinConfig`
#                  below. A null removes an unlocked key, a list replaces
#                  the package's list whole, and the paths in `lockedPaths`
#                  fail evaluation. Size the claim for the ingest rate times
#                  `retention`.
#   extraArgs      flags after the package's own. The flags in `ownedFlags`
#                  fail evaluation: Tempo applies flags after the file, so
#                  each one would override a locked path.
#   env            container env, for `${NAME}` expansion in `settings`.
#   resources, partsOverlays, and each resource's `extra` for the rest.
#
# Limits: one replica (`meta.availability.max = "none"`), the local
# filesystem backend only (no object store), a single tenant, and no
# metrics generator (span metrics and service graphs need a remote-write
# target the package does not wire).
#
# Alerts (PrometheusRule `<name>-alerts`, with metrics on and a prometheus
# dependency):
#   TempoDown                 critical  no target scraped, or the target down
#   TempoBlockFlushFailing    warning   completed blocks fail to reach the
#                                       block store
#   TempoDiscardingSpans      warning   spans dropped at a rate, live-trace,
#                                       or trace-size limit
#   TempoBackendJobsFailing   warning   compaction or retention jobs failing
#   TempoRetentionFailing     warning   expired blocks not deleted
#   TempoPollsFailing         warning   the block list cannot be read
#   TempoCompactionBacklog    warning   over 100 blocks waiting for 6 hours
#   TempoRequestErrors        warning   5xx share of a route above
#                                       `metrics.requestErrorRatio`
#   TempoBlocksNearClaimSize  warning   blocks above 80% of the claim, when
#                                       the storage dependency reports `size`
#   TempoMemoryNearLimit      warning   resident memory above 90% of
#                                       `resources.limits.memory`, when set
# The rules come from the Tempo mixin's alerts for the components this
# single binary runs, scoped to the instance. Left to the generic rules:
# crash loops and restarts, and a claim filling up where kubelet stats
# exist. Left to the site or a dashboard: query latency, live-store back
# pressure, spans rejected for client reasons (invalid IDs), and senders
# that stop sending.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "tempo ${scope.namespaceName}/${name}";
  release = "3.1.0";

  httpPort = 3200;
  otlpGrpcPort = 4317;
  otlpHttpPort = 4318;
  dataPath = "/var/tempo";
  configDir = "/etc/tempo";

  # The grammar of Prometheus `model.ParseDuration`, which parses
  # `block_retention`: whole numbers, units from largest to smallest, each
  # unit once. At least one digit must be non-zero, because Tempo reads a
  # zero per-tenant retention as "use the compaction default" (14 days).
  durationType =
    lib.types.addCheck
      (lib.types.strMatching "([0-9]+y)?([0-9]+w)?([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?([0-9]+ms)?")
      (s: builtins.match ".*[1-9].*" s != null);

  # Tempo runs with `-config.expand-env=true`, and its envsubst reads `\\`
  # in the rendered JSON as an escape, so a backslash in a value breaks the
  # file. Returns the dotted paths of the strings that hold one.
  backslashPaths =
    path: v:
    if builtins.isString v then
      lib.optional (lib.hasInfix "\\" v) (lib.concatStringsSep "." path)
    else if builtins.isAttrs v then
      lib.concatLists (lib.mapAttrsToList (k: backslashPaths (path ++ [ k ])) v)
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: backslashPaths (path ++ [ "[${toString i}]" ])) v)
    else
      [ ];

  builtinConfig = retention: {
    target = "all";
    multitenancy_enabled = false;
    # The older spelling of multitenancy_enabled; true turns tenancy on.
    auth_enabled = false;
    http_api_prefix = "";
    # GOMEMLIMIT at 80% of the container's memory limit, so the Go runtime
    # collects garbage harder before the OOM killer acts.
    memory.automemlimit_enabled = true;
    server = {
      http_listen_port = httpPort;
      log_level = "info";
    };
    distributor.receivers.otlp.protocols = {
      # Every interface, so the Services reach the receivers.
      grpc.endpoint = "0.0.0.0:${toString otlpGrpcPort}";
      http.endpoint = "0.0.0.0:${toString otlpHttpPort}";
    };
    # In single-binary mode Tempo forces the live store's ring address to
    # 127.0.0.1 (cmd/tempo/main.go), so the querier's traffic stays in the pod.
    live_store = {
      wal.path = "${dataPath}/live-store/traces";
      shutdown_marker_dir = "${dataPath}/live-store/shutdown-marker";
    };
    backend_scheduler.local_work_path = "${dataPath}/backend-scheduler";
    storage.trace = {
      backend = "local";
      local.path = "${dataPath}/blocks";
    };
    overrides.defaults.compaction.block_retention = retention;
    usage_report.reporting_enabled = false;
  };

  lockedPaths = [
    # `-target=all` is what makes the one pod serve every component.
    [ "target" ]
    # Consumers send no X-Scope-OrgID header.
    [ "multitenancy_enabled" ]
    [ "auth_enabled" ]
    # The Services, the probes, and `out` use these ports and paths.
    [ "http_api_prefix" ]
    [
      "server"
      "http_listen_port"
    ]
    [
      "distributor"
      "receivers"
      "otlp"
      "protocols"
      "grpc"
      "endpoint"
    ]
    [
      "distributor"
      "receivers"
      "otlp"
      "protocols"
      "http"
      "endpoint"
    ]
    # The claim is the only writable path that survives a restart. The live
    # store's write-ahead log, its shutdown marker, the backend scheduler's
    # job cache, and the blocks live there.
    [
      "live_store"
      "wal"
      "path"
    ]
    [
      "live_store"
      "shutdown_marker_dir"
    ]
    [
      "backend_scheduler"
      "local_work_path"
    ]
    [
      "storage"
      "trace"
      "backend"
    ]
    [
      "storage"
      "trace"
      "local"
      "path"
    ]
    [
      "overrides"
      "defaults"
      "compaction"
      "block_retention"
    ]
  ];

  # Tempo applies flags after the config file, so a flag that sets a locked
  # path overrides it. Go's flag package reads the `-` and `--` spellings.
  ownedFlags =
    let
      locks = path: "it sets ${path}, which the package locks; remove it.";
      flags = {
        "-config.file" = "the package renders the file from settings; change settings instead.";
        "-config.expand-env" = "settings and env rely on variable expansion; remove it.";
        "-target" = "the package runs every Tempo component in its one pod; remove it.";
        "-auth.enabled" = locks "auth_enabled";
        "-multitenancy.enabled" = locks "multitenancy_enabled";
        "-http-api-prefix" = locks "http_api_prefix";
        "-server.http-listen-port" = locks "server.http_listen_port";
        "-storage.trace.backend" = locks "storage.trace.backend";
        "-storage.trace.local.path" = locks "storage.trace.local.path";
        "-live-store.wal.path" = locks "live_store.wal.path";
        "-live-store.shutdown_marker_dir" = locks "live_store.shutdown_marker_dir";
        # Tempo 3.1.0 registers this flag with its prefix doubled.
        "-backend-schedulerbackend-scheduler.local-work-path" = locks "backend_scheduler.local_work_path";
      };
    in
    flags // lib.mapAttrs' (flag: lib.nameValuePair "-${flag}") flags;
in
{
  meta = {
    version = release;
    description = "Grafana Tempo trace store, single binary on one volume";
    owner = "platform";
    defaultAliases = [ "tempo" ];
    # One process owns the volume (write-ahead logs and blocks). A second
    # replica has no volume of its own and no shared store to read.
    availability.max = "none";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/grafana/tempo";
      tag = release;
      digest = "sha256:3076b8dcdfb32fd6bc5ccef85e7b7313e6199b9cb84366257fc17ecb696db5fd";
    };

    retention = lib.mkOption {
      type = durationType;
      default = "168h";
      example = "720h";
      description = ''
        How long Tempo keeps a trace block, as a Prometheus duration: whole
        numbers with units `y`, `w`, `d`, `h`, `m`, `s`, and `ms`, largest
        first (`168h`, `7d`, `4w2d`). The default of seven days matches the
        loki package's, so a trace's links to its logs stay valid for as
        long as the trace. Rendered as
        `overrides.defaults.compaction.block_retention`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        query_frontend.search.max_duration = "336h";
      };
      description = ''
        Tempo configuration (`tempo.yaml` keys) merged over the package's
        own. A null removes a key the package sets. A list replaces the
        package's list whole. The package locks `target`,
        `multitenancy_enabled`, `auth_enabled`, `http_api_prefix`,
        `server.http_listen_port`, the OTLP receiver endpoints under
        `distributor.receivers.otlp.protocols`,
        `live_store.wal.path`, `live_store.shutdown_marker_dir`,
        `backend_scheduler.local_work_path`, `storage.trace.backend`,
        `storage.trace.local.path`, and
        `overrides.defaults.compaction.block_retention` (set `retention`);
        setting one, or replacing a key above it, fails evaluation.

        Tempo runs with `-config.expand-env=true`, so `''${NAME}` in a value
        reads the container's env var NAME (set it through `env`); an unset
        variable becomes an empty string. Write `$$` for a literal `$`.
        A backslash in a value is refused, because the expansion consumes it.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-log.level=debug" ];
      description = ''
        Flags appended after the package's own. Tempo applies flags after
        its config file, so the flags that would override a locked
        `settings` path (`-auth.enabled`, `-multitenancy.enabled`,
        `-http-api-prefix`, `-server.http-listen-port`,
        `-storage.trace.{backend,local.path}`, and the live store and backend
        scheduler path flags), `-config.file`, `-config.expand-env`, and
        `-target` fail evaluation.
      '';
    };

    env = kix.options.env;

    # The live store holds up to 250 MB of live traces by default
    # (`live_store.max_live_traces_bytes`), and GOMEMLIMIT follows the limit.
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
      requestErrorRatio = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 0.1;
        example = 0.05;
        description = "Share of a route's HTTP requests that may answer 5xx before TempoRequestErrors fires. The default matches the loki package's.";
      };
      requestErrorMinRate = lib.mkOption {
        type = lib.types.numbers.nonnegative;
        default = 0.1;
        example = 1;
        description = "Requests per second a route must serve before TempoRequestErrors considers its error ratio, so a few failures on a rarely used route do not fire it.";
      };
    };
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
        backslashes = backslashPaths [ "settings" ] config.settings;
        settings =
          if backslashes == [ ] then
            config.settings
          else
            throw "${who}: ${lib.concatStringsSep ", " backslashes} holds a backslash. Tempo expands environment variables in its config file and reads a backslash as an escape, which breaks the file. Remove the backslash from the value.";
        mergedConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded {
            inherit who;
            what = "settings";
            locked = lockedPaths;
          } (builtinConfig config.retention) settings
        );

        args = [
          "-config.file=${configDir}/tempo.yaml"
          "-config.expand-env=true"
        ]
        ++ kix.guardArgs {
          inherit who;
          owned = ownedFlags;
        } config.extraArgs;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data."tempo.yaml" = builtins.toJSON mergedConfig;
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
            labels."app.kubernetes.io/name" = "tempo";
            spec = {
              headlessService = self.headlessService;
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/config" = self.configMap.out.identityHash;
                spec = {
                  serviceAccount = self.serviceAccount;
                  automountServiceAccountToken = false;
                  # Tempo's own HTTP and gRPC drain (`server.graceful_shutdown_timeout`)
                  # is 30 seconds. The live store replays its write-ahead
                  # log from the claim on the next start.
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
                      name = "tempo";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      inherit args;
                      env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
                      # gRPC (9095) stays inside the pod.
                      ports = [
                        (kix.port "http" httpPort)
                        (kix.port "otlp-grpc" otlpGrpcPort)
                        (kix.port "otlp-http" otlpHttpPort)
                      ];
                      readinessProbe = {
                        httpGet = {
                          path = "/ready";
                          port = "http";
                        };
                        initialDelaySeconds = 15;
                        periodSeconds = 10;
                      };
                      # /ready answers 503 until every component has
                      # started, and the live store replays its write-ahead
                      # log before it starts, so liveness only asks whether
                      # the port is open.
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

        # Two client Services, so a query client (Grafana) gets egress to
        # the query port only and a sender to the OTLP ports only.
        service =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "query";
            ports = [
              {
                name = "http";
                port = httpPort;
                targetPort = "http";
              }
            ];
          }
          |> scope.mkResource;

        otlpService =
          self.statefulSet
          |> kix.service.fromWorkload {
            name = "${name}-otlp";
            labels."app.kubernetes.io/component" = "otlp";
            ports = [
              {
                name = "otlp-grpc";
                port = otlpGrpcPort;
                targetPort = "otlp-grpc";
                appProtocol = "grpc";
              }
              {
                name = "otlp-http";
                port = otlpHttpPort;
                targetPort = "otlp-http";
              }
            ];
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          out = kix.contracts.otlpEndpoint.check who {
            otlpGrpcUrl = self.otlpService.out.url { port = otlpGrpcPort; };
            otlpHttpUrl = self.otlpService.out.url { port = otlpHttpPort; };
            tls = false;
            queryUrl = self.service.out.url { port = httpPort; };
          };
        };
      }
    )

    # The alerts read the options, the memory limit, and the claim size, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        storage,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${scope.namespaceName}",service="${self.service.out.name}"'';
        by = "by (namespace, service)";
        instance = "Tempo ${scope.namespaceName}/${name}";
        runbook = "https://github.com/grafana/tempo/blob/v${release}/operations/tempo-mixin/runbook.md";

        memoryLimit = config.resources.limits.memory or null;
        memoryBytes = if memoryLimit == null then null else kix.parseQuantity "memory" memoryLimit;
        claimSize = storage.out.size or null;
        claimBytes = if claimSize == null then null else kix.parseQuantity "storage" claimSize;

        # The mixin's shape for a retried operation: more than two failures
        # in an hour, and still failing in the last five minutes.
        failingLately =
          grouping: counter:
          "sum by (${grouping}) (increase(${counter}{${sel}}[1h])) > 2 and sum by (${grouping}) (increase(${counter}{${sel}}[5m])) > 0";

        requests =
          filter:
          "sum by (namespace, service, route) (rate(tempo_request_duration_seconds_count{${sel}${filter}}[5m]))";
        failed = requests '',status_code=~"5.."'';
        total = requests "";
      in
      kix.monitor {
        service = "service";
        port = "http";
        alerts = {
          TempoDown = {
            expr = "sum ${by} (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "Tempo is down.";
            description = "Prometheus has scraped no running ${instance} for 10 minutes, so it accepts no spans and answers no queries. Check statefulset/${name} and its pod's events.";
          };
          # Both operations are retried without limit, and the blocks wait in
          # the live store's write-ahead log on the same volume meanwhile.
          TempoBlockFlushFailing = {
            expr = "(sum ${by} (increase(tempo_live_store_failed_completions_total{${sel}}[10m])) > 0) or (sum ${by} (increase(tempo_live_store_local_failed_flushes_total{${sel}}[10m])) > 0)";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo fails to write completed trace blocks.";
            description = "${instance} has failed for 15 minutes to complete write-ahead log blocks or write them to its block store. The blocks stay in the write-ahead log, which grows on the same volume. Check the volume's free space and the pod's log.";
          };
          TempoDiscardingSpans = {
            expr = ''sum by (namespace, service, reason) (rate(tempo_discarded_spans_total{${sel},reason=~"rate_limited|live_traces_exceeded|trace_too_large"}[5m])) > 0'';
            "for" = "15m";
            severity = "warning";
            summary = "Tempo drops spans at a configured limit.";
            description = "${instance} has dropped spans for 15 minutes with reason {{ $labels.reason }}, {{ $value | humanize }} spans per second. Raise the matching limit under settings.overrides.defaults, or reduce what the senders ship.";
          };
          TempoBackendJobsFailing = {
            expr = failingLately "namespace, service, job_type" "tempo_backend_scheduler_jobs_failed_total";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo's backend jobs keep failing.";
            description = "${instance}'s {{ $labels.job_type }} jobs have failed more than twice in the last hour and are still failing. Failed compaction slows queries; failed retention lets the volume fill. Check the pod's log for the backend worker's errors.";
            runbook_url = "${runbook}#tempobackendschedulerjobsfailureratehigh";
          };
          TempoRetentionFailing = {
            expr = failingLately "namespace, service" "tempodb_retention_errors_total";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo fails to delete expired blocks.";
            description = "${instance} has failed to mark or delete blocks older than its retention more than twice in the last hour, so its volume keeps growing. Check the pod's log for retention errors.";
          };
          TempoPollsFailing = {
            expr = failingLately "namespace, service" "tempodb_blocklist_poll_errors_total";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo fails to list its blocks.";
            description = "${instance} has failed to poll its block list more than twice in the last hour and is still failing, so new blocks are not queryable and compaction works from a stale list. Check the volume and the pod's log.";
            runbook_url = "${runbook}#tempopollsfailing";
          };
          TempoCompactionBacklog = {
            expr = "sum ${by} (tempodb_compaction_outstanding_blocks{${sel}}) > 100";
            "for" = "6h";
            severity = "warning";
            summary = "Tempo's compaction is falling behind.";
            description = "${instance} has had {{ $value }} blocks waiting for compaction for 6 hours. Queries read more blocks and slow down. Raise resources.limits.cpu, or check TempoBackendJobsFailing.";
            runbook_url = "${runbook}#tempocompactiontoomanyoutstandingblocks";
          };
          TempoRequestErrors = {
            expr = "${failed} / ${total} > ${toString config.metrics.requestErrorRatio} and ${total} > ${toString config.metrics.requestErrorMinRate}";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo answers many requests with a server error.";
            description = "{{ $value | humanizePercentage }} of ${instance}'s requests on route {{ $labels.route }} have failed with a 5xx status for 15 minutes. Check the pod's log for the route's errors.";
          };
        }
        // lib.optionalAttrs (claimBytes != null && claimBytes > 0) {
          # Tempo reports no disk usage for the local backend. The blocks are
          # most of the claim; the write-ahead log and the scheduler's work
          # cache share it.
          TempoBlocksNearClaimSize = {
            expr = "sum ${by} (tempodb_backend_bytes_total{${sel}}) / ${toString claimBytes} > 0.8";
            "for" = "30m";
            severity = "warning";
            summary = "Tempo's blocks nearly fill its volume.";
            description = "${instance}'s trace blocks take {{ $value | humanizePercentage }} of its ${toString claimSize} claim. When the volume fills, Tempo can no longer write blocks. Shorten retention or grow the claim.";
          };
        }
        // lib.optionalAttrs (memoryBytes != null && memoryBytes > 0) {
          # GOMEMLIMIT is 80% of the limit (memory.automemlimit_enabled), so
          # resident memory above 90% means garbage collection no longer
          # holds it below the limit.
          TempoMemoryNearLimit = {
            expr = "max ${by} (process_resident_memory_bytes{${sel}}) / ${toString memoryBytes} > 0.9";
            "for" = "15m";
            severity = "warning";
            summary = "Tempo is near its memory limit.";
            description = "${instance} uses {{ $value | humanizePercentage }} of its ${toString memoryLimit} memory limit. An OOM kill replays the live store's write-ahead log on restart. Raise resources.limits.memory, or lower live_store.max_live_traces_bytes in settings.";
          };
        };
      } args
    )
  ];
}
