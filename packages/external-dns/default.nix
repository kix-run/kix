# External-DNS kix package.
#
# Manages DNS records in external providers (e.g. Cloudflare) by watching
# Kubernetes Ingress and Service resources.
#
# Supports multi-instance deployment: each instance can manage different
# DNS zones via domainFilters (e.g. external-dns-public for lithus.net,
# external-dns-northwind for shopfront.example).
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Deployment,
#            Service (metrics).
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
      repository = "registry.k8s.io/external-dns/external-dns";
      tag = "v0.15.1";
      pullPolicy = "IfNotPresent";
    };
    provider = "cloudflare";
    sources = [
      "ingress"
      "service"
    ];
    domainFilters = [ ];
    policy = "upsert-only";
    txtOwnerId = null;
    txtPrefix = "ext-dns-";
    registry = "txt";
    logLevel = "info";
    logFormat = "text";
    interval = "1m";
    triggerLoopOnEvent = false;
    env = [ ];
    secretName = null;
    resources = {
      requests = {
        cpu = "50m";
        memory = "64Mi";
      };
      limits = {
        cpu = "200m";
        memory = "256Mi";
      };
    };
  };

  name = scope.instanceName;

  ownerId = if cfg.txtOwnerId != null then cfg.txtOwnerId else name;

  selectorLabels = {
    "app.kubernetes.io/name" = "external-dns";
    "app.kubernetes.io/instance" = name;
  };

  # Build CLI args for the external-dns binary.
  args = [
    "--log-level=${cfg.logLevel}"
    "--log-format=${cfg.logFormat}"
    "--interval=${cfg.interval}"
    "--policy=${cfg.policy}"
    "--registry=${cfg.registry}"
    "--provider=${cfg.provider}"
    "--txt-owner-id=${ownerId}"
    "--txt-prefix=${cfg.txtPrefix}"
  ]
  ++ map (s: "--source=${s}") cfg.sources
  ++ map (d: "--domain-filter=${d}") cfg.domainFilters
  ++ lib.optional cfg.triggerLoopOnEvent "--events";

  # Container env: merge user-provided env with optional secretRef.
  containerEnv =
    cfg.env
    ++ lib.optionals (cfg.secretName != null) [
      {
        name = "CF_API_TOKEN";
        valueFrom.secretKeyRef = {
          name = cfg.secretName;
          key = "CF_API_TOKEN";
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
    labels = selectorLabels;
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    inherit name;
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "services"
          "endpoints"
          "pods"
          "nodes"
        ];
        verbs = [
          "get"
          "watch"
          "list"
        ];
      }
      {
        apiGroups = [
          "extensions"
          "networking.k8s.io"
        ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "watch"
          "list"
        ];
      }
    ];
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-viewer";
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
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
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
      ports = [
        {
          name = "http";
          port = 7979;
          targetPort = "http";
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      metricsPort = "7979";
    };
  };

  # --- Deployment ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    inherit name;
    labels = selectorLabels;
    spec = {
      replicas = 1;
      selector.matchLabels = selectorLabels;
      strategy.type = "Recreate";
      template = {
        metadata.labels = selectorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            fsGroup = 65534;
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
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
                    containerPort = 7979;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/healthz";
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
                  runAsGroup = 65532;
                  runAsNonRoot = true;
                  runAsUser = 65532;
                };
              }
              // lib.optionalAttrs (containerEnv != [ ]) {
                env = containerEnv;
              }
            )
          ];
        };
      };
    };
  };

  # --- Entry point ---
  main = self.deployment;
}
