# Grafana Loki as a single binary on one volume.
#
# One StatefulSet pod runs every Loki component in one process. It keeps its
# write-ahead log, TSDB index and chunks on the filesystem of the claim it
# gets through the `storage` dependency. It has no gateway, no memberlist and
# no object store, so it stays at one replica.
#
#   instances.logs = {
#     storage = { package = packages.persistent-volume-claim; config.size = "20Gi"; };
#     loki.package = packages.loki;
#   };
#
# Beside a workload whose own `storage` dependency is optional (Grafana),
# give Loki's claim another instance name and `aliases`, and wire
# `deps.storage = ref.<ns>.<claim>` as kix.modules.monitoring does.
# Otherwise both pods mount the one ReadWriteOnce claim
# (housekeeping/2026-10-02-two-workloads-share-one-rwo-claim.md).
#
# Configuration is Loki's own `config.yaml` vocabulary. `settings` is merged
# over `builtinConfig` below: a null removes an unlocked key, a list replaces
# the package's list whole, and the paths in `lockedPaths` fail evaluation.
# Size the claim for the ingest rate times the retention period
# (`settings.limits_config.retention_period`, 7 days by default).
#
# DI deps:
#   storage (required)     a persistent-volume-claim instance, mounted at
#                          /var/loki
#   prometheus (optional)  ServiceMonitor on Loki's /metrics
#
# Exposes:
#   out.serviceUrl  "http://<name>.<ns>.svc.<clusterDomain>:3100"
#   out.url { }     the same address, from the root Service
#
# Both are the base of Loki's HTTP API; a consumer appends the path
# (`/loki/api/v1/push`, `/ready`). Loki runs single-tenant: `auth_enabled`
# is locked to false, so consumers send no `X-Scope-OrgID` header.
#
# root = Service.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "loki ${scope.namespaceName}/${name}";
  release = "3.7.8";

  httpPort = 3100;
  dataPath = "/var/loki";
  configDir = "/etc/loki";
  headlessName = "${name}-headless";

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
    # The Services, the probes and `out` use httpPort.
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
    # No memberlist Service exists for a ring to gossip over.
    [
      "common"
      "ring"
      "kvstore"
    ]
    # One replica.
    [
      "common"
      "replication_factor"
    ]
  ];

  configFlag = "the package renders it from settings; change settings instead.";
  expandFlag = "settings and env rely on variable expansion; remove it.";
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
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/grafana/loki";
      tag = release;
      digest = "sha256:1107dd5274e0ada47e42472b7a7e71f3b2a2fe878878108f3e2f9e51528f0193";
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
        `common.ring.kvstore` and `common.replication_factor`; setting
        one, or replacing a key above it, fails evaluation.

        Loki runs with `-config.expand-env=true`, so `''${NAME}` in a value
        reads the container's env var NAME (set it through `env`); an unset
        variable becomes an empty string. Write `$$` for a literal `$`.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-log.format=json" ];
      description = "Flags appended after the package's own. `-config.file` and `-config.expand-env` belong to the package.";
    };

    env = kix.options.env;

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
        mergedConfig = lib.filterAttrsRecursive (_: v: v != null) (
          kix.mergeGuarded {
            inherit who;
            what = "settings";
            locked = lockedPaths;
          } builtinConfig config.settings
        );

        args = [
          "-config.file=${configDir}/config.yaml"
          "-config.expand-env=true"
        ]
        ++ kix.guardArgs {
          inherit who;
          # Go's flag package reads both spellings.
          owned = {
            "-config.file" = configFlag;
            "--config.file" = configFlag;
            "-config.expand-env" = expandFlag;
            "--config.expand-env" = expandFlag;
          };
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
              # By name: the headless Service is derived from this
              # workload, so the dependency runs from it to here.
              serviceName = headlessName;
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/config" = self.configMap.out.identityHash;
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
                      env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
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
            name = headlessName;
            labels."app.kubernetes.io/component" = "headless";
          }
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

        service =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "server";
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          requires = [ self.headlessService ];
          out.serviceUrl = self.service.out.url { };
        };
      }
    )

    (kix.monitor {
      service = "service";
      port = "http";
    })

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
