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
#                (one at `none`, two above),
#                except with `events.enabled`, below.
#   daemonset    an agent on every Linux node, tolerating every NoSchedule
#                taint. The Service sets `internalTrafficPolicy: Local`, so a
#                pod's telemetry goes to the agent on its own node, and a
#                node without a ready agent drops it.
#
# Dependencies:
#   otlp (optional)         an OTLP endpoint (`kix.contracts.experimental.otlpEndpoint`:
#                           `out.otlpGrpcUrl`, and `out.tls` when the
#                           endpoint serves TLS), such as a trace backend or
#                           another otel-collector. Adds the
#                           `otlp_grpc/traces` exporter and a `traces`
#                           pipeline from the `otlp` receiver. An instance
#                           the cluster aliases `otlp` binds it; otherwise
#                           wire one with `deps.otlp = ref.<ns>.<instance>`.
#                           Neither this package nor tempo answers `otlp` by
#                           default, so left unwired the dependency stays
#                           unbound and no traces pipeline is added.
#   prometheus (optional)   a ServiceMonitor on the metrics port and the
#                           alert below.
#
# Kubernetes events (`events.enabled`): a `k8s_objects` receiver watches
# core/v1 Events in every namespace, and a `logs/events` pipeline writes each
# watch notification as a line of OTLP JSON to the collector's stdout, where
# a pod log shipper (clickhouse-logs, loki-logs) collects it with the other
# pod logs. An Event is written when it is created and again each time it
# changes (its `count` rises); the deletion the API server sends when an
# Event's TTL expires is excluded (`exclude_watch_type`). `settings` may
# replace `receivers.k8s_objects.objects` to set `field_selector`,
# `namespaces`, or the watch types, as long as every entry watches core
# `events`, the only resource the package grants get, list, and watch on.
# Only `deployment` mode runs the receiver, at one replica, so one pod writes
# each notification; during a rolling update the old and new pod both watch
# for a few seconds and may both write it. Two instances with
# `events.enabled` each write every event; nothing refuses that.
#
# Minimal instance, forwarding traces to a backend in the cluster:
#
#   instances.observability.otel-collector = {
#     package = packages.experimental.otel-collector;
#     deps.otlp = ref.observability.tempo;
#   };
#
# `out`: `version`, the collector version `image.tag` names, `otlpGrpcUrl` and
# `otlpHttpUrl`, the Service's OTLP addresses
# (`http://<service fqdn>:4317` and `:4318`) for instrumented workloads, and
# `tls = false`. The collector opens the `otlp` receiver only when a
# pipeline lists it, so in an instance where none does (only
# `events.enabled`), reading either address fails evaluation naming the
# instance.
#
# Alerts, scoped to this instance's Service: no collector target has been
# scraped for 10 minutes (`OtelCollectorDown`, critical). One pod of several
# down, such as the agent on one node, is left to the generic `TargetDown`
# and the node alerts.
#
# Escape hatches: `settings` (the collector's configuration; the locked
# paths are listed in its description), `extraArgs`, `env`, and the
# instance's `partsOverlays`.
#
# Limits: the receivers serve plaintext; TLS on them needs a certificate
# mounted through `partsOverlays` and `settings`. Metrics and logs from the
# `otlp` receiver have no exporter dependency yet, so pipelines for them go
# in `settings`, and under default deny their egress needs a policy of the
# instance's own. The package renders no RBAC for the components that read
# pods, nodes, or the kubelet (`k8sattributes`, `k8s_cluster`, `k8s_events`,
# `kubeletstats`), and mounts a ServiceAccount token only with
# `events.enabled`, so `settings` refuses them. Running one takes a
# `partsOverlays` entry that replaces the `configMap` part (the refusal lives
# in it) and the `workload` (to mount the token), and adds a ClusterRole and
# binding.
#
# Upgrades: the collector keeps no data. It reads its configuration at
# startup, and the events receiver starts watching from the current
# resourceVersion. 0.165.0 reads the same configuration as 0.161.0, so an
# upgrade needs no step. Going back works the same way: deploy the older
# package. As in any rollout of an events instance, an Event that changes
# while the old and new pod both run may be written twice.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "0.165.0";
  name = scope.instanceName;

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

  deps.otlp.assertions = kix.contracts.experimental.otlpEndpoint.assertions;

  options = {
    image = kix.options.image {
      repository = "docker.io/otel/opentelemetry-collector-contrib";
      tag = release;
      digest = "sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea";
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
        and `exporters."file/events".path`. Setting a locked path fails
        evaluation. A `k8s_objects` receiver needs `events.enabled`, and
        each entry of its `objects` must watch core `events` (the RBAC
        grants nothing else). `k8sattributes`, `k8s_cluster`, `k8s_events`,
        and `kubeletstats` are refused: the package renders no RBAC for
        them. `health_check` is always in `service.extensions`.
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
              zone = 2;
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
            # changed after the collector starts. DELETED arrives for every
            # Event when its TTL (the API server's --event-ttl) expires.
            k8s_objects.objects = [
              {
                name = "events";
                mode = "watch";
                exclude_watch_type = [ "DELETED" ];
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
          inherit scope;
          option = "settings";
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
          ];
        } builtinSettings config.settings;

        # A component's type is its key up to the first `/`.
        ofType =
          type: section:
          let
            components = merged.${section} or { };
          in
          if builtins.isAttrs components then
            builtins.filter (key: key == type || lib.hasPrefix "${type}/" key) (builtins.attrNames components)
          else
            [ ];

        # Components that read pods, nodes, or the kubelet. The package
        # renders no RBAC for them and mounts a token only for events.
        unsupported =
          builtins.concatMap ({ section, type }: map (key: "${section}.${key}") (ofType type section))
            [
              {
                section = "processors";
                type = "k8sattributes";
              }
              {
                section = "receivers";
                type = "k8s_cluster";
              }
              {
                section = "receivers";
                type = "k8s_events";
              }
              {
                section = "receivers";
                type = "kubeletstats";
              }
            ];

        # The ClusterRole grants core/v1 events only, so every object a
        # k8s_objects receiver lists must be that resource.
        watchesEvents = o: builtins.isAttrs o && (o.name or null) == "events" && (o.group or "") == "";
        objectsReceivers = ofType "k8s_objects" "receivers";
        badObjects = builtins.filter (
          key:
          let
            objects = merged.receivers.${key}.objects or null;
          in
          !(builtins.isList objects && objects != [ ] && builtins.all watchesEvents objects)
        ) objectsReceivers;

        refusals =
          lib.optional (unsupported != [ ])
            "settings sets ${lib.concatStringsSep ", " unsupported}, which needs a ServiceAccount token and RBAC this package does not render. Remove it, or replace the configMap and workload parts and add a ClusterRole through partsOverlays."
          ++
            lib.optional (objectsReceivers != [ ] && !events)
              "settings sets receivers.${builtins.head objectsReceivers}, which needs events.enabled = true (the ServiceAccount token and the events RBAC)."
          ++
            lib.optional (events && badObjects != [ ])
              "receivers.${builtins.head badObjects}.objects must be a non-empty list whose entries all have name = \"events\" and no group other than \"\" (core/v1 Events), the only resource the package's ClusterRole grants.";

        # The configMap part throws, so a partsOverlays entry that replaces
        # it also clears the refusal.
        checkedConfig =
          if refusals == [ ] then
            collectorConfig
          else
            scope.fail {
              message = "${lib.concatStringsSep " " refusals}";
            };

        # The collector opens the otlp receiver only when a pipeline lists it.
        otlpServed = builtins.any (p: builtins.elem "otlp" (p.receivers or [ ])) (
          builtins.attrValues pipelines
        );
        notServed = scope.fail {
          message = "no pipeline lists the otlp receiver, so nothing answers on its OTLP addresses.";
          fix = "Add a pipeline that receives from otlp (deps.otlp adds one), or send to another endpoint.";
        };

        userExtensions = merged.service.extensions or [ ];
        collectorConfig =
          if builtins.isList userExtensions then
            lib.recursiveUpdate merged {
              service.extensions = lib.unique ([ "health_check" ] ++ userExtensions);
            }
          else
            scope.fail {
              option = "settings.service.extensions";
              message = "settings.service.extensions must be a list of extension names; got ${builtins.typeOf userExtensions}.";
            };

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
              # The collector parses flags with cobra and pflag
              # (otelcol/command.go upstream).
              args = kix.mergeArgs {
                inherit scope;
                parser = "gnu";
                args = [
                  {
                    flags = [ "--config=${configDir}/${configFile}" ];
                    reason = "this package renders the collector configuration from the settings option.";
                    fix = "Configure the collector in settings instead.";
                  }
                  {
                    names = [ "--set" ];
                    reason = "--set overrides configuration fields at startup, bypassing this package's checks on settings.";
                    fix = "Configure the collector in settings instead.";
                  }
                ];
              } config.extraArgs;
              env = kix.mkEnvVars (kix.mergeEnv { inherit scope; } config.env);
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
              metadata.annotations."checksum/config" = self.configMap.out.contentHash;
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
        scope.fail {
          option = "settings.service.pipelines";
          message = "settings.service.pipelines must be an attribute set of pipelines; got ${builtins.typeOf pipelines}.";
        }
      else if pipelines == { } then
        scope.fail {
          message = "the collector has no pipeline and would refuse to start.";
          fix = "Wire an OTLP endpoint with deps.otlp, set events.enabled, or define service.pipelines in settings.";
        }
      else
        {
          configMap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-config";
            data.${configFile} = builtins.toJSON checkedConfig;
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
            # Without the receiver the addresses throw when a consumer reads
            # them; `check` would force them here.
            out =
              if otlpServed then
                kix.contracts.experimental.otlpEndpoint.check scope {
                  otlpGrpcUrl = self.service.out.url { port = grpcPort; };
                  otlpHttpUrl = self.service.out.url { port = httpPort; };
                  tls = false;
                }
                // {
                  version = kix.image.version config.image;
                }
              else
                {
                  otlpGrpcUrl = notServed;
                  otlpHttpUrl = notServed;
                  tls = false;
                  version = kix.image.version config.image;
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
            expr = "sum by (namespace, service) (up{${scoped}}) == 0 or absent(up{${scoped}})";
            "for" = "10m";
            severity = "critical";
            summary = "An OpenTelemetry Collector is down.";
            description = "Prometheus has scraped no collector of {{ $labels.namespace }}/{{ $labels.service }} for 10 minutes; telemetry sent to it is lost. Check the instance's pods.";
          };
        };
    })
  ];
}
