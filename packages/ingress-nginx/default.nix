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
# main = Service, selecting the Deployment via scope.selectWorkload.
# IngressClass and ConfigMap pulled in via requires.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    # Override the resource name prefix. Defaults to the instance name.
    namePrefix = null;
    image = {
      repository = "registry.k8s.io/ingress-nginx/controller";
      tag = "v1.13.2";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 3;
    serviceType = "LoadBalancer";
    externalTrafficPolicy = "Cluster";
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
    antiAffinityTopologyKeys = [
      "kubernetes.io/hostname"
      "topology.kubernetes.io/zone"
    ];
    # Extra labels added to pod templates (e.g. tenant labels).
    podLabels = { };
    resources = {
      requests = {
        cpu = "100m";
        memory = "90Mi";
      };
    };
  };

  name = if cfg.namePrefix != null then cfg.namePrefix else scope.instanceName;

  # Derived values — ingressClassName and controllerValue default to
  # instance-name-based values when not overridden.
  ingressClassName = if cfg.ingressClassName != null then cfg.ingressClassName else name;

  controllerValue =
    if cfg.controllerValue != null then cfg.controllerValue else "k8s.io/${name}";

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

  # --- RBAC DSL ---
  inherit (scope.rbac) group core grant watch emit allow restrictTo mkClusterRoleSet mkRoleSet;
  net   = group "networking.k8s.io" [ "ingresses" "ingressclasses" ];
  disco = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];

in
self:
let

  clusterRoles = mkClusterRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = "${self.serviceAccount}"; namespace = scope.namespaceName; }];
    labels = clusterScopedLabels;
    roles = {
      "${name}" = grant [
        ([core.configmaps core.endpoints core.nodes core.pods core.secrets core.namespaces core.services] |> watch)
        (core.events                     |> emit)
        ([net.ingresses net.ingressclasses disco.endpointslices] |> watch)
        (net "ingresses/status"          |> allow [ "update" ])
        (coord.leases                    |> allow [ "list" "watch" ])
      ];
    };
  };

  nsRoles = mkRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = "${self.serviceAccount}"; namespace = scope.namespaceName; }];
    labels = commonLabels;
    roles = {
      "${name}" = grant [
        (core.namespaces                 |> allow [ "get" ])
        ([core.configmaps core.pods core.secrets core.endpoints core.services] |> watch)
        (core.events                     |> emit)
        (coord.leases                    |> restrictTo [ electionId ] |> allow [ "get" "update" ])
        (coord.leases                    |> allow [ "create" ])
        ([disco.endpointslices net.ingresses net.ingressclasses] |> watch)
        (net "ingresses/status"          |> allow [ "update" ])
      ];
    };
  };

in {

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
      cfg.config
      // lib.optionalAttrs cfg.allowSnippetAnnotations {
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
      replicas = cfg.replicaCount;
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
          labels = selectorLabels // cfg.podLabels;
        };
        spec = {
          automountServiceAccountToken = true;
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
                "--publish-service=$(POD_NAMESPACE)/${name}-controller"
                "--election-id=${electionId}"
                "--controller-class=${controllerValue}"
                "--ingress-class=${ingressClassName}"
                "--configmap=$(POD_NAMESPACE)/${self.configmap}"
                "--validating-webhook=:8443"
                "--validating-webhook-certificate=/usr/local/certificates/cert"
                "--validating-webhook-key=/usr/local/certificates/key"
              ]
              ++ lib.optional (cfg.maxmindLicenseKey != null) "--maxmind-license-key=${cfg.maxmindLicenseKey}";
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
              resources = cfg.resources;
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
        // lib.optionalAttrs cfg.enableAntiAffinity {
          affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution =
            lib.imap0 (i: topologyKey: {
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
            }) cfg.antiAffinityTopologyKeys;
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
      type = cfg.serviceType;
      selector = scope.selectWorkload self.deployment;
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
    // lib.optionalAttrs (cfg.serviceType == "LoadBalancer") {
      externalTrafficPolicy = cfg.externalTrafficPolicy;
    }
    // lib.optionalAttrs (cfg.clusterIP != null) {
      clusterIP = cfg.clusterIP;
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
    annotations = lib.optionalAttrs cfg.isDefaultClass {
      "ingressclass.kubernetes.io/is-default-class" = "true";
    };
    spec = {
      controller = controllerValue;
    };
  };

  # --- Entry point ---
  main = self.service;
} // clusterRoles // nsRoles
