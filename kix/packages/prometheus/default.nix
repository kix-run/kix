# prometheus: Prometheus server managed by the Prometheus Operator.
#
# Creates a Prometheus CR that the operator reconciles into a StatefulSet.
# Configurable retention, storage, resources, and scrape settings.
#
# DI deps:
#   prometheus-operator (required): provides the Prometheus CRD
#
# Exposes:
#   out.serviceUrl: "http://prometheus-operated.<ns>.svc:9090" (the operator's Service)
#     for Grafana and other consumers

{
  scope,
  lib,
  kix,
  availability,
}:
let
  name = scope.instanceName;
  ns = scope.namespaceName;

in
{
  meta = {
    version = "v3.13.1";
    description = "Prometheus time-series database";
    owner = "platform";
    defaultAliases = [
      "prometheusServer"
      "promServer"
    ];
    k8s.minVersion = "1.25";
    # Historical metrics are expendable; a fresh start is acceptable on
    # storage backend swaps. See v2_discussions/67_stateful_migration_orchestration.md.
    lifecycle = "ephemeral";
  };

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/prometheus";
      tag = "v3.13.1";
      pullPolicy = null;
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      # The operator's HA pair: from "node" up two replicas scrape and
      # store everything twice, so losing one leaves no gap.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of Prometheus replicas the operator stamps out. Defaults
        from the cluster's availability level (v2_discussions/145).
      '';
    };
    retention = lib.mkOption {
      type = lib.types.str;
      default = "7d";
    };
    retentionSize = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    scrapeInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    evaluationInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "2Gi";
      };
      limits = {
        cpu = "2";
        memory = "4Gi";
      };
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = null;
      description = "VolumeClaimTemplate spec for persistent storage. null = emptyDir.";
    };
    externalUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    # Selector scoping: by default, select all ServiceMonitors/PodMonitors/Rules
    # across all namespaces (matching the Helm chart's default behavior)
    serviceMonitorSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    podMonitorSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    ruleSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    serviceMonitorNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    podMonitorNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    ruleNamespaceSelector = lib.mkOption {
      type = lib.types.anything;
      default = { };
    };
    alerting = lib.mkOption {
      type = lib.types.anything;
      default = null;
      description = "Alertmanager endpoints config. Set by cluster module.";
    };
    priorityClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra fields deep-merged into the Prometheus CR spec. Escape hatch
        for fields not exposed as typed options (remoteWrite, thanos sidecar
        spec, etc.). The package's pod `securityContext` runs Prometheus as
        user 1000 and group 2000 with `fsGroup = 2000`; set
        `extraSpec.securityContext` to change it.
      '';
    };

    # ── Additional scrape / alertmanager / alert-relabel configs ──────────
    # Mirror chart's two-mode pattern: provide content inline (kix creates a
    # Secret and wires the CR), or point at an existing external Secret. The
    # chart's `*Secret` blocks are mutually exclusive with their inline
    # counterparts; same here. Empty list / null means "not set".
    additionalScrapeConfigs = lib.mkOption {
      type = lib.types.either (lib.types.listOf lib.types.anything) lib.types.str;
      default = [ ];
      description = ''
        Inline additional scrape configs. Accepts a list of scrape_config
        entries (recommended) or a raw YAML string. When non-empty, kix
        creates a Secret named `<instance>-prometheus-scrape-confg` keyed
        `additional-scrape-configs.yaml` and wires the Prometheus CR's
        `additionalScrapeConfigs` to it.
      '';
    };
    additionalScrapeConfigsSecret = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Name of an existing Secret holding the scrape configs.";
          };
          key = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Key inside the Secret holding the YAML body.";
          };
        };
      };
      default = { };
      description = ''
        External-Secret variant of `additionalScrapeConfigs`. Mutually
        exclusive with the inline form. When `enabled = true`, kix wires the
        Prometheus CR to the named Secret without creating one.
      '';
    };
    additionalAlertManagerConfigs = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Inline additional Alertmanager configs (list). When non-empty, kix
        creates a Secret named `<instance>-prometheus-am-confg`.
      '';
    };
    additionalAlertManagerConfigsSecret = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            key = lib.mkOption { type = lib.types.str; };
            optional = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
            };
          };
        }
      );
      default = null;
      description = "External-Secret variant of additionalAlertManagerConfigs.";
    };
    additionalAlertRelabelConfigs = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Inline additional alert-relabel configs (list). When non-empty, kix
        creates a Secret named `<instance>-prometheus-am-relabel-confg`.
      '';
    };
    additionalAlertRelabelConfigsSecret = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            key = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = null;
      description = "External-Secret variant of additionalAlertRelabelConfigs.";
    };
    additionalPrometheusSecretsAnnotations = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Annotations applied to the kix-managed additional* Secrets.";
    };

    # ── Thanos sidecar wiring ─────────────────────────────────────────────
    # Mirrors kube-prometheus-stack's `prometheus.thanos{Service,
    # ServiceExternal, ServiceMonitor, Ingress}` value blocks. The Thanos
    # sidecar itself is configured via `extraSpec.thanos` (matches
    # chart's `prometheus.prometheusSpec.thanos`); this block adds the
    # discovery Service, optional external LB Service, auto-scrape SM, and
    # ingress that downstream Thanos compactor/querier expect.
    thanos = lib.mkOption {
      type = lib.types.submodule {
        options = {
          service = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Emit the in-cluster Thanos sidecar discovery Service.";
                };
                annotations = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                labels = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                type = lib.mkOption {
                  type = lib.types.str;
                  default = "ClusterIP";
                };
                externalTrafficPolicy = lib.mkOption {
                  type = lib.types.str;
                  default = "Cluster";
                };
                clusterIP = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
                portName = lib.mkOption {
                  type = lib.types.str;
                  default = "grpc";
                };
                port = lib.mkOption {
                  type = lib.types.int;
                  default = 10901;
                };
                targetPort = lib.mkOption {
                  type = lib.types.either lib.types.int lib.types.str;
                  default = 10901;
                  description = "The sidecar's gRPC port on the server pods. The operator fixes it at 10901. Network policy egress needs a number: Kix did not build the pods, so it cannot resolve a port name.";
                };
                httpPortName = lib.mkOption {
                  type = lib.types.str;
                  default = "http";
                };
                httpPort = lib.mkOption {
                  type = lib.types.int;
                  default = 10902;
                };
                targetHttpPort = lib.mkOption {
                  type = lib.types.either lib.types.int lib.types.str;
                  default = 10902;
                  description = "The sidecar's HTTP port on the server pods, which the Thanos ServiceMonitor scrapes. The operator fixes it at 10902. Network policy egress needs a number: Kix did not build the pods, so it cannot resolve a port name.";
                };
                nodePort = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                };
                httpNodePort = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                };
              };
            };
            default = { };
          };

          serviceExternal = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Emit a LoadBalancer/NodePort Service for cross-cluster Thanos discovery.";
                };
                annotations = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                labels = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                type = lib.mkOption {
                  type = lib.types.str;
                  default = "LoadBalancer";
                };
                externalTrafficPolicy = lib.mkOption {
                  type = lib.types.str;
                  default = "Cluster";
                };
                loadBalancerIP = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
                loadBalancerSourceRanges = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                portName = lib.mkOption {
                  type = lib.types.str;
                  default = "grpc";
                };
                port = lib.mkOption {
                  type = lib.types.int;
                  default = 10901;
                };
                targetPort = lib.mkOption {
                  type = lib.types.either lib.types.int lib.types.str;
                  default = 10901;
                  description = "The sidecar's gRPC port on the server pods. The operator fixes it at 10901. Network policy egress needs a number: Kix did not build the pods, so it cannot resolve a port name.";
                };
                httpPortName = lib.mkOption {
                  type = lib.types.str;
                  default = "http";
                };
                httpPort = lib.mkOption {
                  type = lib.types.int;
                  default = 10902;
                };
                targetHttpPort = lib.mkOption {
                  type = lib.types.either lib.types.int lib.types.str;
                  default = 10902;
                  description = "The sidecar's HTTP port on the server pods, which the Thanos ServiceMonitor scrapes. The operator fixes it at 10902. Network policy egress needs a number: Kix did not build the pods, so it cannot resolve a port name.";
                };
                nodePort = lib.mkOption {
                  type = lib.types.int;
                  default = 30901;
                };
                httpNodePort = lib.mkOption {
                  type = lib.types.int;
                  default = 30902;
                };
              };
            };
            default = { };
          };

          serviceMonitor = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Auto-scrape the Thanos sidecar via a ServiceMonitor (requires service.enabled).";
                };
                interval = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
                additionalLabels = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                scheme = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
                tlsConfig = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                bearerTokenFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
                metricRelabelings = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                };
                relabelings = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                };
              };
            };
            default = { };
          };

          ingress = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enabled = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                ingressClassName = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                };
                annotations = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                labels = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                };
                servicePort = lib.mkOption {
                  type = lib.types.int;
                  default = 10901;
                };
                hosts = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                pathType = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
                tls = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                };
              };
            };
            default = { };
          };
        };
      };
      default = { };
      description = ''
        Thanos sidecar auxiliary resources. The sidecar container itself is
        configured via `extraSpec.thanos` on the Prometheus CR; this block
        adds the discovery Service, optional external Service, auto-scrape
        ServiceMonitor, and Ingress so downstream Thanos components
        (compactor, querier) can find the sidecar.
      '';
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheusOperator,
      ...
    }:
    let
      mkPrometheus = prometheusOperator.out.mkPrometheus;

      # "<group>/<Kind>/<name>" of a CR, for the operand-of annotation. The name
      # keeps the CR's context, so the Service also depends on the CR.
      operandOf = cr: "${lib.head (lib.splitString "/" cr.apiVersion)}/${cr.kind}/${cr.name}";
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;

      # The server pods the operator creates. It labels them with both
      # keys, and the Thanos sidecar runs in the same pods. The Prometheus
      # CRD's factBehavior podSelector names the same labels.
      serverPodSelector = {
        "app.kubernetes.io/name" = "prometheus";
        "operator.prometheus.io/name" = name;
      };

      # Distinguishing label stamped on the discovery Service so the
      # ServiceMonitor and Ingress can find it via labels alone (kix's
      # `out.selector` for a Service falls back to metadata.labels when
      # `spec.selector` lacks `matchLabels`).
      thanosDiscoveryLabel = {
        ${kix.keys.role} = "thanos-discovery";
      };

      mkServicePorts =
        cfg:
        let
          isNodePort = cfg.type == "NodePort";
        in
        [
          (
            {
              name = cfg.portName;
              port = cfg.port;
              targetPort = cfg.targetPort;
            }
            // lib.optionalAttrs isNodePort { nodePort = cfg.nodePort; }
          )
          (
            {
              name = cfg.httpPortName;
              port = cfg.httpPort;
              targetPort = cfg.targetHttpPort;
            }
            // lib.optionalAttrs isNodePort { nodePort = cfg.httpNodePort; }
          )
        ];

      # ── Additional scrape / alertmanager / alert-relabel configs ─────────
      # Chart names (preserving upstream's "confg" typos for fidelity).
      scrapeConfgsSecretName = "${name}-prometheus-scrape-confg";
      amConfgsSecretName = "${name}-prometheus-am-confg";
      amRelabelConfgsSecretName = "${name}-prometheus-am-relabel-confg";

      # `additionalScrapeConfigs` accepts a list (kix toJSON's it; JSON is
      # valid YAML, which Prometheus' parser accepts) or a raw string.
      isList = builtins.isList config.additionalScrapeConfigs;
      isStr = builtins.isString config.additionalScrapeConfigs;
      scrapeIsSet =
        (isList && config.additionalScrapeConfigs != [ ])
        || (isStr && config.additionalScrapeConfigs != "");
      scrapeBody =
        if isStr then config.additionalScrapeConfigs else builtins.toJSON config.additionalScrapeConfigs;

      amIsSet = config.additionalAlertManagerConfigs != [ ];
      amRelabelIsSet = config.additionalAlertRelabelConfigs != [ ];

      scrapeSecretRef = config.additionalScrapeConfigsSecret;
      amSecretRef = config.additionalAlertManagerConfigsSecret;
      amRelabelSecretRef = config.additionalAlertRelabelConfigsSecret;

      # CR-spec fragment that points at whichever Secret holds the config.
      # Inline mode wins over external when both are set (matches chart's
      # template ordering: inline emits first, external `if` overwrites).
      scrapeRefSpec =
        if scrapeIsSet then
          {
            additionalScrapeConfigs = {
              name = self.scrapeConfigsSecret.out.name;
              key = "additional-scrape-configs.yaml";
            };
          }
        else if scrapeSecretRef.enabled then
          {
            additionalScrapeConfigs = {
              inherit (scrapeSecretRef) name key;
            };
          }
        else
          { };

      amRefSpec =
        if amIsSet then
          {
            additionalAlertManagerConfigs = {
              name = self.alertManagerConfigsSecret.out.name;
              key = "additional-alertmanager-configs.yaml";
            };
          }
        else if amSecretRef != null then
          {
            additionalAlertManagerConfigs = {
              inherit (amSecretRef) name key;
            }
            // lib.optionalAttrs (amSecretRef.optional != null) {
              inherit (amSecretRef) optional;
            };
          }
        else
          { };

      amRelabelRefSpec =
        if amRelabelIsSet then
          {
            additionalAlertRelabelConfigs = {
              name = self.alertRelabelConfigsSecret.out.name;
              key = "additional-alert-relabel-configs.yaml";
            };
          }
        else if amRelabelSecretRef != null then
          {
            additionalAlertRelabelConfigs = {
              inherit (amRelabelSecretRef) name key;
            };
          }
        else
          { };

      storageSpec =
        if config.storage != null then
          {
            volumeClaimTemplate = config.storage;
          }
        else
          null;

      inherit (scope.rbac)
        group
        core
        grant
        watch
        allow
        mkClusterRoleSet
        ;

      # Prometheus needs to scrape targets across all namespaces
      scrapeRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        labels = scope.selectorLabels;
        roles = {
          "${name}" = {
            rules =
              grant [
                (core.nodes |> watch)
                (core "nodes/metrics" |> allow [ "get" ])
                (core.services |> watch)
                (core.endpoints |> watch)
                (core.pods |> watch)
                (core.configmaps |> allow [ "get" ])
                (group "networking.k8s.io" [ "ingresses" ] |> (r: r.ingresses) |> watch)
                (group "discovery.k8s.io" [ "endpointslices" ] |> (r: r.endpointslices) |> watch)
              ]
              ++ [
                # nonResourceURLs for /metrics scraping
                {
                  nonResourceURLs = [
                    "/metrics"
                    "/metrics/cadvisor"
                  ];
                  verbs = [ "get" ];
                }
              ];
          };
        };
      };

    in
    {
      # ServiceAccount for the Prometheus pods
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = true;
      };

      # Prometheus CR: the operator reconciles this into a StatefulSet
      prometheus = mkPrometheus scope {
        name = name;
        spec = lib.recursiveUpdate (
          {
            replicas = config.replicas;
            image = kix.image.ref config.image;
            version = config.image.tag;
            serviceAccountName = self.serviceAccount.out.name;

            retention = config.retention;
            scrapeInterval = config.scrapeInterval;
            evaluationInterval = config.evaluationInterval;
            resources = config.resources;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 1000;
              runAsGroup = 2000;
              fsGroup = 2000;
            };

            # Select all ServiceMonitors/PodMonitors/Rules across all namespaces
            serviceMonitorSelector = config.serviceMonitorSelector;
            podMonitorSelector = config.podMonitorSelector;
            ruleSelector = config.ruleSelector;
            serviceMonitorNamespaceSelector = config.serviceMonitorNamespaceSelector;
            podMonitorNamespaceSelector = config.podMonitorNamespaceSelector;
            ruleNamespaceSelector = config.ruleNamespaceSelector;

            enableAdminAPI = false;
            enableRemoteWriteReceiver = false;
          }
          // lib.optionalAttrs (config.image.pullPolicy != null) {
            imagePullPolicy = config.image.pullPolicy;
          }
          // lib.optionalAttrs (storageSpec != null) { storage = storageSpec; }
          // lib.optionalAttrs (config.externalUrl != null) {
            externalUrl = config.externalUrl;
          }
          // lib.optionalAttrs (config.retentionSize != null) {
            retentionSize = config.retentionSize;
          }
          // lib.optionalAttrs (config.alerting != null) {
            alerting = config.alerting;
          }
          // lib.optionalAttrs (config.priorityClassName != null) {
            priorityClassName = config.priorityClassName;
          }
          // scrapeRefSpec
          // amRefSpec
          // amRelabelRefSpec
        ) config.extraSpec;
      };

      # The operator creates the server pods, so no workload policy is
      # derived for them. Kubernetes service discovery needs the API server
      # (the ServiceAccount's ClusterRoleBinding above); the netpol plugin
      # adds the scrape and Alertmanager egress from the monitors this
      # Prometheus selects.
      serverEgress = kix.operandPolicy {
        inherit scope;
        name = "${name}-server-egress";
        spec = {
          endpointSelector.matchLabels = serverPodSelector;
          egress = [
            scope.networkPolicyEnforcer.netpol.dnsEgressRule
            scope.networkPolicyEnforcer.netpol.apiServerEgressRule
          ];
        };
      };

      # ── Additional scrape / AM / alert-relabel Secrets (inline mode) ─────
      # Chart-equivalent: writes the user-provided list/string to a Secret
      # and references it from the CR. Stored under stringData (server-side
      # base64-encoded by K8s), semantically identical to chart's manual
      # b64enc into `data`.
      scrapeConfigsSecret =
        if scrapeIsSet then
          scope.mkSecret {
            name = scrapeConfgsSecretName;
            annotations = config.additionalPrometheusSecretsAnnotations;
            stringData."additional-scrape-configs.yaml" = scrapeBody;
          }
        else
          null;

      alertManagerConfigsSecret =
        if amIsSet then
          scope.mkSecret {
            name = amConfgsSecretName;
            annotations = config.additionalPrometheusSecretsAnnotations;
            stringData."additional-alertmanager-configs.yaml" =
              builtins.toJSON config.additionalAlertManagerConfigs;
          }
        else
          null;

      alertRelabelConfigsSecret =
        if amRelabelIsSet then
          scope.mkSecret {
            name = amRelabelConfgsSecretName;
            annotations = config.additionalPrometheusSecretsAnnotations;
            stringData."additional-alert-relabel-configs.yaml" =
              builtins.toJSON config.additionalAlertRelabelConfigs;
          }
        else
          null;

      # ── Thanos sidecar discovery Service (in-cluster) ────────────────────
      # Mirrors kube-prometheus-stack/templates/prometheus/serviceThanosSidecar.yaml.
      # ServiceMonitor and Ingress key off `kix.run/role: thanos-discovery`
      # in metadata.labels (chart uses `app: <fullname>-thanos-discovery`).
      thanosService = lib.optionalAttrs config.thanos.service.enabled {
        discovery = scope.mkResource ({
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-thanos-discovery";
          labels = thanosDiscoveryLabel // config.thanos.service.labels;
          # The operator creates no Service for the sidecar, so this one is
          # kix-rendered over operator-created pods. Say so: the
          # cross-resource check accepts a selector that matches no pod
          # template when the Service names the CR that produces the pods.
          annotations = config.thanos.service.annotations // {
            ${kix.keys.operandOf} = operandOf self.prometheus;
          };
          spec = {
            type = config.thanos.service.type;
            ports = mkServicePorts config.thanos.service;
            selector = serverPodSelector;
          }
          // lib.optionalAttrs (config.thanos.service.clusterIP != null) {
            clusterIP = config.thanos.service.clusterIP;
          }
          // lib.optionalAttrs (config.thanos.service.type != "ClusterIP") {
            externalTrafficPolicy = config.thanos.service.externalTrafficPolicy;
          };
        });
      };

      # ── Thanos sidecar external Service (cross-cluster) ──────────────────
      # Mirrors serviceThanosSidecarExternal.yaml. Defaults to LoadBalancer.
      thanosServiceExternal = lib.optionalAttrs config.thanos.serviceExternal.enabled {
        external = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-thanos-external";
          labels = config.thanos.serviceExternal.labels;
          annotations = config.thanos.serviceExternal.annotations // {
            ${kix.keys.operandOf} = operandOf self.prometheus;
          };
          spec = {
            type = config.thanos.serviceExternal.type;
            ports = mkServicePorts config.thanos.serviceExternal;
            selector = serverPodSelector;
          }
          // lib.optionalAttrs (config.thanos.serviceExternal.loadBalancerIP != "") {
            loadBalancerIP = config.thanos.serviceExternal.loadBalancerIP;
          }
          // lib.optionalAttrs (config.thanos.serviceExternal.loadBalancerSourceRanges != [ ]) {
            loadBalancerSourceRanges = config.thanos.serviceExternal.loadBalancerSourceRanges;
          }
          // lib.optionalAttrs (config.thanos.serviceExternal.type != "ClusterIP") {
            externalTrafficPolicy = config.thanos.serviceExternal.externalTrafficPolicy;
          };
        };
      };

      # ── Thanos sidecar ServiceMonitor (auto-scrape) ──────────────────────
      # Mirrors servicemonitorThanosSidecar.yaml. Selects the discovery
      # Service via the role label; consumes httpPortName from service config.
      thanosServiceMonitor =
        lib.optionalAttrs (config.thanos.service.enabled && config.thanos.serviceMonitor.enabled)
          {
            sm = mkSmon {
              name = "${name}-thanos-sidecar";
              labels = config.thanos.serviceMonitor.additionalLabels;
              spec = {
                selector.matchLabels = self.thanosService.discovery.out.selector;
                namespaceSelector.matchNames = [ ns ];
                endpoints = [
                  (
                    {
                      port = config.thanos.service.httpPortName;
                      path = "/metrics";
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.interval != "") {
                      inherit (config.thanos.serviceMonitor) interval;
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.scheme != "") {
                      inherit (config.thanos.serviceMonitor) scheme;
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.tlsConfig != { }) {
                      inherit (config.thanos.serviceMonitor) tlsConfig;
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.bearerTokenFile != null) {
                      inherit (config.thanos.serviceMonitor) bearerTokenFile;
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.metricRelabelings != [ ]) {
                      inherit (config.thanos.serviceMonitor) metricRelabelings;
                    }
                    // lib.optionalAttrs (config.thanos.serviceMonitor.relabelings != [ ]) {
                      inherit (config.thanos.serviceMonitor) relabelings;
                    }
                  )
                ];
              };
            };
          };

      # ── Thanos sidecar Ingress (gRPC gateway) ────────────────────────────
      # Mirrors ingressThanosSidecar.yaml. Backend is the discovery Service.
      thanosIngress = lib.optionalAttrs config.thanos.ingress.enabled (
        let
          icfg = config.thanos.ingress;
          # INFO: chart-faithful: when `pathType` is unset, kube-prometheus-
          # stack emits `pathType: ` (empty string), which the K8s API
          # rejects (Ingress requires Exact|Prefix|ImplementationSpecific).
          # We mirror the upstream bug verbatim per the project's "follow
          # chart logic exactly" rule. Users must set
          # `thanos.ingress.pathType = "Prefix"` (or similar) when enabling
          # the ingress, just as they would in the chart.
          pathType = if icfg.pathType != null then icfg.pathType else "";
          # Chart uses prometheusSpec.routePrefix when paths is empty;
          # extraSpec drives the CR's routePrefix in kix, so default to "/"
          # which matches the operator-honoured default.
          paths = if icfg.paths != [ ] then icfg.paths else [ "/" ];
          mkPaths = map (p: {
            path = p;
            inherit pathType;
            backend.service = {
              name = self.thanosService.discovery.out.name;
              port.number = icfg.servicePort;
            };
          }) paths;
        in
        {
          gateway = scope.mkResource ({
            apiVersion = "networking.k8s.io/v1";
            kind = "Ingress";
            name = "${name}-thanos-gateway";
            labels = icfg.labels;
            annotations = icfg.annotations;
            spec = {
              rules =
                if icfg.hosts != [ ] then
                  map (host: {
                    inherit host;
                    http.paths = mkPaths;
                  }) icfg.hosts
                else
                  [ { http.paths = mkPaths; } ];
            }
            // lib.optionalAttrs (icfg.ingressClassName != "") {
              inherit (icfg) ingressClassName;
            }
            // lib.optionalAttrs (icfg.tls != [ ]) {
              inherit (icfg) tls;
            };
          });
        }
      );

      # The operator creates `prometheus-operated` (headless, port web 9090)
      # selecting the pods it stamps with the labels below. A ServiceRef
      # describes that Service, so out.fqdn carries dependency context, the
      # deploy engine waits for the Service, and netpol derives the same
      # edges as for a rendered Service (v2_discussions/135).
      service = scope.mkServiceRef {
        name = "prometheus-operated";
        selector = {
          "app.kubernetes.io/name" = "prometheus";
          "app.kubernetes.io/instance" = name;
        };
        # The label the operator puts on prometheus-operated.
        labels."operated-prometheus" = "true";
        ports = [
          {
            name = "web";
            port = 9090;
            protocol = "TCP";
          }
        ];
        requires = [ self.prometheus ];
      };

      root = {
        resource = self.service;
        requires = [
          self.serviceAccount
          self.prometheus
        ]
        ++ lib.optional config.thanos.service.enabled self.thanosService.discovery
        ++ lib.optional config.thanos.serviceExternal.enabled self.thanosServiceExternal.external
        ++ lib.optional (
          config.thanos.service.enabled && config.thanos.serviceMonitor.enabled
        ) self.thanosServiceMonitor.sm
        ++ lib.optional config.thanos.ingress.enabled self.thanosIngress.gateway
        ++ lib.optional scrapeIsSet self.scrapeConfigsSecret
        ++ lib.optional amIsSet self.alertManagerConfigsSecret
        ++ lib.optional amRelabelIsSet self.alertRelabelConfigsSecret
        ++ lib.optional (self.serverEgress != null) self.serverEgress;
        out = {
          # Built on the ref's fqdn: the URL carries the marker's context.
          serviceUrl = "http://${self.service.out.fqdn}:9090";
          # The Prometheus CR's image is reconciled by the operator into a
          # StatefulSet, not directly in a kix-generated pod spec.
          extraImages = [
            (kix.image.ref config.image)
          ];
        };
      };
    }
    // scrapeRoles;
}
