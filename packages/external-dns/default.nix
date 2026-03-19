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
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    image = {
      repository = "docker.io/bitnami/external-dns";
      tag = "0.16.1-debian-12-r1";
      pullPolicy = "IfNotPresent";
    };
    provider = "cloudflare";
    sources = [
      "service"
      "ingress"
    ];
    domainFilters = [ ];
    serviceTypeFilters = [ ];
    annotationFilter = null;
    policy = "upsert-only";
    txtOwnerId = null;
    txtPrefix = "ext-dns-";
    registry = "txt";
    logLevel = "info";
    logFormat = "text";
    interval = "1m";
    metricsPort = 7979;
    cloudflare = {
      dnsRecordsPerPage = 100;
    };
    triggerLoopOnEvent = false;
    env = [ ];
    secretName = null;
    extraLabels = { };
    resources = {
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
    affinity = {
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
    pdb = {
      enabled = true;
      maxUnavailable = 1;
    };
    networkPolicy = {
      enabled = true;
    };
  };

  name = scope.instanceName;

  ownerId = if cfg.txtOwnerId != null then cfg.txtOwnerId else name;

  selectorLabels = {
    "app.kubernetes.io/name" = "external-dns";
    "app.kubernetes.io/instance" = name;
  };

  # Merge extra labels into all resource labels.
  allLabels = selectorLabels // cfg.extraLabels;

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
    if cfg.affinity == { } then
      null
    else if cfg.affinity ? podAntiAffinity then
      # Replace PLACEHOLDER in the default affinity structure with actual selectorLabels
      defaultAffinity
    else
      cfg.affinity;

  # Build CLI args for the external-dns binary — ordered to match bitnami chart.
  args = [
    "--metrics-address=:${toString cfg.metricsPort}"
    "--log-level=${cfg.logLevel}"
    "--log-format=${cfg.logFormat}"
  ]
  ++ map (t: "--service-type-filter=${t}") cfg.serviceTypeFilters
  ++ map (d: "--domain-filter=${d}") cfg.domainFilters
  ++ [
    "--policy=${cfg.policy}"
    "--provider=${cfg.provider}"
    "--registry=${cfg.registry}"
    "--interval=${cfg.interval}"
    "--txt-prefix=${cfg.txtPrefix}"
  ]
  ++ lib.optional (cfg.annotationFilter != null) "--annotation-filter=${cfg.annotationFilter}"
  ++ map (s: "--source=${s}") cfg.sources
  ++ [ "--cloudflare-dns-records-per-page=${toString cfg.cloudflare.dnsRecordsPerPage}" ]
  ++ lib.optional cfg.triggerLoopOnEvent "--events";

  # Container env: Cloudflare credentials from a secret named after the instance.
  containerEnv =
    cfg.env
    ++ lib.optionals (cfg.secretName != null) [
      {
        name = "CF_API_EMAIL";
      }
      {
        name = "CF_API_KEY";
        valueFrom.secretKeyRef = {
          name = cfg.secretName;
          key = "cloudflare_api_key";
          optional = true;
        };
      }
      {
        name = "CF_API_TOKEN";
        valueFrom.secretKeyRef = {
          name = cfg.secretName;
          key = "cloudflare_api_token";
          optional = true;
        };
      }
    ];

in
self: {

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
    if cfg.secretName != null then
      scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = cfg.secretName;
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
          port = cfg.metricsPort;
          targetPort = "http";
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      metricsPort = toString cfg.metricsPort;
    };
  };

  # --- NetworkPolicy ---
  networkPolicy =
    if cfg.networkPolicy.enabled then
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
                  port = cfg.metricsPort;
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
    if cfg.pdb.enabled then
      scope.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        inherit name;
        labels = allLabels;
        spec = {
          maxUnavailable = cfg.pdb.maxUnavailable;
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
                image = "${cfg.image.repository}:${cfg.image.tag}";
                imagePullPolicy = cfg.image.pullPolicy;
                inherit args;
                ports = [
                  {
                    name = "http";
                    containerPort = cfg.metricsPort;
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
                resources = cfg.resources;
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
}
