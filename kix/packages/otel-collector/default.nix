# otel-collector: the OpenTelemetry Collector (contrib distribution), as a
# gateway Deployment or a node agent DaemonSet, with no operator and no CRDs.
#
# Installs the collector workload, a ConfigMap holding its configuration, a
# ServiceAccount, and a Service with the OTLP ports (gRPC 4317, HTTP 4318).
# The configuration is the package's pipeline with the instance's `settings`
# deep-merged over it:
#   - the `otlp` receiver on both ports;
#   - the `memory_limiter` processor at 80% of the container's memory limit,
#     and `batch`;
#   - the `health_check` extension on 13133, which the probes read;
#   - the collector's own metrics on 8888, while `metrics.enabled` is true;
#   - one pipeline per dependency and toggle below.
# Evaluation fails when the merged configuration has no pipeline, because
# the collector refuses to start without one.
#
# Modes (`mode`):
#   deployment   a gateway. Replicas follow the cluster's availability level
#                (one at `none`, two at `pod` and `node`, three at `zone`),
#                except with `events.enabled`, below.
#   daemonset    an agent on every Linux node, tolerating every NoSchedule
#                taint. The Service sets `internalTrafficPolicy: Local`, so a
#                pod's telemetry goes to the agent on its own node, and a
#                node without a ready agent drops it.
#
# Dependencies:
#   otlp (optional)         an OTLP endpoint (`kix.contracts.otlpEndpoint`:
#                           `out.otlpGrpcUrl`, and `out.tls` when the
#                           endpoint serves TLS), such as a trace backend or
#                           another otel-collector. Adds the
#                           `otlp_grpc/traces` exporter and a `traces`
#                           pipeline from the `otlp` receiver. Any instance
#                           answering `otlp` binds it (Tempo does); wire a
#                           specific one with `deps.otlp = ref.<ns>.<instance>`.
#                           This package does not answer `otlp`, so an agent
#                           names its gateway explicitly.
#   prometheus (optional)   a ServiceMonitor on the metrics port and the
#                           alert below.
#
# Kubernetes events (`events.enabled`): a `k8s_objects` receiver watches
# core/v1 Events in every namespace, and a `logs/events` pipeline writes each
# one as a line of OTLP JSON to the collector's stdout, where a pod log
# shipper (clickhouse-logs, loki-logs) collects it with the other pod logs.
# The package grants get, list, and watch on events. Only `deployment` mode
# runs it, at one replica, so each event is written once. Two instances with
# `events.enabled` each write every event; nothing refuses that.
#
# Minimal instance, forwarding traces to a backend in the cluster:
#
#   instances.observability.otel-collector = {
#     package = packages.otel-collector;
#     deps.otlp = ref.observability.tempo;
#   };
#
# `out`: `otlpGrpcUrl` and `otlpHttpUrl`, the Service's OTLP addresses
# (`http://<service fqdn>:4317` and `:4318`) for instrumented workloads, and
# `tls = false`. The receivers accept a signal only once a pipeline uses
# them, so an instance with only `events.enabled` publishes addresses
# nothing answers on.
#
# Alerts, scoped to this instance's Service: a collector is not scraped for
# 5 minutes.
#
# Escape hatches: `settings` (the collector's configuration; the locked
# paths are listed in its description), `extraArgs`, `env`, and the
# instance's `partsOverlays`.
#
# Limits: the receivers serve plaintext; TLS on them needs a certificate
# mounted through `partsOverlays` and `settings`. Metrics and logs from the
# `otlp` receiver have no exporter dependency yet, so pipelines for them go
# in `settings`, and under default deny their egress needs a policy of the
# instance's own.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "0.161.0";
  name = scope.instanceName;
  who = "otel-collector ${scope.namespaceName}/${name}";

  grpcPort = 4317;
  httpPort = 4318;
  healthPort = 13133;
  metricsPort = 8888;

  configDir = "/etc/otelcol-contrib";
  configFile = "config.yaml";
in
{
  meta = {
    version = release;
    description = "OpenTelemetry Collector, a gateway Deployment or a node agent DaemonSet, receiving OTLP";
    owner = "platform";
  };

  # CONTRACT (otlpEndpoint): deps.otlp.assertions = dep: kix.contracts.otlpEndpoint.assertions who dep;

  options = {
    image = kix.options.image {
      repository = "docker.io/otel/opentelemetry-collector-contrib";
      tag = release;
      digest = "sha256:fd328de2552466ad78385e1b1289c3f2402b1c45f265b252aab1955b42845ac1";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "deployment"
        "daemonset"
      ];
      default = "deployment";
      description = "`deployment` runs a gateway whose replicas follow the availability level. `daemonset` runs an agent on every node, and the Service routes each pod's telemetry to the agent on its node (`internalTrafficPolicy: Local`).";
    };

    events.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Watch Kubernetes Events in every namespace and write each one to the collector's stdout as OTLP JSON, for a pod log shipper to collect. Needs `mode = \"deployment\"`, and runs the Deployment at one replica.";
    };

    # The upstream chart sets no default. The memory limit is what
    # memory_limiter's percentages apply to.
    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    env = kix.options.env // {
      description = "Extra environment variables for the collector, such as values that `settings` reads as `\${env:NAME}`: a string, a `fieldRef` source, or a `kix.untrackedRef` secretKeyRef.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--feature-gates=+extension.healthcheck.useComponentStatus" ];
      description = "Flags appended after `--config`. `--config` and `--set` are refused: put configuration in `settings`.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        exporters.debug.verbosity = "basic";
        service.pipelines.metrics = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "batch"
          ];
          exporters = [ "debug" ];
        };
      };
      description = ''
        Collector configuration, deep-merged over the package's (see the
        package header); a list replaces the package's list. The package
        locks `extensions.health_check.endpoint` (the probes),
        `receivers.otlp.protocols.{grpc,http}.endpoint` (the Service),
        `service.telemetry.metrics.readers` (the metrics port),
        `exporters."otlp_grpc/traces".endpoint` (from `deps.otlp`),
        `exporters."file/events".path`, and `receivers.k8s_objects.objects`
        (the RBAC grants events only); `receivers.k8s_objects` needs
        `events.enabled`. `health_check` is always in
        `service.extensions`. Setting a locked path fails evaluation.
      '';
    };

    metrics = kix.options.monitor;
  };

  assertions =
    { config, ... }:
    [
      {
        assertion = !(config.events.enabled && config.mode == "daemonset");
        message = "events.enabled needs mode = \"deployment\": every agent of a DaemonSet would watch the same Events and write each one once per node. Run events on a separate deployment-mode instance.";
      }
    ];

  build = [
    (
      {
        self,
        config,
        scope,
        kix,
        otlp ? null,
        prometheus ? null,
        ...
      }:
      let
        daemonset = config.mode == "daemonset";
        events = config.events.enabled;
        # Only `metrics.enabled` changes the pod template; a prometheus
        # dependency adds the Service port and the ServiceMonitor.
        metricsOn = config.metrics.enabled;
        scraped = metricsOn && prometheus != null;

        tracesUrl = otlp.out.otlpGrpcUrl;
        # The gRPC exporter speaks TLS unless told otherwise, whatever the
        # URL's scheme.
        tracesTls = (otlp.out.tls or null) == true || lib.hasPrefix "https://" tracesUrl;

        # A Deployment watching Events runs one pod, so each event is written
        # once; the ceiling below keeps the lib's spread and budgets at that.
        replicas =
          if events then
            1
          else
            kix.availability.pick availability {
              none = 1;
              pod = 2;
              node = 2;
              zone = 3;
            };

        builtinSettings = {
          extensions.health_check.endpoint = "0.0.0.0:${toString healthPort}";

          receivers = {
            otlp.protocols = {
              grpc.endpoint = "0.0.0.0:${toString grpcPort}";
              http.endpoint = "0.0.0.0:${toString httpPort}";
            };
          }
          // lib.optionalAttrs events {
            # Watch from the current resourceVersion: only Events created or
            # changed after the collector starts.
            k8s_objects.objects = [
              {
                name = "events";
                mode = "watch";
              }
            ];
          };

          processors = {
            # Percentages of the cgroup memory limit, as upstream advises in
            # containers.
            memory_limiter = {
              check_interval = "1s";
              limit_percentage = 80;
              spike_limit_percentage = 25;
            };
            batch = { };
          };

          exporters =
            lib.optionalAttrs (otlp != null) {
              # The URL travels through the ConfigMap into the pod, which
              # gives the dependency edge and the derived egress.
              "otlp_grpc/traces" = {
                endpoint = tracesUrl;
                tls.insecure = !tracesTls;
              };
            }
            // lib.optionalAttrs events {
              # One OTLP JSON object per line. stdout is the collector's
              # own, so the pod log shipper reads it; the collector's logs
              # go to stderr.
              "file/events" = {
                path = "/dev/stdout";
                append = true;
                format = "json";
              };
            };

          service = {
            extensions = [ "health_check" ];
            telemetry.metrics =
              if metricsOn then
                {
                  readers = [
                    {
                      pull.exporter.prometheus = {
                        host = "0.0.0.0";
                        port = metricsPort;
                      };
                    }
                  ];
                }
              else
                { level = "none"; };
            pipelines =
              lib.optionalAttrs (otlp != null) {
                traces = {
                  receivers = [ "otlp" ];
                  processors = [
                    "memory_limiter"
                    "batch"
                  ];
                  exporters = [ "otlp_grpc/traces" ];
                };
              }
              // lib.optionalAttrs events {
                # No batch processor, so each line holds one event.
                "logs/events" = {
                  receivers = [ "k8s_objects" ];
                  processors = [ "memory_limiter" ];
                  exporters = [ "file/events" ];
                };
              };
          };
        };

        merged = kix.mergeGuarded {
          inherit who;
          what = "settings";
          locked = [
            [
              "extensions"
              "health_check"
              "endpoint"
            ]
            [
              "receivers"
              "otlp"
              "protocols"
              "grpc"
              "endpoint"
            ]
            [
              "receivers"
              "otlp"
              "protocols"
              "http"
              "endpoint"
            ]
            [
              "service"
              "telemetry"
              "metrics"
              "readers"
            ]
            [
              "exporters"
              "otlp_grpc/traces"
              "endpoint"
            ]
            [
              "exporters"
              "file/events"
              "path"
            ]
            (
              if events then
                [
                  "receivers"
                  "k8s_objects"
                  "objects"
                ]
              else
                [
                  "receivers"
                  "k8s_objects"
                ]
            )
          ];
        } builtinSettings config.settings;

        userExtensions = merged.service.extensions or [ ];
        collectorConfig =
          if builtins.isList userExtensions then
            lib.recursiveUpdate merged {
              service.extensions = lib.unique ([ "health_check" ] ++ userExtensions);
            }
          else
            throw "${who}: settings.service.extensions must be a list of extension names; got ${builtins.typeOf userExtensions}.";

        pipelines = collectorConfig.service.pipelines or { };

        probe = {
          httpGet = {
            path = "/";
            port = "health";
          };
          periodSeconds = 10;
        };

        podSpec = {
          serviceAccount = self.serviceAccount;
          # Kubernetes' default. The batch processor's default timeout is
          # 200ms, so its batch in hand is sent well within it.
          terminationGracePeriodSeconds = 30;
          securityContext = {
            runAsNonRoot = true;
            # The image's otel user.
            runAsUser = 10001;
            runAsGroup = 10001;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "otel-collector";
              image = kix.image.ref config.image;
              imagePullPolicy = config.image.pullPolicy;
              args = [
                "--config=${configDir}/${configFile}"
              ]
              ++ kix.guardArgs {
                inherit who;
                owned = {
                  "--config" = "the package's merged settings are the collector's only configuration; put configuration in settings.";
                  "--set" = "it overrides configuration paths after the package's checks; put configuration in settings.";
                };
              } config.extraArgs;
              env = kix.mkEnvVars (kix.mergeEnv { inherit who; } config.env);
              ports = [
                (kix.port "otlp-grpc" grpcPort)
                (kix.port "otlp-http" httpPort)
                (kix.port "health" healthPort)
              ]
              ++ lib.optional metricsOn (kix.port "metrics" metricsPort);
              livenessProbe = probe;
              readinessProbe = probe;
              resources = config.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = [ "ALL" ];
              };
            }
          ];
        }
        // lib.optionalAttrs (!events) {
          # Only the events receiver calls the API server.
          automountServiceAccountToken = false;
        }
        // lib.optionalAttrs daemonset {
          # Every node a workload may send from, the control plane included.
          tolerations = [
            {
              operator = "Exists";
              effect = "NoSchedule";
            }
          ];
          nodeSelector."kubernetes.io/os" = "linux";
        };

        workloadBody = {
          inherit name;
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.annotations."checksum/config" = self.configMap.out.identityHash;
              spec = podSpec;
            };
          }
          // lib.optionalAttrs (!daemonset) { inherit replicas; };
        };

        inherit (scope.rbac)
          core
          grant
          watch
          mkClusterRoleSet
          ;
      in
      if !builtins.isAttrs pipelines then
        throw "${who}: settings.service.pipelines must be an attribute set of pipelines; got ${builtins.typeOf pipelines}."
      else if pipelines == { } then
        throw "${who}: the collector has no pipeline and would refuse to start. Wire an OTLP endpoint with deps.otlp, set events.enabled, or define service.pipelines in settings."
      else
        {
          configMap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-config";
            data.${configFile} = builtins.toJSON collectorConfig;
          };

          configMount = kix.mount.configMap self.configMap {
            mountPath = configDir;
            readOnly = true;
          };

          serviceAccount = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            inherit name;
          };

          workload =
            workloadBody
            |> kix.withMounts [ self.configMount ]
            |> (
              if daemonset then
                scope.mkDaemonSet
              else
                (
                  w:
                  scope.mkDeployment (
                    w
                    // lib.optionalAttrs events {
                      # One replica watches Events; see `replicas`.
                      availability.max = "none";
                    }
                  )
                )
            );

          service =
            self.workload
            |> kix.service.fromWorkload (
              {
                inherit name;
                ports = [
                  {
                    name = "otlp-grpc";
                    port = grpcPort;
                    targetPort = "otlp-grpc";
                    appProtocol = "grpc";
                  }
                  {
                    name = "otlp-http";
                    port = httpPort;
                    targetPort = "otlp-http";
                  }
                ]
                ++ lib.optional scraped {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = "metrics";
                };
              }
              // lib.optionalAttrs daemonset { spec.internalTrafficPolicy = "Local"; }
            )
            |> scope.mkResource;

          root = {
            resource = self.service;
            requires = builtins.filter (p: p != null) [
              (self.serviceMonitor or null)
              (self.prometheusRules or null)
            ];
            # CONTRACT (otlpEndpoint): out = kix.contracts.otlpEndpoint.check who { ... };
            out = {
              otlpGrpcUrl = self.service.out.url { port = grpcPort; };
              otlpHttpUrl = self.service.out.url { port = httpPort; };
              tls = false;
            };
          };
        }
        # The role name joins the namespace and the instance with a dot,
        # which neither contains, so two instances never share it.
        // lib.optionalAttrs events (
          mkClusterRoleSet scope {
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.serviceAccount.out.name;
                namespace = scope.namespaceName;
              }
            ];
            labels = scope.selectorLabels;
            roles.${"${scope.namespaceName}.${name}"} = grant [ (core.events |> watch) ];
          }
        )
    )

    (kix.monitor {
      service = "service";
      alerts =
        let
          scoped = ''namespace="${scope.namespaceName}", service="${name}"'';
        in
        {
          OtelCollectorDown = {
            expr = "up{${scoped}} == 0";
            "for" = "5m";
            severity = "critical";
            summary = "An OpenTelemetry Collector is down.";
            description = "Prometheus has not scraped the collector at {{ $labels.instance }} for 5 minutes; telemetry sent to it may be lost.";
          };
        };
    })
  ];
}
