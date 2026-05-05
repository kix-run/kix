# ingress-nginx kix package.
#
# NGINX Ingress Controller for Kubernetes. Supports multiple instances
# in the same namespace — all resource names are prefixed with
# scope.instanceName to avoid collisions.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Role,
# RoleBinding, ConfigMap (NGINX config), Deployment, Service
# (LoadBalancer/ClusterIP), IngressClass, ValidatingWebhookConfiguration.
#
# root = Service, selecting the Deployment via out.selector.
# IngressClass and ConfigMap pulled in via requires.

{
  scope,
  lib,
  kix,
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
    version = "v1.14.0";
    description = "NGINX Ingress Controller for Kubernetes";
    provides = [
      "ingress"
      "ingress-controller"
    ];
    defaultAliases = [ "ingressNginx" ];
    k8s.minVersion = "1.25";
    # The ingress controller proxies external traffic to backend pods.
    # It needs world ingress (external HTTP/HTTPS), all-pods ingress
    # (webhook callbacks from kube-apiserver), and world egress (OCSP
    # stapling, upstream auth endpoints, etc.).
    network.intents = {
      external-ingress = {
        ingress = [
          {
            from = "world";
            ports = [
              {
                port = 80;
                protocol = "TCP";
              }
              {
                port = 443;
                protocol = "TCP";
              }
            ];
          }
        ];
      };
      webhook-ingress = {
        ingress = [
          {
            from = "all-pods";
            ports = [
              {
                port = 8443;
                protocol = "TCP";
              }
            ];
          }
        ];
      };
    };
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
        tag = "v1.14.0";
        digest = null;
        pullPolicy = "IfNotPresent";
      };
    };
    webhookCertgenImage = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "registry.k8s.io/ingress-nginx/kube-webhook-certgen";
        tag = "v1.4.4";
        digest = null;
      };
    };
    # Suffix appended to controller-bound resource names (Deployment,
    # ConfigMap, Service, PDB, admission Service). Helm chart 4.13+
    # uses "-controller"; older charts (4.10 and earlier) use "".
    controllerNameSuffix = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    # Override the controller's --election-id arg. Defaults to "<name>-leader".
    electionId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    # Override the controller's --ingress-class arg. Defaults to ingressClassName.
    # (Helm chart 4.15+ defaults this to "nginx" not the resource name.)
    controllerIngressClass = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    serviceType = lib.mkOption {
      type = lib.types.str;
      default = "ClusterIP";
    };
    externalTrafficPolicy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
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
      default = true;
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
    allocateLoadBalancerNodePorts = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Whether to allocate node ports for LoadBalancer services";
    };
    nodePorts = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
      description = "Map of port name to nodePort value (e.g. { http = 30080; https = 30443; })";
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

      # Name used for controller-bound resources (Deployment, ConfigMap,
      # Service, PDB, admission Service). Newer ingress-nginx charts
      # (4.13+) suffix these with "-controller" while keeping the SA,
      # Roles, IngressClass, ValidatingWebhookConfiguration, and
      # admission Jobs at the bare instance name.
      ctrlName = "${name}${config.controllerNameSuffix}";

      # Derived values — ingressClassName and controllerValue default to
      # instance-name-based values when not overridden.
      ingressClassName = if config.ingressClassName != null then config.ingressClassName else name;

      controllerIngressClass =
        if config.controllerIngressClass != null then config.controllerIngressClass else ingressClassName;

      controllerValue =
        if config.controllerValue != null then config.controllerValue else "k8s.io/${name}";

      electionId = if config.electionId != null then config.electionId else "${name}-leader";

      controllerImage =
        "${config.image.repository}:${config.image.tag}"
        + lib.optionalString (
          config.image ? digest && config.image.digest != null
        ) "@${config.image.digest}";

      certgenImage =
        "${config.webhookCertgenImage.repository}:${config.webhookCertgenImage.tag}"
        + lib.optionalString (
          config.webhookCertgenImage ? digest && config.webhookCertgenImage.digest != null
        ) "@${config.webhookCertgenImage.digest}";

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

      admissionClusterRoles =
        let
          adm = group "admissionregistration.k8s.io" [ "validatingwebhookconfigurations" ];
        in
        mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.admissionServiceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
          labels = clusterScopedLabels // {
            "app.kubernetes.io/component" = "admission-webhook";
          };
          roles = {
            "${name}-admission" = grant [
              (
                adm.validatingwebhookconfigurations
                |> allow [
                  "get"
                  "update"
                ]
              )
            ];
          };
        };

      admissionWebhookLabels = commonLabels // {
        "app.kubernetes.io/component" = "admission-webhook";
      };
      admissionHookAnnotations = {
        "helm.sh/hook" = "pre-install,pre-upgrade,post-install,post-upgrade";
        "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
      };
      admissionRole = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "${name}-admission";
        labels = admissionWebhookLabels;
        annotations = admissionHookAnnotations;
        extra.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [
              "create"
              "get"
            ];
          }
        ];
      };
      admissionRoleBinding = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "${name}-admission";
        labels = admissionWebhookLabels;
        annotations = admissionHookAnnotations;
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = admissionRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.admissionServiceAccount.out.name;
              namespace = scope.namespaceName;
            }
          ];
        };
      };
      admissionNsRoles = {
        "${name}-admission" = admissionRole;
        "${name}-admission-binding" = admissionRoleBinding;
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
        name = ctrlName;
        labels = commonLabels;
        data =
          config.config
          // lib.optionalAttrs config.allowSnippetAnnotations {
            allow-snippet-annotations = "true";
          };
      };

      # --- Deployment ---
      deployment = scope.mkDeployment {
        name = ctrlName;
        labels = commonLabels;
        # Must deploy after admissionCreate so the ingress-nginx-admission
        # secret exists before the pod tries to mount it. Controller RBAC
        # must be reachable from root so the ServiceAccount has permissions
        # to list ingressclasses, services, etc — without these, the
        # controller's caches time out and the pod CrashLoops.
        # Service must exist before the controller starts: --publish-service
        # below references it, and the controller fatally exits with
        # `no service with name ${name} found` if the lookup fails at startup.
        requires = [
          self.admissionCreate
          self.service
        ]
        ++ builtins.attrValues clusterRoles
        ++ builtins.attrValues nsRoles;
        spec = {
          replicas = config.replicaCount;
          revisionHistoryLimit = 10;
          minReadySeconds = 0;
          selector.matchLabels = selectorLabels;
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
                  image = controllerImage;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "/nginx-ingress-controller"
                    "--publish-service=$(POD_NAMESPACE)/${ctrlName}"
                    "--election-id=${electionId}"
                    "--controller-class=${controllerValue}"
                    "--ingress-class=${controllerIngressClass}"
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
                    # Created by the webhook setup job, not by kix.
                    secretName = kix.untrackedRef "${name}-admission";
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
      service =
        let
          addNodePort =
            portDef:
            portDef
            // lib.optionalAttrs (config.nodePorts ? ${portDef.name}) {
              nodePort = config.nodePorts.${portDef.name};
            };
        in
        scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = ctrlName;
          labels = commonLabels;
          spec = {
            type = config.serviceType;
            ipFamilyPolicy = "SingleStack";
            ipFamilies = [ "IPv4" ];
            # Use self.deployment.rawSelector instead of
            # self.deployment.out.selector to avoid an evaluation cycle:
            # the deployment now `requires` this service (so the controller
            # finds its --publish-service at startup). rawSelector is a
            # cheap accessor that doesn't force the workload's manifest
            # hash — no cycle, and the selector is coupled to the actual
            # workload spec (unlike a hand-rolled label literal).
            selector = self.deployment.rawSelector;
            ports = map addNodePort [
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
          //
            lib.optionalAttrs (config.serviceType == "LoadBalancer" && config.externalTrafficPolicy != null)
              {
                externalTrafficPolicy = config.externalTrafficPolicy;
              }
          // lib.optionalAttrs (config.allocateLoadBalancerNodePorts != null) {
            allocateLoadBalancerNodePorts = config.allocateLoadBalancerNodePorts;
          }
          // lib.optionalAttrs (config.clusterIP != null) {
            clusterIP = config.clusterIP;
          };
          requires = [
            self.ingressClass
            self.configmap
            self.pdb
            self.admissionService
            self.admissionWebhook
            self.admissionCreate
          ];
        };

      # --- PodDisruptionBudget ---
      pdb = scope.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        name = ctrlName;
        labels = commonLabels;
        spec = {
          minAvailable = 1;
          # See selector comment on the Service: rawSelector avoids the
          # manifest-hash cycle caused by deployment requiring the service.
          selector.matchLabels = self.deployment.rawSelector;
        };
      };

      # --- Admission webhook ServiceAccount ---
      admissionServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-admission";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "admission-webhook";
        };
        annotations = {
          "helm.sh/hook" = "pre-install,pre-upgrade,post-install,post-upgrade";
          "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        };
        extra.automountServiceAccountToken = true;
      };

      # Job: generate TLS cert and store as secret ${name}-admission.
      # Runs once; Kubernetes re-creates it on next apply only if deleted.
      admissionCreate = scope.mkJob {
        name = "${name}-admission-create";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "admission-webhook";
        };
        annotations = {
          "helm.sh/hook" = "pre-install,pre-upgrade";
          "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        };
        spec = {
          ttlSecondsAfterFinished = 0;
          template = {
            metadata = {
              name = "${name}-admission-create";
              labels = commonLabels // {
                "app.kubernetes.io/component" = "admission-webhook";
              };
            };
            spec = {
              serviceAccountName = self.admissionServiceAccount.out.name;
              automountServiceAccountToken = true;
              restartPolicy = "OnFailure";
              containers = [
                {
                  name = "create";
                  image = certgenImage;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "create"
                    "--host=${ctrlName}-admission,${ctrlName}-admission.$(POD_NAMESPACE).svc"
                    "--namespace=$(POD_NAMESPACE)"
                    "--secret-name=${name}-admission"
                  ];
                  env = [
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    runAsGroup = 65532;
                    runAsNonRoot = true;
                    runAsUser = 65532;
                    seccompProfile.type = "RuntimeDefault";
                  };
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            };
          };
        };
        requires = builtins.attrValues admissionClusterRoles ++ builtins.attrValues admissionNsRoles;
      };

      # Job: patch ValidatingWebhookConfiguration with the generated CA bundle.
      admissionPatch = scope.mkJob {
        name = "${name}-admission-patch";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "admission-webhook";
        };
        annotations = {
          "helm.sh/hook" = "post-install,post-upgrade";
          "helm.sh/hook-delete-policy" = "before-hook-creation,hook-succeeded";
        };
        spec = {
          ttlSecondsAfterFinished = 0;
          template = {
            metadata = {
              name = "${name}-admission-patch";
              labels = commonLabels // {
                "app.kubernetes.io/component" = "admission-webhook";
              };
            };
            spec = {
              serviceAccountName = self.admissionServiceAccount.out.name;
              automountServiceAccountToken = true;
              restartPolicy = "OnFailure";
              containers = [
                {
                  name = "patch";
                  image = certgenImage;
                  imagePullPolicy = "IfNotPresent";
                  args = [
                    "patch"
                    "--webhook-name=${name}-admission"
                    "--namespace=$(POD_NAMESPACE)"
                    "--patch-mutating=false"
                    "--secret-name=${name}-admission"
                    "--patch-failure-policy=Fail"
                  ];
                  env = [
                    {
                      name = "POD_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.namespace";
                    }
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    runAsGroup = 65532;
                    runAsNonRoot = true;
                    runAsUser = 65532;
                    seccompProfile.type = "RuntimeDefault";
                  };
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            };
          };
        };
        requires = [
          self.admissionCreate
          self.admissionWebhook
        ];
      };

      # --- Admission webhook Service ---
      admissionService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "${ctrlName}-admission";
        labels = commonLabels;
        spec = {
          type = "ClusterIP";
          # See selector comment on the main Service: rawSelector avoids
          # the cycle while staying coupled to the workload's labels.
          selector = self.deployment.rawSelector;
          ports = [
            {
              name = "https-webhook";
              port = 443;
              protocol = "TCP";
              targetPort = "webhook";
              appProtocol = "https";
            }
          ];
        };
      };

      # --- ValidatingWebhookConfiguration (cluster-scoped) ---
      admissionWebhook = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingWebhookConfiguration";
        name = "${name}-admission";
        labels = commonLabels // {
          "app.kubernetes.io/component" = "admission-webhook";
        };
        extra.webhooks = [
          {
            name = "validate.nginx.ingress.kubernetes.io";
            admissionReviewVersions = [ "v1" ];
            clientConfig.service = {
              name = self.admissionService.out.name;
              namespace = scope.namespaceName;
              path = "/networking/v1/ingresses";
              port = 443;
            };
            failurePolicy = "Fail";
            matchPolicy = "Equivalent";
            rules = [
              {
                apiGroups = [ "networking.k8s.io" ];
                apiVersions = [ "v1" ];
                operations = [
                  "CREATE"
                  "UPDATE"
                ];
                resources = [ "ingresses" ];
                scope = "*";
              }
            ];
            sideEffects = "None";
            timeoutSeconds = 10;
          }
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
      #
      # root.resource is the Deployment, not the Service, even though the
      # Service is the user-facing handle. Why: this package is wired
      # "inverse" — the Deployment requires the Service (the controller's
      # --publish-service flag fatally exits if the Service doesn't exist
      # at startup), so the Service is upstream of the Deployment in the
      # forward closure. If root were the Service, the PackageInstance's
      # "main" resource would be Ready before the actual controller pod.
      #
      # ingressClassName carries the Deployment's store-path context in
      # addition to the IngressClass's. Consumer dep edges flow through
      # manifest string-context (see kix/lib/k8s.nix:271), so any package
      # that references `ingressNginx.out.ingressClassName` (notably
      # kix.expose) gets a direct depends-on edge to the controller pod —
      # not just to the IngressClass. Without this, the consumer's Ingress
      # only edges to the IngressClass (wave 0) and lands in the same
      # wave as the Service, racing the controller and failing admission
      # until the controller catches up.
      root = {
        resource = self.deployment;
        out = {
          ingressClassName = builtins.appendContext self.ingressClass.out.name (
            builtins.getContext self.deployment.out.name
          );
        };
      };
    }
    // clusterRoles
    // nsRoles
    // admissionClusterRoles
    // admissionNsRoles;
}
