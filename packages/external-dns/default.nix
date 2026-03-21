# External-DNS kix package.
#
# Manages DNS records in external providers (e.g. Cloudflare) by watching
# Kubernetes Ingress and Service resources.
#
# Supports multi-instance deployment: each instance can manage different
# DNS zones via domainFilters (e.g. external-dns-cluster-public for lithus.net,
# external-dns-northwind for shopfront.example).
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment,
#            Service (metrics), NetworkPolicy, PodDisruptionBudget, Secret.
#
# main = Deployment

{
  scope,
  lib,
}:

{
  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        repository = "docker.io/bitnami/external-dns";
        tag = "0.16.1-debian-12-r1";
        pullPolicy = "IfNotPresent";
      };
    };
    provider = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare";
    };
    sources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "service"
        "ingress"
      ];
    };
    domainFilters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    serviceTypeFilters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    annotationFilter = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    policy = lib.mkOption {
      type = lib.types.str;
      default = "upsert-only";
    };
    txtOwnerId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    txtPrefix = lib.mkOption {
      type = lib.types.str;
      default = "ext-dns-";
    };
    registry = lib.mkOption {
      type = lib.types.str;
      default = "txt";
    };
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
    };
    logFormat = lib.mkOption {
      type = lib.types.str;
      default = "text";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
    };
    metricsPort = lib.mkOption {
      type = lib.types.int;
      default = 7979;
    };
    cloudflare = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        dnsRecordsPerPage = 100;
      };
    };
    triggerLoopOnEvent = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    env = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    secretName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    extraLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
          ephemeral-storage = "50Mi";
        };
        limits = {
          cpu = "150m";
          memory = "192Mi";
          ephemeral-storage = "2Gi";
        };
      };
    };
    affinity = lib.mkOption {
      type = lib.types.anything;
      default = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [
            {
              podAffinityTerm = {
                labelSelector.matchLabels = {
                  "app.kubernetes.io/name" = "external-dns";
                  "app.kubernetes.io/instance" = "PLACEHOLDER";
                };
                topologyKey = "kubernetes.io/hostname";
              };
              weight = 1;
            }
          ];
        };
      };
    };
    pdb = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        enabled = true;
        maxUnavailable = 1;
      };
    };
    networkPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        enabled = true;
      };
    };
  };

  build = { self, config, clusterConfig }:
  let
    name = scope.instanceName;

    selectorLabels = {
      "app.kubernetes.io/name" = "external-dns";
      "app.kubernetes.io/instance" = name;
    };

    ownerId = if config.txtOwnerId != null then config.txtOwnerId else name;

    # Merge extra labels into all resource labels.
    allLabels = selectorLabels // config.extraLabels;

    # Resolve the affinity with actual instance name replacing PLACEHOLDER.
    resolvedAffinity =
      let
        defaultAffinity = {
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [
              {
                podAffinityTerm = {
                  labelSelector.matchLabels = selectorLabels;
                  topologyKey = "kubernetes.io/hostname";
                };
                weight = 1;
              }
            ];
          };
        };
      in
      if config.affinity == { } then
        null
      else if config.affinity ? podAntiAffinity then
        # Replace PLACEHOLDER in the default affinity structure with actual selectorLabels
        defaultAffinity
      else
        config.affinity;

    # Build CLI args for the external-dns binary — ordered to match bitnami chart.
    args = [
      "--metrics-address=:${toString config.metricsPort}"
      "--log-level=${config.logLevel}"
      "--log-format=${config.logFormat}"
    ]
    ++ map (t: "--service-type-filter=${t}") config.serviceTypeFilters
    ++ map (d: "--domain-filter=${d}") config.domainFilters
    ++ [
      "--policy=${config.policy}"
      "--provider=${config.provider}"
      "--registry=${config.registry}"
      "--interval=${config.interval}"
      "--txt-prefix=${config.txtPrefix}"
    ]
    ++ lib.optional (config.annotationFilter != null) "--annotation-filter=${config.annotationFilter}"
    ++ map (s: "--source=${s}") config.sources
    ++ [ "--cloudflare-dns-records-per-page=${toString config.cloudflare.dnsRecordsPerPage}" ]
    ++ lib.optional config.triggerLoopOnEvent "--events";

    # Container env: Cloudflare credentials from a secret named after the instance.
    containerEnv =
      config.env
      ++ lib.optionals (config.secretName != null) [
        {
          name = "CF_API_EMAIL";
        }
        {
          name = "CF_API_KEY";
          valueFrom.secretKeyRef = {
            name = config.secretName;
            key = "cloudflare_api_key";
            optional = true;
          };
        }
        {
          name = "CF_API_TOKEN";
          valueFrom.secretKeyRef = {
            name = config.secretName;
            key = "cloudflare_api_token";
            optional = true;
          };
        }
      ];

  in
  {

    # --- ServiceAccount ---
    serviceAccount = scope.mkResource {
      apiVersion = "v1";
      kind = "ServiceAccount";
      inherit name;
      labels = allLabels;
      extra = {
        automountServiceAccountToken = false;
      };
    };

    # --- Secret (Opaque, credentials managed externally) ---
    secret =
      if config.secretName != null then
        scope.mkResource {
          apiVersion = "v1";
          kind = "Secret";
          name = config.secretName;
          labels = allLabels;
          extra = {
            type = "Opaque";
          };
        }
      else
        null;

    # --- ClusterRole ---
    clusterRole = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      name = "${name}-${scope.namespaceName}";
      labels = allLabels;
      extra.rules = [
        {
          apiGroups = [ "" ];
          resources = [
            "services"
            "pods"
            "nodes"
            "endpoints"
            "namespaces"
          ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "cis.f5.com" ];
          resources = [
            "virtualservers"
            "transportservers"
          ];
          verbs = [
            "get"
            "watch"
            "list"
          ];
        }
        {
          apiGroups = [ "configuration.konghq.com" ];
          resources = [ "tcpingresses" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [
            "extensions"
            "networking.k8s.io"
            "getambassador.io"
          ];
          resources = [
            "ingresses"
            "hosts"
          ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "gateway.networking.k8s.io" ];
          resources = [
            "gateways"
            "httproutes"
            "tlsroutes"
            "tcproutes"
            "udproutes"
            "grpcroutes"
          ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [
            "gloo.solo.io"
            "gateway.solo.io"
          ];
          resources = [
            "proxies"
            "virtualservices"
          ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "networking.istio.io" ];
          resources = [
            "gateways"
            "virtualservices"
          ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "projectcontour.io" ];
          resources = [ "httpproxies" ];
          verbs = [
            "get"
            "watch"
            "list"
          ];
        }
        {
          apiGroups = [ "route.openshift.io" ];
          resources = [ "routes" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "zalando.org" ];
          resources = [ "routegroups" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
        {
          apiGroups = [ "zalando.org" ];
          resources = [ "routegroups/status" ];
          verbs = [
            "patch"
            "update"
          ];
        }
      ];
    };

    # --- ClusterRoleBinding ---
    clusterRoleBinding = scope.mkClusterResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      name = "${name}-${scope.namespaceName}";
      labels = allLabels;
      extra = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.out.name;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
      };
    };

    # --- Service (metrics) ---
    service = scope.mkResource {
      apiVersion = "v1";
      kind = "Service";
      inherit name;
      labels = allLabels // { "k8s-app" = "external-dns"; };
      spec = {
        type = "ClusterIP";
        selector = selectorLabels;
        ports = [
          {
            name = "http";
            port = config.metricsPort;
            targetPort = "http";
            protocol = "TCP";
          }
        ];
      };
      outputs = {
        metricsPort = toString config.metricsPort;
      };
    };

    # --- NetworkPolicy ---
    networkPolicy =
      if config.networkPolicy.enabled then
        scope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          inherit name;
          labels = allLabels // {
            "app.kubernetes.io/component" = "controller";
          };
          spec = {
            podSelector.matchLabels = selectorLabels;
            policyTypes = [
              "Ingress"
              "Egress"
            ];
            ingress = [
              {
                ports = [
                  {
                    port = config.metricsPort;
                    protocol = "TCP";
                  }
                ];
              }
            ];
            egress = [ { } ];
          };
        }
      else
        null;

    # --- PodDisruptionBudget ---
    podDisruptionBudget =
      if config.pdb.enabled then
        scope.mkResource {
          apiVersion = "policy/v1";
          kind = "PodDisruptionBudget";
          inherit name;
          labels = allLabels;
          spec = {
            maxUnavailable = config.pdb.maxUnavailable;
            selector.matchLabels = selectorLabels;
          };
        }
      else
        null;

    # --- Deployment ---
    deployment = scope.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      inherit name;
      labels = allLabels;
      requires = [
        self.clusterRole
        self.clusterRoleBinding
        self.service
      ]
      ++ lib.optional (self.secret != null) self.secret
      ++ lib.optional (self.networkPolicy != null) self.networkPolicy
      ++ lib.optional (self.podDisruptionBudget != null) self.podDisruptionBudget;
      spec = {
        replicas = 1;
        selector.matchLabels = selectorLabels;
        strategy = {
          type = "RollingUpdate";
          rollingUpdate = {
            maxSurge = "25%";
            maxUnavailable = "25%";
          };
        };
        template = {
          metadata.labels = selectorLabels;
          spec = {
            serviceAccountName = self.serviceAccount.out.name;
            automountServiceAccountToken = true;
            affinity = resolvedAffinity;
            securityContext = {
              fsGroup = 1001;
              fsGroupChangePolicy = "Always";
            };
            containers = [
              (
                {
                  name = "external-dns";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  inherit args;
                  ports = [
                    {
                      name = "http";
                      containerPort = config.metricsPort;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    tcpSocket = {
                      port = "http";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 2;
                    successThreshold = 1;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "http";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                    timeoutSeconds = 5;
                    failureThreshold = 6;
                    successThreshold = 1;
                  };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    privileged = false;
                    readOnlyRootFilesystem = true;
                    runAsGroup = 1001;
                    runAsNonRoot = true;
                    runAsUser = 1001;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  volumeMounts = [
                    {
                      name = "empty-dir";
                      mountPath = "/tmp";
                      subPath = "tmp-dir";
                    }
                  ];
                }
                // lib.optionalAttrs (containerEnv != [ ]) {
                  env = containerEnv;
                }
              )
            ];
            volumes = [
              {
                name = "empty-dir";
              }
            ];
          };
        };
      };
    };

    # --- Entry point ---
    main = self.deployment;
  };
}
