# Infisical Secrets Operator package.
#
# Syncs InfisicalSecret CRDs to Kubernetes Secrets. The operator
# watches for InfisicalSecret, InfisicalDynamicSecret, InfisicalPushSecret,
# and ClusterGenerator custom resources.
#
# Resources: ServiceAccount, ClusterRole (manager + proxy + metrics-reader),
#            ClusterRoleBinding (manager + proxy), Role (leader election),
#            RoleBinding (leader election), Service (metrics), Deployment.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    image = {
      repository = "infisical/kubernetes-operator";
      tag = "v0.9.1";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    resources = {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };
    # Override the resource name prefix (e.g. for Helm-truncated names).
    # Defaults to the instance name.
    namePrefix = scope.instanceName;
    # kube-rbac-proxy sidecar for securing the metrics endpoint.
    kubeRbacProxy = {
      enabled = false;
      image = {
        repository = "gcr.io/kubebuilder/kube-rbac-proxy";
        tag = "v0.15.0";
        pullPolicy = "IfNotPresent";
      };
      resources = {
        requests = {
          cpu = "5m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
    };
    # Extra CRD resources managed by the manager ClusterRole beyond the
    # base set (infisicalsecrets, infisicaldynamicsecrets, infisicalpushsecrets).
    # Set to a list of resource names, e.g. [ "clustergenerators" ].
    extraManagedCrds = [];
  };

  prefix = cfg.namePrefix;
  name = scope.instanceName;
  ns = scope.namespaceName;

  # Labels applied to the deployment, service, and pod selector.
  selectorLabels = {
    "app.kubernetes.io/name" = "secrets-operator";
    "app.kubernetes.io/instance" = name;
    "control-plane" = "controller-manager";
  };

  # Labels for RBAC and ServiceAccount resources (no control-plane label).
  rbacLabels = {
    "app.kubernetes.io/name" = "secrets-operator";
    "app.kubernetes.io/instance" = name;
  };

  # Manager container args differ depending on whether kube-rbac-proxy is used.
  managerArgs =
    if cfg.kubeRbacProxy.enabled then [
      "--health-probe-bind-address=:8081"
      "--metrics-bind-address=127.0.0.1:8080"
      "--leader-elect"
    ] else [
      "--metrics-bind-address=:8443"
      "--leader-elect"
      "--health-probe-bind-address=:8081"
    ];

  # Manager container definition (shared between proxy and non-proxy modes).
  managerContainer = {
    name = "manager";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    imagePullPolicy = cfg.image.pullPolicy;
    command = [ "/manager" ];
    args = managerArgs;
    env = [
      {
        name = "KUBERNETES_CLUSTER_DOMAIN";
        value = "cluster.local";
      }
    ];
    livenessProbe = {
      httpGet = {
        path = "/healthz";
        port = 8081;
      };
      initialDelaySeconds = 15;
      periodSeconds = 20;
      failureThreshold = 3;
      timeoutSeconds = 1;
    };
    readinessProbe = {
      httpGet = {
        path = "/readyz";
        port = 8081;
      };
      initialDelaySeconds = 5;
      periodSeconds = 10;
      failureThreshold = 3;
      timeoutSeconds = 1;
    };
    resources = cfg.resources;
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };
  } // lib.optionalAttrs (!cfg.kubeRbacProxy.enabled) {
    ports = [
      {
        name = "metrics";
        containerPort = 8443;
      }
      {
        name = "health";
        containerPort = 8081;
      }
    ];
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
      readOnlyRootFilesystem = true;
    };
  };

  # kube-rbac-proxy sidecar container.
  proxyContainer = {
    name = "kube-rbac-proxy";
    image = "${cfg.kubeRbacProxy.image.repository}:${cfg.kubeRbacProxy.image.tag}";
    imagePullPolicy = cfg.kubeRbacProxy.image.pullPolicy;
    args = [
      "--secure-listen-address=0.0.0.0:8443"
      "--upstream=http://127.0.0.1:8080/"
      "--logtostderr=true"
      "--v=0"
    ];
    env = [
      {
        name = "KUBERNETES_CLUSTER_DOMAIN";
        value = "cluster.local";
      }
    ];
    ports = [
      {
        containerPort = 8443;
        name = "https";
        protocol = "TCP";
      }
    ];
    resources = cfg.kubeRbacProxy.resources;
    securityContext = {
      allowPrivilegeEscalation = false;
      capabilities.drop = [ "ALL" ];
    };
  };

  containers =
    if cfg.kubeRbacProxy.enabled then [ proxyContainer managerContainer ]
    else [ managerContainer ];

  # Base CRD resources always managed by the operator.
  baseManagedCrds = [
    "infisicaldynamicsecrets"
    "infisicalpushsecrets"
    "infisicalsecrets"
  ];

  allManagedCrds = cfg.extraManagedCrds ++ baseManagedCrds;

  # Pod security context differs based on proxy mode.
  podSecurityContext =
    if cfg.kubeRbacProxy.enabled then {
      runAsNonRoot = true;
    } else {
      runAsNonRoot = true;
      seccompProfile.type = "RuntimeDefault";
    };

  # Node affinity for the deployment (matches Helm chart defaults).
  nodeAffinity = lib.optionalAttrs cfg.kubeRbacProxy.enabled {
    affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
      {
        matchExpressions = [
          {
            key = "kubernetes.io/arch";
            operator = "In";
            values = [ "amd64" "arm64" "ppc64le" "s390x" ];
          }
          {
            key = "kubernetes.io/os";
            operator = "In";
            values = [ "linux" ];
          }
        ];
      }
    ];
  };

  # --- RBAC DSL ---
  inherit (scope.rbac) group core grant full readWrite watch allow mkClusterRoleSet mkRoleSet;
  apps      = group "apps" [ "daemonsets" "deployments" "statefulsets" ];
  authn     = group "authentication.k8s.io" [ "tokenreviews" ];
  authz     = group "authorization.k8s.io" [ "subjectaccessreviews" ];
  coord     = group "coordination.k8s.io" [ "leases" ];
  infisical = group "secrets.infisical.com" allManagedCrds;
  emit      = scope.rbac.emit;

in
self:
let

  clusterRoles = mkClusterRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = ns; }];
    labels = rbacLabels;
    roles = {
      "${prefix}-manager-role" = grant ([
        (core.configmaps              |> readWrite)
        (core.pods                    |> allow [ "get" "list" ])
        (core.secrets                 |> readWrite)
        (core.serviceaccounts         |> watch)
        (core "serviceaccounts/token" |> allow [ "create" ])
        (apps.daemonsets              |> allow [ "get" "list" "update" "watch" ])
        (apps.deployments             |> allow [ "get" "list" "update" "watch" ])
        (apps.statefulsets            |> allow [ "get" "list" "update" "watch" ])
        (authn.tokenreviews           |> allow [ "create" ])
      ] ++ lib.concatMap (crd: [
        (infisical crd               |> full)
        (infisical crd               |> scope.rbac.finalize)
        (infisical "${crd}/status"   |> allow [ "get" "patch" "update" ])
      ]) allManagedCrds);

      "${prefix}-proxy-role" = grant [
        (authn.tokenreviews           |> allow [ "create" ])
        (authz.subjectaccessreviews   |> allow [ "create" ])
      ];
    };
  };

  nsRoles = mkRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = ns; }];
    labels = rbacLabels;
    roles = {
      "${prefix}-leader-election-role" = grant [
        (core.configmaps |> full)
        (coord.leases    |> full)
        (core.events     |> emit)
      ];
    };
  };

in {

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${prefix}-controller-manager";
    labels = rbacLabels;
  };

  # --- Standalone ClusterRole (no binding — uses nonResourceURLs) ---

  metricsReaderRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${prefix}-metrics-reader";
    labels = rbacLabels;
    extra.rules = [
      {
        nonResourceURLs = [ "/metrics" ];
        verbs = [ "get" ];
      }
    ];
  };

  # --- Service (metrics) ---

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${prefix}-controller-manager-metrics-service";
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      selector = self.deployment.out.selector;
      ports = [
        {
          name = "https";
          port = 8443;
          protocol = "TCP";
          targetPort = "https";
        }
      ];
    };
    outputs = {
      metricsPort = "8443";
    };
  };

  # --- Deployment ---

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${prefix}-controller-manager";
    labels = selectorLabels;
    spec = {
      replicas = cfg.replicaCount;
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
          labels = selectorLabels;
          annotations = {
            "kubectl.kubernetes.io/default-container" = "manager";
          };
        };
        spec = {
          serviceAccountName = self.serviceAccount.out.name;
          terminationGracePeriodSeconds = 10;
          securityContext = podSecurityContext;
          inherit containers;
        } // nodeAffinity;
      };
    };
  };

  main = {
    resource = self.deployment;
    requires = [
      self.serviceAccount
      self.metricsReaderRole
      self.service
    ];
  };
}
// clusterRoles
// nsRoles
