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
  lib,
  kix,
  availability,
}:

let
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

  # Base CRD resources always managed by the operator.
  baseManagedCrds = [
    "infisicaldynamicsecrets"
    "infisicalpushsecrets"
    "infisicalsecrets"
  ];

  # --- RBAC DSL ---
  inherit (scope.rbac)
    group
    core
    grant
    full
    readWrite
    watch
    allow
    mkClusterRoleSet
    mkRoleSet
    ;
  apps = group "apps" [
    "daemonsets"
    "deployments"
    "statefulsets"
  ];
  authn = group "authentication.k8s.io" [ "tokenreviews" ];
  authz = group "authorization.k8s.io" [ "subjectaccessreviews" ];
  coord = group "coordination.k8s.io" [ "leases" ];
  emit = scope.rbac.emit;

in
{
  meta = {
    version = "v0.9.1";
    description = "Infisical Secrets Operator, which syncs secrets from Infisical into Kubernetes Secrets through InfisicalSecret resources";
    owner = "platform";
  };

  options = {
    image = kix.options.image {
      repository = "infisical/kubernetes-operator";
      tag = "v0.9.1";
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # The manager runs with --leader-elect, so a restart is invisible and
      # "pod" stays at 1; from "node" up a standby survives a lost node.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of operator replicas. Defaults from the cluster's
        availability level (v2_discussions/145).
      '';
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "128Mi";
        };
      };
    };
    # Override the resource name prefix (e.g. for Helm-truncated names).
    # Defaults to the instance name.
    namePrefix = lib.mkOption {
      type = lib.types.str;
      default = scope.instanceName;
    };
    # kube-rbac-proxy sidecar for securing the metrics endpoint.
    kubeRbacProxy = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Serve the metrics endpoint through a kube-rbac-proxy sidecar over HTTPS.";
      };
      image = kix.options.image {
        repository = "gcr.io/kubebuilder/kube-rbac-proxy";
        tag = "v0.15.0";
        description = "Image for the kube-rbac-proxy sidecar.";
      };
      resources = lib.mkOption {
        type = lib.types.anything;
        default = {
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
    };
    # Extra CRD resources managed by the manager ClusterRole beyond the
    # base set (infisicalsecrets, infisicaldynamicsecrets, infisicalpushsecrets).
    # Set to a list of resource names, e.g. [ "clustergenerators" ].
    extraManagedCrds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    # Extra env vars merged onto the manager container. Use for site-specific
    # configuration like INFISICAL_HOST_API.
    managerEnv = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      prefix = config.namePrefix;

      # Manager container args differ depending on whether kube-rbac-proxy is used.
      managerArgs =
        if config.kubeRbacProxy.enabled then
          [
            "--health-probe-bind-address=:8081"
            "--metrics-bind-address=127.0.0.1:8080"
            "--leader-elect"
          ]
        else
          [
            "--metrics-bind-address=:8443"
            "--leader-elect"
            "--health-probe-bind-address=:8081"
          ];

      # Manager container definition (shared between proxy and non-proxy modes).
      managerContainer = {
        name = "manager";
        image = kix.image.ref config.image;
        imagePullPolicy = config.image.pullPolicy;
        command = [ "/manager" ];
        args = managerArgs;
        env = [
          {
            name = "KUBERNETES_CLUSTER_DOMAIN";
            value = "cluster.local";
          }
        ]
        ++ config.managerEnv;
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
        resources = config.resources;
        securityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
          readOnlyRootFilesystem = true;
        };
      }
      // lib.optionalAttrs (!config.kubeRbacProxy.enabled) {
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
      };

      # kube-rbac-proxy sidecar container.
      proxyContainer = {
        name = "kube-rbac-proxy";
        image = kix.image.ref config.kubeRbacProxy.image;
        imagePullPolicy = config.kubeRbacProxy.image.pullPolicy;
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
        resources = config.kubeRbacProxy.resources;
        securityContext = {
          allowPrivilegeEscalation = false;
          capabilities.drop = [ "ALL" ];
        };
      };

      containers =
        if config.kubeRbacProxy.enabled then
          [
            proxyContainer
            managerContainer
          ]
        else
          [ managerContainer ];

      allManagedCrds = config.extraManagedCrds ++ baseManagedCrds;

      podSecurityContext = {
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      };

      # Node affinity for the deployment (matches Helm chart defaults).
      nodeAffinity = lib.optionalAttrs config.kubeRbacProxy.enabled {
        affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
          {
            matchExpressions = [
              {
                key = "kubernetes.io/arch";
                operator = "In";
                values = [
                  "amd64"
                  "arm64"
                  "ppc64le"
                  "s390x"
                ];
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

      infisical = group "secrets.infisical.com" allManagedCrds;

      clusterRoles = mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        labels = rbacLabels;
        roles = {
          "${prefix}-manager-role" = {
            bindingName = "${prefix}-manager-rolebinding";
            rules = grant (
              [
                (core.configmaps |> readWrite)
                (
                  core.pods
                  |> allow [
                    "get"
                    "list"
                  ]
                )
                (core.secrets |> readWrite)
                (core.serviceaccounts |> watch)
                (core "serviceaccounts/token" |> allow [ "create" ])
                (
                  apps.daemonsets
                  |> allow [
                    "get"
                    "list"
                    "update"
                    "watch"
                  ]
                )
                (
                  apps.deployments
                  |> allow [
                    "get"
                    "list"
                    "update"
                    "watch"
                  ]
                )
                (
                  apps.statefulsets
                  |> allow [
                    "get"
                    "list"
                    "update"
                    "watch"
                  ]
                )
                (authn.tokenreviews |> allow [ "create" ])
              ]
              ++ lib.concatMap (crd: [
                (infisical crd |> full)
              ]) allManagedCrds
              # Helm chart only emits /finalizers and /status rules for
              # the base CRD set; extras (e.g. clustergenerators) appear
              # only in the main rule.
              ++ lib.concatMap (crd: [
                (infisical crd |> scope.rbac.finalize)
                (
                  infisical "${crd}/status"
                  |> allow [
                    "get"
                    "patch"
                    "update"
                  ]
                )
              ]) baseManagedCrds
            );
          };

          "${prefix}-proxy-role" = {
            bindingName = "${prefix}-proxy-rolebinding";
            rules = grant [
              (authn.tokenreviews |> allow [ "create" ])
              (authz.subjectaccessreviews |> allow [ "create" ])
            ];
          };
        };
      };

      nsRoles = mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        labels = rbacLabels;
        roles = {
          "${prefix}-leader-election-role" = {
            bindingName = "${prefix}-leader-election-rolebinding";
            rules = grant [
              (core.configmaps |> full)
              (coord.leases |> full)
              (core.events |> emit)
            ];
          };
        };
      };

    in
    {

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
              # 8443 is the proxy sidecar's "https" port when the sidecar
              # runs, and the manager's own "metrics" port when it does not.
              targetPort = if config.kubeRbacProxy.enabled then "https" else "metrics";
            }
          ];
        };
        outputs = {
          metricsPort = "8443";
        };
      };

      # --- Deployment ---

      deployment = scope.mkDeployment {
        name = "${prefix}-controller-manager";
        labels = selectorLabels;
        spec = {
          replicas = config.replicaCount;
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
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 10;
              securityContext = podSecurityContext;
              inherit containers;
            }
            // nodeAffinity;
          };
        };
        requires = builtins.attrValues self.crds;
      };

      # --- CRDs ---
      # Vendored from Infisical/infisical at tag infisical-k8-operator/v0.9.1,
      # k8-operator/config/crd/bases/. The controller's informers list these
      # kinds at start; without them the caches never sync and the manager
      # exits every two minutes.
      crds =
        let
          vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
        in
        {
          infisicalSecrets = scope.mkCRD { spec = vendored "infisicalsecrets.secrets.infisical.com.json"; };
          infisicalPushSecrets = scope.mkCRD {
            spec = vendored "infisicalpushsecrets.secrets.infisical.com.json";
          };
          infisicalDynamicSecrets = scope.mkCRD {
            spec = vendored "infisicaldynamicsecrets.secrets.infisical.com.json";
          };
        };

      root = {
        resource = self.deployment;
        requires = [
          self.serviceAccount
          self.metricsReaderRole
          self.service
        ]
        ++ builtins.attrValues self.crds;
      };
    }
    // clusterRoles
    // nsRoles;
}
