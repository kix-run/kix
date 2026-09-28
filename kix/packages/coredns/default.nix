# CoreDNS kix package.
#
# Produces: ConfigMap, Deployment, Service (kube-dns), ServiceAccount,
# ClusterRole, ClusterRoleBinding, and optionally HPA, metrics Service,
# and ServiceMonitor. The PodDisruptionBudget is derived by the compiler
# from the availability level, not written here.
#
# Dependencies:
#   prometheus: optional, gates ServiceMonitor creation and provides CRD ref
#
# root = Service (kube-dns), selecting the Deployment via .out.selector.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  helpers = import ./helpers.nix { inherit lib; };

  # Selector labels: used for Deployment matchLabels and template labels.
  # Other resources derive selectors via .out.selector.
  selectorLabels = {
    "k8s-app" = "coredns";
    "app.kubernetes.io/name" = "coredns";
  };

  # RBAC DSL
  inherit (scope.rbac) grant allow core;
  discovery = scope.rbac.group "discovery.k8s.io" [ "endpointslices" ];

in
{
  meta = {
    version = "1.13.1";
    description = "CoreDNS as the cluster DNS server behind the kube-dns Service, with a Corefile built from structured server blocks";
    owner = "platform";
  };

  options = {
    image = kix.options.image {
      repository = "coredns/coredns";
      tag = "1.13.1";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # A serving data plane: two replicas once a pod restart must not stop
      # cluster DNS, three once a whole zone may go.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      description = ''
        Number of CoreDNS `Deployment` replicas. Defaults from the
        cluster's availability level (v2_discussions/145).
      '';
    };
    isClusterService = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    serviceType = lib.mkOption {
      type = lib.types.str;
      default = "ClusterIP";
    };
    clusterIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Explicit ClusterIP for the kube-dns service";
    };
    serviceAccount = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        create = true;
        name = null;
      };
    };
    servers = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ helpers.defaultServer ];
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
      };
    };
    rollingUpdate = lib.mkOption {
      type = lib.types.anything;
      default = {
        maxSurge = "25%";
        maxUnavailable = 1;
      };
    };
    affinity = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    };
    enableTcpPort = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    hpa = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        # The floor follows replicaCount's mapping of the availability
        # level (v2_discussions/145), so the autoscaler never undoes it.
        minReplicas = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 3;
        };
        maxReplicas = 5;
        metrics = [ ];
      };
    };
    prometheus = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        service = {
          enabled = false;
          annotations = { };
        };
        monitor = {
          enabled = false;
          interval = null;
        };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      prometheus ? null,
    }:
    let
      # Common labels applied to all resources.
      commonLabels =
        selectorLabels
        // lib.optionalAttrs config.isClusterService {
          "kubernetes.io/cluster-service" = "true";
          "kubernetes.io/name" = "CoreDNS";
        };

      # Build the Corefile string from server config.
      corefile = helpers.mkCorefile config.servers;

      saName =
        if config.serviceAccount.name != null then config.serviceAccount.name else scope.instanceName;

      # ServiceMonitor builder from prometheus DI dep
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;

    in
    {

      # --- ServiceAccount ---
      serviceAccount =
        if config.serviceAccount.create then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = saName;
            labels = commonLabels;
          }
        else
          null;

      # --- ConfigMap (Corefile) ---
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${scope.instanceName}";
        labels = {
          "app.kubernetes.io/name" = "coredns";
        };
        data = {
          Corefile = corefile;
        };
      };

    }
    // scope.rbac.mkClusterRoleSet scope {
      subjects = [
        {
          kind = "ServiceAccount";
          # Tracked when we build the SA; the bare name when the cluster
          # supplies an existing one (config.serviceAccount.create = false).
          name = if config.serviceAccount.create then self.serviceAccount.out.name else saName;
          namespace = scope.namespaceName;
        }
      ];
      labels = commonLabels;
      roles = {
        "${scope.instanceName}" = grant [
          (
            [
              core.endpoints
              core.services
              core.pods
              core.namespaces
              discovery.endpointslices
            ]
            |> allow [
              "list"
              "watch"
            ]
          )
        ];
      };
    }
    // {

      # --- Deployment ---
      deployment = scope.mkDeployment {
        name = "${scope.instanceName}";
        labels = commonLabels // {
          "app.kubernetes.io/version" = config.image.tag;
        };
        spec = {
          replicas = config.replicaCount;
          strategy = {
            type = "RollingUpdate";
            rollingUpdate = {
              inherit (config.rollingUpdate) maxUnavailable maxSurge;
            };
          };
          selector.matchLabels = selectorLabels // {
            "app.kubernetes.io/instance" = scope.instanceName;
          };
          template = {
            metadata = {
              labels = selectorLabels // {
                "app.kubernetes.io/instance" = scope.instanceName;
              };
            };
            spec = {
              terminationGracePeriodSeconds = 30;
              dnsPolicy = "Default";
              # Cluster DNS must keep running on nodes tainted for add-ons
              # only. This replaces the pre-1.6 alpha tolerations annotation,
              # which current kubelets ignore.
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
              ];
            }
            // (
              if config.serviceAccount.create then
                { serviceAccount = self.serviceAccount; }
              else
                # An existing ServiceAccount this package does not build.
                { serviceAccountName = kix.untrackedRef saName; }
            )
            // lib.optionalAttrs (config.affinity != null) {
              inherit (config) affinity;
            }
            // {
              containers = [
                {
                  name = "coredns";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "-conf"
                    "/etc/coredns/Corefile"
                  ];
                  volumeMounts = [
                    {
                      name = "config-volume";
                      mountPath = "/etc/coredns";
                    }
                  ];
                  inherit (config) resources;
                  ports = [
                    {
                      containerPort = 53;
                      name = "udp-53";
                      protocol = "UDP";
                    }
                  ]
                  ++ lib.optional config.enableTcpPort {
                    containerPort = 53;
                    name = "tcp-53";
                    protocol = "TCP";
                  }
                  ++ [
                    {
                      containerPort = 9153;
                      name = "tcp-9153";
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/health";
                      port = 8080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 60;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    successThreshold = 1;
                    failureThreshold = 5;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/ready";
                      port = 8181;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 30;
                    periodSeconds = 5;
                    timeoutSeconds = 5;
                    successThreshold = 1;
                    failureThreshold = 1;
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    # The image runs as its own non-root user.
                    runAsNonRoot = true;
                    capabilities = {
                      add = [ "NET_BIND_SERVICE" ];
                      drop = [ "ALL" ];
                    };
                    readOnlyRootFilesystem = true;
                  };
                }
              ];
              volumes = [
                {
                  name = "config-volume";
                  configMap = {
                    name = self.configmap.out.name;
                    defaultMode = 420;
                    items = [
                      {
                        key = "Corefile";
                        path = "Corefile";
                      }
                    ];
                  };
                }
              ];
            };
          };
        };
      };

      # --- Service (kube-dns) ---
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${scope.instanceName}";
        # A component of its own, so the metrics Service (component=metrics)
        # is not a superset of this one's labels.
        labels = commonLabels // {
          "app.kubernetes.io/component" = "dns";
        };
        spec = {
          selector = self.deployment.out.selector;
          ports = [
            {
              name = "udp-53";
              port = 53;
              protocol = "UDP";
              targetPort = 53;
            }
          ]
          ++ lib.optional config.enableTcpPort {
            name = "tcp-53";
            port = 53;
            protocol = "TCP";
            targetPort = 53;
          };
          type = config.serviceType;
        }
        // lib.optionalAttrs (config.clusterIP != null) {
          clusterIP = config.clusterIP;
        };
        requires =
          lib.optional (self.metricsService != null) self.metricsService
          ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor
          ++ lib.optional (self.prometheusRules != null) self.prometheusRules
          ++ lib.optional (self.hpa != null) self.hpa;
      };

      # --- Optional: Metrics Service ---
      metricsService =
        if config.prometheus.service.enabled or false then
          scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "${scope.instanceName}-metrics";
            labels = commonLabels // {
              "app.kubernetes.io/component" = "metrics";
            };
            annotations = config.prometheus.service.annotations or { };
            spec = {
              selector = self.deployment.out.selector;
              ports = [
                {
                  name = "metrics";
                  port = 9153;
                  protocol = "TCP";
                  targetPort = 9153;
                }
              ];
              type = "ClusterIP";
            };
          }
        else
          null;

      # --- Optional: ServiceMonitor ---
      serviceMonitor =
        if (config.prometheus.monitor.enabled or false) && prometheus != null then
          mkServiceMonitor {
            name = "${scope.instanceName}";
            labels = commonLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = self.metricsService.out.selector;
              endpoints = [
                (
                  {
                    port = "metrics";
                  }
                  // lib.optionalAttrs (config.prometheus.monitor.interval != null) {
                    interval = config.prometheus.monitor.interval;
                  }
                )
              ];
            };
          }
        else
          null;

      # --- Optional: PrometheusRule (DNS alerts) ---
      prometheusRules =
        if prometheus != null then
          prometheus.out.mkPrometheusRule scope {
            name = "${scope.instanceName}-dns-alerts";
            labels = commonLabels;
            spec = {
              groups = [
                {
                  name = "node-dns-rules";
                  rules = [
                    {
                      alert = "NodeDNSDown";
                      expr = ''min by (node) (up{job="dns-exporter"}) == 0'';
                      "for" = "5m";
                      labels.severity = "critical";
                      annotations = {
                        summary = "Node CoreDNS service is down";
                        description = "Node CoreDNS service on {{ $labels.node }} has been down for 5 minutes.";
                      };
                    }
                    {
                      alert = "NodeDNSQueryTimeHigh";
                      expr = "avg_over_time(dnsexp_dns_query_time_seconds[5m]) > 100";
                      "for" = "5m";
                      labels.severity = "warning";
                      annotations = {
                        summary = "Node CoreDNS query time is high";
                        description = "Node CoreDNS query time on {{ $labels.node }} has been high for 5 minutes.";
                      };
                    }
                  ];
                }
              ];
            };
          }
        else
          null;

      # --- Optional: HPA ---
      hpa =
        if config.hpa.enabled then
          scope.mkResource {
            apiVersion = "autoscaling/v2";
            kind = "HorizontalPodAutoscaler";
            name = "${scope.instanceName}";
            labels = commonLabels;
            spec = {
              scaleTargetRef = {
                apiVersion = "apps/v1";
                kind = "Deployment";
                name = self.deployment.out.name;
              };
              minReplicas = config.hpa.minReplicas;
              maxReplicas = config.hpa.maxReplicas;
              metrics = config.hpa.metrics;
            };
          }
        else
          null;

      # --- Entry point ---
      # root is the Service. The Deployment is tracked via .out.selector,
      # ConfigMap and ServiceAccount via .out.name.
      # RBAC is pulled in via inverse dependency detection.
      root = self.service;
    };
}
