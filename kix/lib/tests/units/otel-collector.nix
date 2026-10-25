# Tests for kix/packages/otel-collector: the pipelines each dependency and
# toggle adds, the refusal of a configuration without a pipeline, events in
# daemonset mode, the events receiver's objects, the locked settings paths,
# the refused Kubernetes components, and owned flags, the OTLP addresses in
# `out`, the daemonset Service, replicas under events, and the metrics
# toggle. The collector runs
# in namespace `otel` with an OTLP endpoint stub answering `otlp`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  ...
}:

let
  otelPackage = import ../../../packages/otel-collector;

  # An OTLP endpoint provider in the contract's shape. `tls` is published
  # only when it is not "absent".
  tracesPackage =
    tls:
    { ... }:
    {
      meta = {
        version = "test";
        description = "OTLP endpoint stub";
        owner = "test";
        defaultAliases = [ "otlp" ];
      };
      build =
        { self, scope, ... }:
        {
          marker = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "backend";
          };
          root = {
            resource = self.marker;
            out = {
              otlpGrpcUrl = "http://backend.otel.svc:4317";
              otlpHttpUrl = "http://backend.otel.svc:4318";
            }
            // lib.optionalAttrs (tls != "absent") { inherit tls; };
          };
        };
    };

  clusterWith =
    {
      config ? { },
      traces ? null,
      prometheus ? false,
      availability ? null,
    }:
    mkCluster [
      {
        instances.otel = {
          collector = {
            package = otelPackage;
            inherit config;
          }
          // lib.optionalAttrs (availability != null) { inherit availability; };
        }
        // lib.optionalAttrs (traces != null) {
          backend.package = tracesPackage traces;
        };
      }
      (lib.optionalAttrs prometheus {
        instances.monitoring.prometheus.package = prometheusStub;
      })
      (lib.optionalAttrs (availability != null) {
        cluster.capabilities.multiNode = true;
      })
    ];

  events.config.events.enabled = true;

  configOf =
    cluster:
    builtins.fromJSON
      (byName "collector-config" (ofKind "ConfigMap" (manifests cluster))).data."config.yaml";
  workloadOf = kind: cluster: byName "collector" (ofKind kind (manifests cluster));
  containerOf =
    cluster: builtins.head (workloadOf "Deployment" cluster).spec.template.spec.containers;
  serviceOf = cluster: byName "collector" (ofKind "Service" (manifests cluster));
  servicePortsOf = cluster: map (p: p.name) (serviceOf cluster).spec.ports;

  # The package's own assertions, called directly to read their messages.
  assertionMessages =
    config:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (otelPackage {
          scope = {
            instanceName = "collector";
            namespaceName = "otel";
          };
          inherit lib;
          kix = { };
          availability = "none";
        }).assertions
          { inherit config; }
      )
    );
in
{
  # With events on, the Deployment runs one pod, the ClusterRole grants
  # events only, and the logs/events pipeline writes to stdout. This is the
  # positive control for the refusals below.
  otel-collector-events =
    let
      c = clusterWith events;
      cfg = configOf c;
      role = byName "otel.collector" (ofKind "ClusterRole" (manifests c));
    in
    (
      (workloadOf "Deployment" c).spec.replicas == 1
      && cfg.service.pipelines."logs/events".receivers == [ "k8s_objects" ]
      && cfg.exporters."file/events".path == "/dev/stdout"
      &&
        cfg.receivers.k8s_objects.objects == [
          {
            name = "events";
            mode = "watch";
            exclude_watch_type = [ "DELETED" ];
          }
        ]
      && map (r: r.resources) role.rules == [ [ "events" ] ]
      && !((workloadOf "Deployment" c).spec.template.spec ? automountServiceAccountToken)
    )
    || throw "otel-collector events: config ${builtins.toJSON cfg}";

  # Without a dependency, events, or a pipeline in settings, the collector
  # would refuse to start.
  otel-collector-no-pipeline-refused =
    evalFails (clusterWith { })
    && !(evalFails (clusterWith {
      config.settings = {
        exporters.debug = { };
        service.pipelines.traces = {
          receivers = [ "otlp" ];
          exporters = [ "debug" ];
        };
      };
    }));

  # Events in daemonset mode are refused with a message naming the mode.
  otel-collector-events-daemonset-refused =
    let
      messages = assertionMessages {
        mode = "daemonset";
        events.enabled = true;
      };
    in
    (
      evalFails (clusterWith {
        config = {
          mode = "daemonset";
          events.enabled = true;
        };
      })
      && builtins.length messages == 1
      && lib.hasInfix "mode = \"deployment\"" (builtins.head messages)
      &&
        assertionMessages {
          mode = "deployment";
          events.enabled = true;
        } == [ ]
    )
    || throw "otel-collector events in daemonset mode: ${builtins.toJSON messages}";

  # The otlp dependency adds the exporter and the traces pipeline. A
  # plaintext endpoint sets tls.insecure; out.tls = true leaves TLS on.
  otel-collector-traces =
    let
      plain = configOf (clusterWith {
        traces = false;
      });
      absent = configOf (clusterWith {
        traces = "absent";
      });
      secure = configOf (clusterWith {
        traces = true;
      });
    in
    (
      plain.exporters."otlp_grpc/traces".endpoint == "http://backend.otel.svc:4317"
      && plain.exporters."otlp_grpc/traces".tls.insecure
      && absent.exporters."otlp_grpc/traces".tls.insecure
      && !secure.exporters."otlp_grpc/traces".tls.insecure
      &&
        plain.service.pipelines.traces == {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "batch"
          ];
          exporters = [ "otlp_grpc/traces" ];
        }
      && !(plain.service.pipelines ? "logs/events")
    )
    || throw "otel-collector traces: ${builtins.toJSON plain}";

  # out publishes the Service's OTLP addresses while a pipeline lists the
  # otlp receiver. With only events, reading them fails, and so does an
  # agent that forwards to that instance; the same agent forwarding to a
  # gateway with a traces pipeline evaluates.
  otel-collector-out =
    let
      out = (clusterWith (events // { traces = false; })).instances.otel.collector.out;
      eventsOnly = (clusterWith events).instances.otel.collector.out;
      # The gateway binds the backend through the otlp alias when one is
      # present; the agent names the gateway.
      withAgent =
        backend:
        mkCluster [
          (
            { ref, ... }:
            {
              instances.otel = {
                gateway = {
                  package = otelPackage;
                  config = events.config;
                };
                agent = {
                  package = otelPackage;
                  config.mode = "daemonset";
                  deps.otlp = ref.otel.gateway;
                };
              }
              // lib.optionalAttrs backend { backend.package = tracesPackage false; };
            }
          )
        ];
    in
    (
      lib.hasPrefix "http://collector.otel.svc." out.otlpGrpcUrl
      && lib.hasSuffix ":4317" out.otlpGrpcUrl
      && lib.hasSuffix ":4318" out.otlpHttpUrl
      && out.tls == false
      && !(builtins.tryEval eventsOnly.otlpGrpcUrl).success
      && !(builtins.tryEval eventsOnly.otlpHttpUrl).success
      && eventsOnly.tls == false
      && !(evalFails (withAgent true))
      && evalFails (withAgent false)
    )
    || throw "otel-collector out: ${builtins.toJSON out}";

  # Each locked settings path is refused; other keys merge, and
  # health_check stays in service.extensions when settings replaces the
  # list. receivers.k8s_objects needs events.enabled.
  otel-collector-locked-settings =
    let
      withSettings =
        settings:
        clusterWith {
          traces = false;
          config = events.config // {
            inherit settings;
          };
        };
      accepted = builtins.filter (s: !(evalFails (withSettings s))) [
        { extensions.health_check.endpoint = "0.0.0.0:1"; }
        { receivers.otlp.protocols.grpc.endpoint = "0.0.0.0:1"; }
        { receivers.otlp.protocols.http.endpoint = "0.0.0.0:1"; }
        { service.telemetry.metrics.readers = [ ]; }
        { exporters."otlp_grpc/traces".endpoint = "elsewhere:4317"; }
        { exporters."file/events".path = "/tmp/events"; }
        { exporters = null; }
      ];
      merged = configOf (withSettings {
        processors.batch.timeout = "5s";
        extensions.pprof = { };
        service.extensions = [ "pprof" ];
      });
    in
    (
      accepted == [ ]
      && merged.processors.batch.timeout == "5s"
      &&
        merged.service.extensions == [
          "health_check"
          "pprof"
        ]
      && evalFails (clusterWith {
        traces = false;
        config.settings.receivers.k8s_objects.auth_type = "serviceAccount";
      })
    )
    || throw "otel-collector settings accepted locked paths: ${builtins.toJSON accepted}";

  # settings may replace the events receiver's objects to narrow the watch,
  # as long as every entry is core/v1 events; any other resource, group, or
  # an empty list is refused, as is a second k8s_objects receiver without
  # events.enabled.
  otel-collector-events-objects =
    let
      withObjects =
        objects:
        clusterWith {
          config = events.config // {
            settings.receivers.k8s_objects = { inherit objects; };
          };
        };
      narrowed = [
        {
          name = "events";
          mode = "watch";
          field_selector = "type=Warning";
          namespaces = [ "apps" ];
        }
      ];
    in
    (
      (configOf (withObjects narrowed)).receivers.k8s_objects.objects == narrowed
      && evalFails (withObjects [ { name = "pods"; } ])
      && evalFails (withObjects [
        {
          name = "events";
          group = "events.k8s.io";
        }
      ])
      && evalFails (withObjects [ ])
      && evalFails (clusterWith {
        traces = false;
        config.settings.receivers."k8s_objects/pods".objects = [ { name = "events"; } ];
      })
    )
    || throw "otel-collector events objects: ${builtins.toJSON (configOf (withObjects narrowed)).receivers}";

  # Components that need a token and RBAC the package does not render are
  # refused, under any key suffix and with events on. A partsOverlays entry
  # that replaces the configMap part clears the refusal, as the message says.
  otel-collector-k8s-components-refused =
    let
      withSettings =
        settings:
        clusterWith {
          traces = false;
          config = { inherit settings; };
        };
      accepted = builtins.filter (s: !(evalFails (withSettings s))) [
        { processors.k8sattributes = { }; }
        { processors."k8sattributes/pods" = { }; }
        { receivers.k8s_cluster = { }; }
        { receivers.k8s_events = { }; }
        { receivers.kubeletstats = { }; }
      ];
      overlaid = mkCluster [
        {
          instances.otel = {
            backend.package = tracesPackage false;
            collector = {
              package = otelPackage;
              config.settings.processors.k8sattributes = { };
              partsOverlays = [
                (scope: _self: _base: {
                  configMap = scope.mkResource {
                    apiVersion = "v1";
                    kind = "ConfigMap";
                    name = "collector-config";
                    data."config.yaml" = "{}";
                  };
                })
              ];
            };
          };
        }
      ];
    in
    (
      accepted == [ ]
      && evalFails (clusterWith {
        traces = false;
        config = events.config // {
          settings.processors.k8sattributes = { };
        };
      })
      && !(evalFails overlaid)
    )
    || throw "otel-collector k8s components accepted: ${builtins.toJSON accepted}";

  # --config and --set are refused; other flags follow --config.
  otel-collector-owned-args-refused =
    let
      accepted =
        builtins.filter
          (
            arg:
            !(evalFails (
              clusterWith (
                events
                // {
                  config = events.config // {
                    extraArgs = [ arg ];
                  };
                }
              )
            ))
          )
          [
            "--config=/tmp/x.yaml"
            "--config"
            "--set=processors.batch.timeout=1s"
          ];
      args =
        (containerOf (clusterWith {
          config = events.config // {
            extraArgs = [ "--feature-gates=+extension.healthcheck.useComponentStatus" ];
          };
        })).args;
    in
    (
      accepted == [ ]
      &&
        args == [
          "--config=/etc/otelcol-contrib/config.yaml"
          "--feature-gates=+extension.healthcheck.useComponentStatus"
        ]
    )
    || throw "otel-collector extraArgs: accepted ${builtins.toJSON accepted}, args ${builtins.toJSON args}";

  # Daemonset mode renders a DaemonSet and a node-local Service.
  otel-collector-daemonset =
    let
      c = clusterWith {
        traces = false;
        config.mode = "daemonset";
      };
    in
    (
      workloadOf "DaemonSet" c != null
      && workloadOf "Deployment" c == null
      && (serviceOf c).spec.internalTrafficPolicy == "Local"
      && (workloadOf "DaemonSet" c).spec.template.spec.automountServiceAccountToken == false
    )
    || throw "otel-collector daemonset: ${builtins.toJSON (serviceOf c)}";

  # Replicas follow the availability level, except with events on, where
  # the Deployment runs one pod at any level.
  otel-collector-replicas =
    let
      gateway = clusterWith {
        traces = false;
        availability = "node";
      };
      watcher = clusterWith {
        traces = false;
        availability = "node";
        config.events.enabled = true;
      };
    in
    (
      (workloadOf "Deployment" gateway).spec.replicas == 2
      && (workloadOf "Deployment" watcher).spec.replicas == 1
    )
    || throw "otel-collector replicas: ${toString (workloadOf "Deployment" gateway).spec.replicas}";

  # A prometheus dependency adds the Service port and the ServiceMonitor
  # and leaves the pod template unchanged; metrics.enabled = false turns the
  # collector's own metrics off.
  otel-collector-metrics =
    let
      plain = clusterWith events;
      scraped = clusterWith (events // { prometheus = true; });
      off = clusterWith {
        prometheus = true;
        config = events.config // {
          metrics.enabled = false;
        };
      };
    in
    (
      servicePortsOf plain == [
        "otlp-grpc"
        "otlp-http"
      ]
      &&
        servicePortsOf scraped == [
          "otlp-grpc"
          "otlp-http"
          "metrics"
        ]
      && ofKind "ServiceMonitor" (manifests scraped) != [ ]
      && (workloadOf "Deployment" plain).spec.template == (workloadOf "Deployment" scraped).spec.template
      && (configOf off).service.telemetry.metrics == { level = "none"; }
      &&
        servicePortsOf off == [
          "otlp-grpc"
          "otlp-http"
        ]
      && ofKind "ServiceMonitor" (manifests off) == [ ]
    )
    || throw "otel-collector metrics: plain ${builtins.toJSON (servicePortsOf plain)} scraped ${builtins.toJSON (servicePortsOf scraped)}";
}
