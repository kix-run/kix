# ingress-nginx kix package.
#
# NGINX Ingress Controller for Kubernetes. Supports multiple instances
# in the same namespace — all resource names are prefixed with
# scope.instanceName to avoid collisions.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Role
# (leader election), RoleBinding, ConfigMap (NGINX config), Deployment,
# Service (LoadBalancer/ClusterIP), IngressClass.
#
# main = Service, with requires pointing to Deployment, IngressClass,
# and ConfigMap.

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "registry.k8s.io/ingress-nginx/controller";
      tag = "v1.12.1";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 3;
    serviceType = "LoadBalancer";
    clusterIP = null;
    ingressClassName = null;
    isDefaultClass = false;
    controllerValue = null;
    config = {
      proxy-body-size = "200M";
      use-forwarded-headers = "true";
      annotations-risk-level = "Critical";
    };
    allowSnippetAnnotations = true;
    maxmindLicenseKey = null;
    enableAntiAffinity = true;
    resources = {
      requests = {
        cpu = "100m";
        memory = "90Mi";
      };
      limits = {
        cpu = "1";
        memory = "256Mi";
      };
    };
  };

  # Derived values — ingressClassName and controllerValue default to
  # instance-name-based values when not overridden.
  ingressClassName = if cfg.ingressClassName != null then cfg.ingressClassName else name;

  controllerValue =
    if cfg.controllerValue != null then cfg.controllerValue else "k8s.io/ingress-nginx-${name}";

  electionId = "ingress-nginx-${name}-leader";

  selectorLabels = {
    "app.kubernetes.io/name" = "ingress-nginx";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "controller";
  };

  commonLabels = selectorLabels // {
    "app.kubernetes.io/part-of" = "ingress-nginx";
  };

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-ingress-nginx";
    labels = commonLabels;
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-ingress-nginx";
    labels = commonLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "configmaps"
          "endpoints"
          "nodes"
          "pods"
          "secrets"
          "namespaces"
        ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "nodes" ];
        verbs = [ "get" ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "services" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses/status" ];
        verbs = [ "update" ];
      }
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingressclasses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [
          "list"
          "watch"
          "get"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "list"
          "watch"
        ];
      }
    ];
  };

  # --- ClusterRoleBinding ---
  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-ingress-nginx";
    labels = commonLabels;
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

  # --- Role (leader election, namespace-scoped) ---
  role = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${name}-ingress-nginx";
    labels = commonLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "configmaps" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
        ];
      }
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [ "get" ];
      }
    ];
  };

  # --- RoleBinding ---
  roleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${name}-ingress-nginx";
    labels = commonLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.role}";
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

  # --- ConfigMap (NGINX configuration) ---
  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-ingress-nginx-controller";
    labels = commonLabels;
    data =
      cfg.config
      // lib.optionalAttrs cfg.allowSnippetAnnotations {
        allow-snippet-annotations = "true";
      }
      // lib.optionalAttrs (cfg.maxmindLicenseKey != null) {
        maxmind-license-key = cfg.maxmindLicenseKey;
      };
  };

  # --- Deployment ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-ingress-nginx-controller";
    labels = commonLabels;
    spec = {
      replicas = cfg.replicaCount;
      revisionHistoryLimit = 10;
      minReadySeconds = 0;
      selector.matchLabels = selectorLabels;
      template = {
        metadata = {
          labels = selectorLabels;
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 300;
          dnsPolicy = "ClusterFirst";
          containers = [
            {
              name = "controller";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              args = [
                "/nginx-ingress-controller"
                "--publish-service=$(POD_NAMESPACE)/${name}-ingress-nginx-controller"
                "--election-id=${electionId}"
                "--controller-class=${controllerValue}"
                "--ingress-class=${ingressClassName}"
                "--configmap=$(POD_NAMESPACE)/${self.configmap}"
                "--validating-webhook=:8443"
                "--validating-webhook-certificate=/usr/local/certificates/cert"
                "--validating-webhook-key=/usr/local/certificates/key"
              ]
              ++ lib.optional cfg.allowSnippetAnnotations "--enable-annotation-validation=true";
              env = [
                {
                  name = "POD_NAME";
                  valueFrom.fieldRef.fieldPath = "metadata.name";
                }
                {
                  name = "POD_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
                {
                  name = "LD_PRELOAD";
                  value = "/usr/local/lib/libmimalloc.so";
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
                {
                  name = "metrics";
                  containerPort = 10254;
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
              resources = cfg.resources;
              securityContext = {
                runAsUser = 101;
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
                  mountPath = "/usr/local/certificates/";
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
                secretName = "${name}-ingress-nginx-admission";
              };
            }
          ];
        }
        // lib.optionalAttrs cfg.enableAntiAffinity {
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
            {
              weight = 100;
              podAffinityTerm = {
                labelSelector.matchExpressions = [
                  {
                    key = "app.kubernetes.io/instance";
                    operator = "In";
                    values = [ name ];
                  }
                  {
                    key = "app.kubernetes.io/name";
                    operator = "In";
                    values = [ "ingress-nginx" ];
                  }
                  {
                    key = "app.kubernetes.io/component";
                    operator = "In";
                    values = [ "controller" ];
                  }
                ];
                topologyKey = "kubernetes.io/hostname";
              };
            }
            {
              weight = 50;
              podAffinityTerm = {
                labelSelector.matchExpressions = [
                  {
                    key = "app.kubernetes.io/instance";
                    operator = "In";
                    values = [ name ];
                  }
                  {
                    key = "app.kubernetes.io/name";
                    operator = "In";
                    values = [ "ingress-nginx" ];
                  }
                  {
                    key = "app.kubernetes.io/component";
                    operator = "In";
                    values = [ "controller" ];
                  }
                ];
                topologyKey = "topology.kubernetes.io/zone";
              };
            }
          ];
        };
      };
    };
  };

  # --- Service ---
  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-ingress-nginx-controller";
    labels = commonLabels;
    annotations = {
      # Preserve source IP for external traffic.
    };
    spec = {
      type = cfg.serviceType;
      selector = selectorLabels;
      ports = [
        {
          name = "http";
          port = 80;
          protocol = "TCP";
          targetPort = "http";
        }
        {
          name = "https";
          port = 443;
          protocol = "TCP";
          targetPort = "https";
        }
      ];
    }
    // lib.optionalAttrs (cfg.serviceType == "LoadBalancer") {
      externalTrafficPolicy = "Local";
    }
    // lib.optionalAttrs (cfg.clusterIP != null) {
      clusterIP = cfg.clusterIP;
    };
    requires = [
      self.deployment
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
    annotations = lib.optionalAttrs cfg.isDefaultClass {
      "ingressclass.kubernetes.io/is-default-class" = "true";
    };
    spec = {
      controller = controllerValue;
    };
  };

  # --- Entry point ---
  main = self.service;
}
