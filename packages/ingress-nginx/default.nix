# ingress-nginx kix package.
#
# NGINX Ingress Controller for Kubernetes. Supports multiple instances
# in the same namespace — all resource names are prefixed with
# scope.instanceName to avoid collisions.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Role,
# RoleBinding, ConfigMap (NGINX config), Deployment, Service
# (LoadBalancer/ClusterIP), IngressClass.
#
# main = Service, selecting the Deployment via out.selector.
# IngressClass and ConfigMap pulled in via requires.

{
  scope,
  lib,
}:

let
  # --- RBAC DSL ---
  inherit (scope.rbac)
    group
    core
    grant
    watch
    emit
    allow
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;
  net = group "networking.k8s.io" [
    "ingresses"
    "ingressclasses"
  ];
  disco = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];

in
{
  meta = {
    description = "NGINX Ingress Controller for Kubernetes";
    provides = [
      "ingress"
      "ingress-controller"
    ];
    defaultAliases = [ "ingressNginx" ];
    k8s.minVersion = "1.25";
  };

  options = {
    # Override the resource name prefix. Defaults to the instance name.
    namePrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "registry.k8s.io/ingress-nginx/controller";
        tag = "v1.13.2";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 3;
    };
    serviceType = lib.mkOption {
      type = lib.types.str;
      default = "LoadBalancer";
    };
    externalTrafficPolicy = lib.mkOption {
      type = lib.types.str;
      default = "Cluster";
    };
    clusterIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    ingressClassName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    isDefaultClass = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    controllerValue = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        proxy-body-size = "200M";
        use-forwarded-headers = "true";
        annotations-risk-level = "Critical";
      };
    };
    allowSnippetAnnotations = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    maxmindLicenseKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    enableAntiAffinity = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    antiAffinityTopologyKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "kubernetes.io/hostname"
        "topology.kubernetes.io/zone"
      ];
    };
    # Extra labels added to pod templates (e.g. tenant labels).
    podLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "90Mi";
        };
      };
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      name = if config.namePrefix != null then config.namePrefix else scope.instanceName;

      # Derived values — ingressClassName and controllerValue default to
      # instance-name-based values when not overridden.
      ingressClassName = if config.ingressClassName != null then config.ingressClassName else name;

      controllerValue =
        if config.controllerValue != null then config.controllerValue else "k8s.io/${name}";

      electionId = "${name}-leader";

      selectorLabels = {
        "app.kubernetes.io/name" = "ingress-nginx";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/component" = "controller";
      };

      commonLabels = selectorLabels // {
        "app.kubernetes.io/part-of" = "ingress-nginx";
      };

      # ClusterRole/ClusterRoleBinding don't carry the component label.
      clusterScopedLabels = {
        "app.kubernetes.io/name" = "ingress-nginx";
        "app.kubernetes.io/instance" = name;
        "app.kubernetes.io/part-of" = "ingress-nginx";
      };

      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        labels = clusterScopedLabels;
        roles = {
          "${name}" = grant [
            (
              [
                core.configmaps
                core.endpoints
                core.nodes
                core.pods
                core.secrets
                core.namespaces
                core.services
              ]
              |> watch
            )
            (core.events |> emit)
            (
              [
                net.ingresses
                net.ingressclasses
                disco.endpointslices
              ]
              |> watch
            )
            (net "ingresses/status" |> allow [ "update" ])
            (
              coord.leases
              |> allow [
                "list"
                "watch"
              ]
            )
          ];
        };
      };

      nsRoles = mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        labels = commonLabels;
        roles = {
          "${name}" = grant [
            (core.namespaces |> allow [ "get" ])
            (
              [
                core.configmaps
                core.pods
                core.secrets
                core.endpoints
                core.services
              ]
              |> watch
            )
            (core.events |> emit)
            (
              coord.leases
              |> restrictTo [ electionId ]
              |> allow [
                "get"
                "update"
              ]
            )
            (coord.leases |> allow [ "create" ])
            (
              [
                disco.endpointslices
                net.ingresses
                net.ingressclasses
              ]
              |> watch
            )
            (net "ingresses/status" |> allow [ "update" ])
          ];
        };
      };

    in
    {

      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = name;
        labels = commonLabels;
        extra = {
          automountServiceAccountToken = true;
        };
      };

      # --- ConfigMap (NGINX configuration) ---
      configmap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-controller";
        labels = commonLabels;
        data =
          config.config
          // lib.optionalAttrs config.allowSnippetAnnotations {
            allow-snippet-annotations = "true";
          };
      };

      # --- Deployment ---
      deployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "${name}-controller";
        labels = commonLabels;
        spec = {
          replicas = config.replicaCount;
          revisionHistoryLimit = 10;
          selector.matchLabels = selectorLabels;
          strategy = {
            type = "RollingUpdate";
            rollingUpdate = {
              maxSurge = "25%";
              maxUnavailable = "25%";
            };
          };
          template = {
            metadata = {
              labels = selectorLabels // config.podLabels;
            };
            spec = {
              automountServiceAccountToken = true;
              serviceAccountName = self.serviceAccount.out.name;
              terminationGracePeriodSeconds = 300;
              dnsPolicy = "ClusterFirst";
              containers = [
                {
                  name = "controller";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "/nginx-ingress-controller"
                    "--publish-service=$(POD_NAMESPACE)/${name}-controller"
                    "--election-id=${electionId}"
                    "--controller-class=${controllerValue}"
                    "--ingress-class=${ingressClassName}"
                    "--configmap=$(POD_NAMESPACE)/${self.configmap.out.name}"
                    "--validating-webhook=:8443"
                    "--validating-webhook-certificate=/usr/local/certificates/cert"
                    "--validating-webhook-key=/usr/local/certificates/key"
                  ]
                  ++ lib.optional (
                    config.maxmindLicenseKey != null
                  ) "--maxmind-license-key=${config.maxmindLicenseKey}";
                  env = [
                    {
                      name = "LD_PRELOAD";
                      value = "/usr/local/lib/libmimalloc.so";
                    }
                    {
                      name = "POD_NAME";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.name";
                      };
                    }
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                  ];
                  ports = [
                    {
                      name = "http";
                      containerPort = 80;
                      protocol = "TCP";
                    }
                    {
                      name = "https";
                      containerPort = 443;
                      protocol = "TCP";
                    }
                    {
                      name = "webhook";
                      containerPort = 8443;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 10254;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 1;
                    successThreshold = 1;
                    failureThreshold = 5;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 10254;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 1;
                    successThreshold = 1;
                    failureThreshold = 3;
                  };
                  lifecycle = {
                    preStop.exec.command = [ "/wait-shutdown" ];
                  };
                  resources = config.resources;
                  securityContext = {
                    runAsUser = 101;
                    runAsGroup = 82;
                    runAsNonRoot = true;
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = false;
                    capabilities = {
                      add = [ "NET_BIND_SERVICE" ];
                      drop = [ "ALL" ];
                    };
                    seccompProfile.type = "RuntimeDefault";
                  };
                  volumeMounts = [
                    {
                      name = "webhook-cert";
                      mountPath = "/usr/local/certificates";
                      readOnly = true;
                    }
                  ];
                }
              ];
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
              volumes = [
                {
                  name = "webhook-cert";
                  secret = {
                    secretName = "${name}-admission";
                    defaultMode = 420;
                  };
                }
              ];
            }
            // lib.optionalAttrs config.enableAntiAffinity {
              affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = lib.imap0 (
                i: topologyKey: {
                  weight = 100;
                  podAffinityTerm = {
                    labelSelector.matchExpressions = [
                      {
                        key = "app.kubernetes.io/name";
                        operator = "In";
                        values = [ "ingress-nginx" ];
                      }
                    ];
                    inherit topologyKey;
                  };
                }) config.antiAffinityTopologyKeys;
            };
          };
        };
      };

      # --- Service ---
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${name}-controller";
        labels = commonLabels;
        spec = {
          type = config.serviceType;
          selector = self.deployment.out.selector;
          ports = [
            {
              name = "http";
              port = 80;
              protocol = "TCP";
              targetPort = "http";
              appProtocol = "http";
            }
            {
              name = "https";
              port = 443;
              protocol = "TCP";
              targetPort = "https";
              appProtocol = "https";
            }
          ];
        }
        // lib.optionalAttrs (config.serviceType == "LoadBalancer") {
          externalTrafficPolicy = config.externalTrafficPolicy;
        }
        // lib.optionalAttrs (config.clusterIP != null) {
          clusterIP = config.clusterIP;
        };
        requires = [
          self.ingressClass
          self.configmap
        ];
      };

      # --- IngressClass (cluster-scoped) ---
      ingressClass = scope.mkClusterResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "IngressClass";
        name = ingressClassName;
        labels = commonLabels;
        annotations = lib.optionalAttrs config.isDefaultClass {
          "ingressclass.kubernetes.io/is-default-class" = "true";
        };
        spec = {
          controller = controllerValue;
        };
      };

      # --- Entry point ---
      main = {
        resource = self.service;
        out = {
          ingressClassName = self.ingressClass.out.name;
        };
      };
    }
    // clusterRoles
    // nsRoles;
}
