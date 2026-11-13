# valkey: Valkey, a Redis-compatible data store, as one StatefulSet on the
# official image. Below availability level "node" it runs one standalone
# pod; from "node" up, three pods, each with a Sentinel sidecar, fail over
# automatically. Pod 0 is the primary on a first start and after every pod
# has stopped, because Sentinel state lives in an emptyDir.
#
# Required dependency `valkeyPassword`: a `secret` or `secret-ref` in this
# namespace, aliased `valkeyPassword`, with key `password`. Auth is always
# on.
#
# `out` honours `kix.contracts.redis`: `host`, `port`, `credentials` (the
# valkeyPassword secret), `tls = false`, and `sentinel`: null, or with
# Sentinel `{ port; primarySet; }`. It also keeps the Service's `name` and `fqdn`.
# Consumers run in this namespace (`meta.scope`). With Sentinel the Service
# also reaches replicas, so a client that writes asks Sentinel for the
# primary, without AUTH.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "8.1.10";

  name = scope.instanceName;
  who = "valkey ${scope.namespaceName}/${name}";

  ports = {
    valkey = 6379;
    sentinel = 26379;
    metrics = 9121;
  };
  # The name Sentinel monitors the primary under, published as
  # `out.sentinel.primarySet`.
  primarySet = "primary";

  conf = import ./conf.nix { inherit lib kix; };

  hardening = {
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };

  execProbe = mode: {
    exec.command = [
      "/opt/valkey/probe.sh"
      mode
    ];
  };
in
{
  meta = {
    version = release;
    description = "Valkey, a Redis-compatible data store: one primary, or a primary with replicas and Sentinel failover";
    owner = "platform";
    lifecycle = "stateful";
    # Consumers read `out.credentials` through a secretKeyRef, which
    # Kubernetes resolves only in the pod's own namespace.
    scope = "namespace";
    defaultAliases = [ "redis" ];
    k8s.minVersion = "1.25";
  };

  assertions =
    { config, ... }:
    [
      # Without Sentinel every pod would start as a primary with its own
      # dataset behind one Service.
      {
        assertion = config.sentinel.enabled || config.replicas == 1;
        message = "replicas is ${toString config.replicas} with sentinel.enabled = false; standalone Valkey runs one pod. Set replicas = 1, or sentinel.enabled = true for a primary with replicas and failover.";
      }
      # Losing the primary's pod also loses its Sentinel, so the others
      # must still reach the quorum.
      {
        assertion = !config.sentinel.enabled || config.replicas >= 3;
        message = "replicas is ${toString config.replicas} with Sentinel on; a failover needs a quorum of Sentinels after the primary's pod is lost, which takes at least 3 pods. Set replicas = 3 or more, or sentinel.enabled = false for one standalone pod.";
      }
      {
        assertion = !config.sentinel.enabled || config.sentinel.quorum <= config.replicas - 1;
        message = "sentinel.quorum is ${toString config.sentinel.quorum} with replicas = ${toString config.replicas}; when the primary's pod is lost its Sentinel goes with it, leaving ${toString (config.replicas - 1)} to agree on the failover. Set sentinel.quorum to at most ${toString (config.replicas - 1)}, or raise replicas.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "docker.io/valkey/valkey";
      tag = release;
      digest = "sha256:640c5e62cea04b6d6f2084232651d0cc70362d31f4f805e7be94dbed6855e8f2";
      description = "Image of valkey-server and the Sentinel sidecar.";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      defaultText = lib.literalMD "3 with Sentinel, else 1";
      description = "Pods of the StatefulSet. Standalone Valkey runs one; with Sentinel, one is the primary and the others replicate it. After a scale-down, Sentinel lists the removed replicas until `SENTINEL RESET primary` runs on each Sentinel.";
    };

    sentinel = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = kix.availability.atLeast "node" availability;
        defaultText = lib.literalMD "true from availability level `node` up";
        description = "Run a Sentinel sidecar in every pod, so a replica takes over when the primary is lost.";
      };
      quorum = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Sentinels that must agree the primary is down before a failover starts (the quorum of `sentinel monitor`).";
      };
      primarySettings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.nullOr (
            lib.types.oneOf [
              lib.types.int
              conf.lineStr
            ]
          )
        );
        default = { };
        example = {
          down-after-milliseconds = 5000;
        };
        description = ''
          Sentinel settings for the monitored primary, rendered as
          `sentinel <key> primary <value>`. They apply over the built-ins
          `down-after-milliseconds = 3000`, `failover-timeout = 10000`, and
          `parallel-syncs = 1`; null drops one. Keys are lower case, and
          values have no line breaks.
        '';
      };
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        limits = {
          cpu = "250m";
          memory = "128Mi";
        };
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.nullOr (
          lib.types.oneOf [
            conf.lineStr
            lib.types.int
            lib.types.bool
            (lib.types.listOf conf.lineStr)
          ]
        )
      );
      default = { };
      example = {
        maxmemory-policy = "allkeys-lru";
        save = [
          "900 1"
          "300 10"
        ];
      };
      description = ''
        valkey.conf directives over the built-ins `appendonly = "yes"` and
        `maxmemory`, which is 70% of `resources.limits.memory` when that is
        set. A bool renders yes or no, a list one line per element, and null
        drops a built-in. Keys are lower case, and values have no line
        breaks. The directives the package owns (`port`, `bind`, the
        password and replication user, replication, `dir`, `include`,
        `user`, `aclfile`, `daemonize`, `rename-command`) are refused.
      '';
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "8Gi";
        description = "Volume requested for each pod, holding the AOF and RDB files.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass of the volumes. Null takes the class from the storageClasses dependency, or with none the cluster default.";
      };
    };

    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "512Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
      description = "Resources of the valkey container. `limits.memory` also sets the built-in `maxmemory`.";
    };

    metrics = kix.options.monitor // {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run the redis_exporter sidecar, a metrics Service, a
          ServiceMonitor, and alerts when the cluster has a prometheus
          provider. The sidecar is part of the pod template, so adding the
          first prometheus provider, or turning this off, restarts every
          pod; a standalone instance is down while its pod restarts.
        '';
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--include-system-metrics" ];
        description = "Flags appended to the exporter's command line. The package owns the flags for the address, credentials, listen address, and metrics path.";
      };
      image = kix.options.image {
        repository = "docker.io/oliver006/redis_exporter";
        tag = "v1.93.0";
        digest = "sha256:6ca518a72f30f7f576ef92963de1b91d3c3f5fd3aeac949f878bfda183587820";
        description = "Image of the metrics exporter sidecar.";
      };
      resources = kix.options.resources {
        requests = {
          cpu = "50m";
          memory = "64Mi";
        };
        # A scrape needs a short burst of CPU. At 250m the exporter spent
        # 30% of its periods throttled, which raised CPUThrottlingHigh.
        limits = {
          cpu = "1";
          memory = "128Mi";
        };
      };
    };
  };

  config =
    { config, ... }:
    {
      replicas = lib.mkDefault (if config.sentinel.enabled then 3 else 1);
    };

  build = [
    (
      {
        self,
        config,
        valkeyPassword,
        storageClasses ? null,
        prometheus ? null,
        ...
      }:
      let
        sentinel = config.sentinel.enabled;
        scrape = config.metrics.enabled && prometheus != null;

        password = kix.contracts.secret.helpers.use {
          inherit who;
          arg = "valkeyPassword";
          dep = valkeyPassword;
          keys = [ "password" ];
        };
        passwordRef = password.out.keyRef "password";

        storageClassName =
          if config.storage.storageClassName != null then
            config.storage.storageClassName
          else if storageClasses != null then
            storageClasses.out.storageClassName
          else
            null;

        maxmemory = conf.maxmemoryFor (config.resources.limits.memory or null);

        valkeyDirectives = conf.overlay (
          {
            appendonly = "yes";
          }
          // lib.optionalAttrs (maxmemory != null) { inherit maxmemory; }
        ) config.settings;

        primaryDirectives = conf.overlay {
          down-after-milliseconds = 3000;
          failover-timeout = 10000;
          parallel-syncs = 1;
        } config.sentinel.primarySettings;

        refused =
          conf.refusals who "settings" (conf.reservedSettings ports.valkey) config.settings
          ++
            conf.refusals who "sentinel.primarySettings" conf.reservedPrimarySettings
              config.sentinel.primarySettings;

        valkeyConf = lib.throwIf (refused != [ ]) (lib.concatStringsSep "\n" refused) (
          conf.render lib.id valkeyDirectives
        );

        sentinelConf = conf.render (k: "sentinel ${k} ${primarySet}") primaryDirectives;

        podName.valueFrom.fieldRef.fieldPath = "metadata.name";

        # Sentinel topology only: what the scripts need to find their peers.
        topologyEnv = lib.optionalAttrs sentinel {
          HEADLESS_FQDN = self.headlessService.out.fqdn;
          VALKEY_REPLICAS = toString config.replicas;
          PRIMARY_SET = primarySet;
        };

        portEnv = {
          VALKEY_PORT = toString ports.valkey;
          SENTINEL_PORT = toString ports.sentinel;
        };

        configMount = kix.mount.configMap self.configMap {
          name = "config";
          mountPath = "/opt/valkey";
          readOnly = true;
          # The scripts run from the mount.
          defaultMode = 365; # 0555
        };

        valkeyContainer = {
          name = "valkey";
          image = kix.image.ref config.image;
          imagePullPolicy = config.image.pullPolicy;
          command = [ "/opt/valkey/start-valkey.sh" ];
          ports = [ (kix.port "valkey" ports.valkey) ];
          # valkey-cli, which the scripts and probes run, reads the password
          # from REDISCLI_AUTH.
          env = kix.mkEnvVars (
            portEnv
            // topologyEnv
            // {
              REDISCLI_AUTH = passwordRef;
              POD_NAME = podName;
              SENTINEL_ENABLED = if sentinel then "yes" else "no";
            }
          );
          inherit (config) resources;
          livenessProbe = execProbe "liveness" // {
            periodSeconds = 10;
            timeoutSeconds = 5;
            failureThreshold = 6;
          };
          readinessProbe = execProbe "readiness" // {
            periodSeconds = 5;
            timeoutSeconds = 3;
            failureThreshold = 3;
          };
          securityContext = hardening;
          volumeMounts = [
            {
              name = "data";
              mountPath = "/data";
            }
          ];
        }
        // lib.optionalAttrs sentinel {
          lifecycle.preStop.exec.command = [
            "/opt/valkey/prestop.sh"
            "valkey"
          ];
        };

        sentinelContainer = {
          name = "sentinel";
          image = kix.image.ref config.image;
          imagePullPolicy = config.image.pullPolicy;
          command = [ "/opt/valkey/start-sentinel.sh" ];
          ports = [ (kix.port "sentinel" ports.sentinel) ];
          env = kix.mkEnvVars (
            portEnv
            // topologyEnv
            // {
              VALKEY_PASSWORD = passwordRef;
              POD_NAME = podName;
              SENTINEL_QUORUM = toString config.sentinel.quorum;
            }
          );
          inherit (config.sentinel) resources;
          livenessProbe = execProbe "sentinel" // {
            periodSeconds = 10;
            timeoutSeconds = 5;
            failureThreshold = 6;
          };
          readinessProbe = execProbe "sentinel" // {
            periodSeconds = 5;
            timeoutSeconds = 3;
            failureThreshold = 3;
          };
          lifecycle.preStop.exec.command = [
            "/opt/valkey/prestop.sh"
            "sentinel"
          ];
          securityContext = hardening;
          # The config volume is declared by the valkey container's mounts.
          volumeMounts = [
            {
              name = configMount.name;
              mountPath = configMount.mountPath;
              readOnly = true;
            }
          ];
        };

        # redis_exporter parses flags with Go's flag package, which takes
        # both `-flag` and `--flag`.
        exporterOwned =
          lib.concatMapAttrs
            (flag: reason: {
              "-${flag}" = reason;
              "--${flag}" = reason;
            })
            {
              "redis.addr" = "the exporter reads the local valkey-server; remove it.";
              "redis.user" = "the exporter authenticates with the valkeyPassword password; remove it.";
              "redis.password" = "the exporter authenticates with the valkeyPassword password; remove it.";
              "redis.password-file" = "the exporter authenticates with the valkeyPassword password; remove it.";
              "web.listen-address" =
                "the metrics Service and probes use port ${toString ports.metrics}; remove it.";
              "web.telemetry-path" = "the ServiceMonitor scrapes /metrics; remove it.";
            };
        exporterArgs = kix.guardArgs {
          inherit who;
          option = "metrics.extraArgs";
          owned = exporterOwned;
        } config.metrics.extraArgs;

        metricsContainer = {
          name = "metrics";
          image = kix.image.ref config.metrics.image;
          imagePullPolicy = config.metrics.image.pullPolicy;
          env = kix.mkEnvVars {
            REDIS_ADDR = "redis://localhost:${toString ports.valkey}";
            REDIS_PASSWORD = passwordRef;
          };
          ports = [ (kix.port "metrics" ports.metrics) ];
          inherit (config.metrics) resources;
          livenessProbe.httpGet = {
            path = "/health";
            port = ports.metrics;
          };
          readinessProbe.httpGet = {
            path = "/health";
            port = ports.metrics;
          };
          securityContext = hardening;
        }
        // lib.optionalAttrs (exporterArgs != [ ]) { args = exporterArgs; };

        valkeyPort = {
          name = "valkey";
          port = ports.valkey;
          targetPort = ports.valkey;
          protocol = "TCP";
        };
        sentinelPort = {
          name = "sentinel";
          port = ports.sentinel;
          targetPort = ports.sentinel;
          protocol = "TCP";
        };
        servicePorts = [ valkeyPort ] ++ lib.optional sentinel sentinelPort;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data = {
            "valkey.conf" = valkeyConf;
            "lib.sh" = builtins.readFile ./scripts/lib.sh;
            "start-valkey.sh" = builtins.readFile ./scripts/start-valkey.sh;
            "probe.sh" = builtins.readFile ./scripts/probe.sh;
          }
          // lib.optionalAttrs sentinel {
            "sentinel.conf" = sentinelConf;
            "start-sentinel.sh" = builtins.readFile ./scripts/start-sentinel.sh;
            "prestop.sh" = builtins.readFile ./scripts/prestop.sh;
          };
        };

        statefulSet =
          {
            inherit name;
            spec = {
              headlessService = self.headlessService;
              replicas = if sentinel then config.replicas else 1;
              # A starting pod asks the Sentinels of the pods already running
              # for the primary. Parallel would start every pod before any
              # Sentinel answers, and each would make itself the primary.
              podManagementPolicy = "OrderedReady";
              updateStrategy.type = "RollingUpdate";
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations = {
                  "checksum/configMap" = self.configMap.out.contentHash;
                }
                # A secret-ref has no contentHash, so a rotation of that
                # Secret does not roll the pods.
                // lib.optionalAttrs (password.out ? contentHash) {
                  "checksum/valkeyPassword" = password.out.contentHash;
                };
                spec = {
                  automountServiceAccountToken = false;
                  # The scripts read only the variables the package sets;
                  # service links would add several for every Service in the
                  # namespace.
                  enableServiceLinks = false;
                  terminationGracePeriodSeconds = 30;
                  # The image's `valkey` user.
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 999;
                    runAsGroup = 999;
                    fsGroup = 999;
                    fsGroupChangePolicy = "OnRootMismatch";
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    valkeyContainer
                  ]
                  ++ lib.optional sentinel sentinelContainer
                  ++ lib.optional scrape metricsContainer;
                };
              };
              volumeClaimTemplates = [
                {
                  metadata.name = "data";
                  spec = {
                    accessModes = [ "ReadWriteOnce" ];
                    resources.requests.storage = toString config.storage.size;
                  }
                  // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
                }
              ];
            };
          }
          # Standalone Valkey never runs a second pod.
          // lib.optionalAttrs (!sentinel) { availability.max = "none"; }
          |> kix.withMountsOn "valkey" [
            configMount
            # The runtime valkey.conf, which holds the password.
            (kix.mount.emptyDir {
              name = "run";
              mountPath = "/run/valkey";
              medium = "Memory";
              sizeLimit = "1Mi";
            })
          ]
          |> (
            if sentinel then
              kix.withMountsOn "sentinel" [
                # sentinel.conf, which Sentinel rewrites as its state changes
                # and which holds the password.
                (kix.mount.emptyDir {
                  name = "sentinel";
                  mountPath = "/sentinel";
                  medium = "Memory";
                  sizeLimit = "1Mi";
                })
              ]
            else
              lib.id
          )
          |> scope.mkStatefulSet;

        # With Sentinel the start scripts read this Service's `out.fqdn`, so
        # it is applied before the StatefulSet and selects through
        # `rawSelector`; `out.selector` would recurse. It publishes unready
        # addresses so a starting pod resolves its peers.
        headlessService =
          if sentinel then
            scope.mkResource {
              apiVersion = "v1";
              kind = "Service";
              name = "${name}-headless";
              labels."app.kubernetes.io/component" = "headless";
              spec = {
                clusterIP = "None";
                publishNotReadyAddresses = true;
                selector = self.statefulSet.rawSelector;
                ports = servicePorts;
              };
            }
          else
            self.statefulSet
            |> kix.service.fromWorkload {
              name = "${name}-headless";
              labels."app.kubernetes.io/component" = "headless";
              spec.clusterIP = "None";
              ports = servicePorts;
            }
            |> scope.mkResource;

        # Every pod, replicas included, so a writer under Sentinel asks
        # Sentinel for the primary.
        mainService =
          self.statefulSet
          |> kix.service.fromWorkload {
            inherit name;
            labels."app.kubernetes.io/component" = "server";
            ports = servicePorts;
            outputs.port = toString ports.valkey;
          }
          |> scope.mkResource;

        metricsService =
          if scrape then
            self.statefulSet
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              labels."app.kubernetes.io/component" = "metrics";
              ports = [
                {
                  name = "metrics";
                  port = ports.metrics;
                  targetPort = ports.metrics;
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        root = {
          resource = self.mainService;
          out = kix.contracts.redis.check who ({
            host = self.mainService.out.fqdn;
            port = toString ports.valkey;
            credentials = password;
            tls = false;
            sentinel =
              if sentinel then
                {
                  port = toString ports.sentinel;
                  inherit primarySet;
                }
              else
                null;
          });
          # Parts the root Service does not reference itself; `requires`
          # keeps them in the build.
          requires = builtins.filter (r: r != null) [
            self.headlessService
            self.metricsService
          ];
        };
      }
    )

    # kix.monitor reads `scope`, `lib`, and `prometheus` from the arguments
    # it is called with, so they are declared here for the build to pass
    # them. It renders the alerts only when the metrics Service exists.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts =
          let
            sel = ''namespace="${scope.namespaceName}", service="${self.metricsService.out.name}"'';
            instance = "Valkey ${scope.namespaceName}/${name}";
          in
          {
            ValkeyDown = {
              expr = "redis_up{${sel}} == 0";
              "for" = "1m";
              severity = "critical";
              summary = "${instance} is down";
              description = "The exporter in pod {{ $labels.pod }} cannot reach valkey-server.";
            };
            ValkeyMetricsAbsent = {
              expr = "absent(redis_up{${sel}})";
              "for" = "5m";
              severity = "critical";
              summary = "${instance} reports no metrics";
              description = "No ${instance} exporter has been scraped for 5 minutes: its pods are Pending or gone, or Prometheus cannot reach them.";
            };
            ValkeyRejectedConnections = {
              expr = "increase(redis_rejected_connections_total{${sel}}[5m]) > 0";
              "for" = "5m";
              severity = "warning";
              summary = "${instance} rejects connections";
              description = "Pod {{ $labels.pod }} rejected client connections in the last 5 minutes, usually at the maxclients limit.";
            };
            ValkeyMemoryNearLimit = {
              expr = "redis_memory_used_bytes{${sel}} / redis_memory_max_bytes{${sel}} > 0.9 and redis_memory_max_bytes{${sel}} > 0";
              "for" = "10m";
              severity = "warning";
              summary = "${instance} is near maxmemory";
              description = "Pod {{ $labels.pod }} uses {{ $value | humanizePercentage }} of maxmemory; with the noeviction policy, writes fail when it is full.";
            };
          }
          // lib.optionalAttrs config.sentinel.enabled {
            ValkeyReplicasMissing = {
              expr = "max by (namespace, service) (redis_connected_slaves{${sel}}) < ${toString (config.replicas - 1)}";
              "for" = "5m";
              severity = "warning";
              summary = "${instance} has fewer replicas than pods";
              description = "The primary has {{ $value }} connected replicas, below the ${toString (config.replicas - 1)} the StatefulSet runs.";
            };
            # count() over no series is empty, so absent() supplies a zero,
            # with the namespace and service labels, when no pod is primary.
            ValkeyPrimaryCount = {
              expr = ''(count by (namespace, service) (redis_instance_info{${sel}, role="master"}) or absent(redis_instance_info{${sel}, role="master"}) * 0) != 1'';
              "for" = "2m";
              severity = "critical";
              summary = "${instance} does not have exactly one primary";
              description = "{{ $value }} pods report the primary role.";
            };
          };
      } args
    )
  ];
}
