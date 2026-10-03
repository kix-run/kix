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
#   prometheus (optional)  ServiceMonitor on Tempo's /metrics
#
# Exposes (root.out, checked by kix.contracts.otlpEndpoint):
#   out.otlpGrpcUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4317"
#   out.otlpHttpUrl  "http://<name>-otlp.<ns>.svc.<clusterDomain>:4318"
#   out.tls          false
#   out.queryUrl     "http://<name>.<ns>.svc.<clusterDomain>:3200", the base
#                    of Tempo's query API, for a Grafana datasource
#
# `multitenancy_enabled` is locked to false, so senders and Grafana send no
# `X-Scope-OrgID` header. The instance answers both `tempo` and `otlp`; in a
# namespace that also holds an OpenTelemetry collector, wire each consumer's
# `otlp` dependency with `ref`.
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
# target the package does not wire). The package ships no alerts.

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

  # A Go duration with at least one non-zero digit. Tempo reads a zero
  # per-tenant retention as "use the compaction default" (14 days).
  durationType = lib.types.addCheck (lib.types.strMatching "([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+") (
    s: builtins.match ".*[1-9].*" s != null
  );

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
    # The querier reaches the live store at its ring address. On loopback
    # that traffic never leaves the pod, so network policy has no
    # pod-to-itself rule to allow. Single-binary mode already points the
    # querier and backend worker at 127.0.0.1 (cmd/tempo/app/modules.go).
    live_store.ring.instance_addr = "127.0.0.1";
    storage.trace = {
      backend = "local";
      wal.path = "${dataPath}/wal";
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
    [
      "live_store"
      "ring"
      "instance_addr"
    ]
    # The claim is the only writable path that survives a restart.
    [
      "storage"
      "trace"
      "backend"
    ]
    [
      "storage"
      "trace"
      "wal"
      "path"
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
        "-storage.trace.wal.path" = locks "storage.trace.wal.path";
        "-storage.trace.local.path" = locks "storage.trace.local.path";
      };
    in
    flags // lib.mapAttrs' (flag: lib.nameValuePair "-${flag}") flags;
in
{
  meta = {
    version = release;
    description = "Grafana Tempo trace store, single binary on one volume";
    owner = "platform";
    defaultAliases = [
      "tempo"
      kix.contracts.otlpEndpoint.alias
    ];
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
        How long Tempo keeps a trace block, as a Go duration (`168h`,
        `720h`). The default of seven days matches the loki package's, so a
        trace's links to its logs stay valid for as long as the trace.
        Rendered as `overrides.defaults.compaction.block_retention`.
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
        `live_store.ring.instance_addr`, `storage.trace.backend`,
        `storage.trace.wal.path`, `storage.trace.local.path`, and
        `overrides.defaults.compaction.block_retention` (set `retention`);
        setting one, or replacing a key above it, fails evaluation.

        Tempo runs with `-config.expand-env=true`, so `''${NAME}` in a value
        reads the container's env var NAME (set it through `env`); an unset
        variable becomes an empty string. Write `$$` for a literal `$`.
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
        `-storage.trace.{backend,wal.path,local.path}`), `-config.file`,
        `-config.expand-env`, and `-target` fail evaluation.
      '';
    };

    env = kix.options.env;

    # Tempo 3.1.0 with this config, run outside Kubernetes: about 90 MB
    # resident when idle. The live store holds up to 250 MB of live traces
    # by default (`live_store.max_live_traces_bytes`), and GOMEMLIMIT
    # follows the limit.
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

    metrics = kix.options.monitor;
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
        mergedConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded {
            inherit who;
            what = "settings";
            locked = lockedPaths;
          } (builtinConfig config.retention) config.settings
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

    (kix.monitor {
      service = "service";
      port = "http";
    })
  ];
}
