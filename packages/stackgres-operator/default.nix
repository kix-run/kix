# StackGres Operator package — stackgres.io/operator v1.16.3.
#
# PostgreSQL operator that manages SGCluster, SGInstanceProfile,
# SGPostgresConfig, SGPoolingConfig, SGObjectStorage, SGBackupConfig,
# SGDistributedLogs, SGShardedCluster, SGScript, and SGDbOps custom
# resources.
#
# Resources: ServiceAccount, ClusterRole (full CRD + core management),
#            ClusterRoleBinding, Deployment (operator),
#            Service (operator webhook), CRDs (10x),
#            ValidatingWebhookConfiguration,
#            MutatingWebhookConfiguration.
#
# The REST API deployment, admin UI, and associated services are managed
# by the operator itself at runtime via the SGConfig CR.
#
# CRDs include structural metadata only — full OpenAPI schemas are
# omitted for brevity. The operator itself enforces validation at
# admission time via the webhook configurations.

{
  scope,
  lib,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "stackgres-operator";
    "app.kubernetes.io/instance" = name;
  };

  operatorSelectorLabels = {
    app = name;
    "group" = "stackgres.io";
  };

  sgGroup = "stackgres.io";

  # Single source of truth for all StackGres CRD definitions.
  # Each entry produces a CRD resource and feeds the webhook + RBAC lists.
  #   webhook: whether to generate validating/mutating webhooks for this CRD.
  #   shortNames: short aliases for kubectl.
  #   specOverrides: deep-merged into crd.fromKind output (for irregular names).
  crdDefs = {
    sgCluster = {
      kind = "SGCluster";
      shortNames = [ "sgclu" ];
      webhook = true;
    };
    sgInstanceProfile = {
      kind = "SGInstanceProfile";
      shortNames = [ "sginp" ];
      webhook = true;
    };
    sgPostgresConfig = {
      kind = "SGPostgresConfig";
      shortNames = [ "sgpgc" ];
      specOverrides.spec.names = {
        singular = "sgpgconfig";
        plural = "sgpgconfigs";
      };
      webhook = true;
    };
    sgPoolingConfig = {
      kind = "SGPoolingConfig";
      shortNames = [ "sgpoc" ];
      specOverrides.spec.names = {
        singular = "sgpoolconfig";
        plural = "sgpoolconfigs";
      };
      webhook = true;
    };
    sgBackupConfig = {
      kind = "SGBackupConfig";
      shortNames = [ "sgbac" ];
      webhook = false;
    };
    sgObjectStorage = {
      kind = "SGObjectStorage";
      shortNames = [ "sgobs" ];
      webhook = true;
    };
    sgDistributedLogs = {
      kind = "SGDistributedLogs";
      shortNames = [ "sgdil" ];
      specOverrides.spec.names.plural = "sgdistributedlogs";
      webhook = true;
    };
    sgShardedCluster = {
      kind = "SGShardedCluster";
      shortNames = [ "sgshr" ];
      webhook = true;
    };
    sgScript = {
      kind = "SGScript";
      shortNames = [ "sgscr" ];
      webhook = true;
    };
    sgDbOps = {
      kind = "SGDbOps";
      shortNames = [ "sgdbo" ];
      specOverrides.spec.names.plural = "sgdbops";
      webhook = true;
    };
    sgBackup = {
      kind = "SGBackup";
      shortNames = [ "sgbkp" ];
      webhook = true;
    };
    sgShardedBackup = {
      kind = "SGShardedBackup";
      shortNames = [ "sgsbk" ];
      webhook = true;
    };
    sgShardedDbOps = {
      kind = "SGShardedDbOps";
      shortNames = [ "sgsdo" ];
      specOverrides.spec.names.plural = "sgshardeddbops";
      webhook = true;
    };
    sgStream = {
      kind = "SGStream";
      shortNames = [ "sgstr" ];
      webhook = true;
    };
    sgConfig = {
      kind = "SGConfig";
      shortNames = [ "sgcfg" ];
      webhook = false;
    };
  };

  # Build the CRD spec input for a given crdDef entry.
  mkCrdInput =
    def:
    scope.crd.fromKind def.kind (
      lib.recursiveUpdate { spec.group = sgGroup; } (def.specOverrides or { })
    )
    |> scope.crd.withShortNames def.shortNames;

  # Extract resolved names (singular/plural) from each CRD definition.
  # Used to derive webhook and RBAC lists.
  resolvedNames = lib.mapAttrs (_: def: (mkCrdInput def).spec.names) crdDefs;

  # Webhook resources — derived from CRD definitions that have webhook = true.
  webhookResources = lib.mapAttrsToList (attr: def: {
    inherit (resolvedNames.${attr}) singular plural;
  }) (lib.filterAttrs (_: def: def.webhook) crdDefs);

  # RBAC CRD names — "plural.group" for every CRD.
  sgCrdNames = lib.mapAttrsToList (_: names: "${names.plural}.${sgGroup}") resolvedNames;

  mkValidatingWebhook = operatorServiceName: res: {
    name = "${res.singular}.validating-webhook.stackgres.io";
    admissionReviewVersions = [ "v1" ];
    sideEffects = "None";
    failurePolicy = "Fail";
    matchPolicy = "Equivalent";
    timeoutSeconds = 10;
    clientConfig.service = {
      name = operatorServiceName;
      namespace = scope.namespaceName;
      path = "/stackgres/validation/${res.singular}";
    };
    rules = [
      {
        apiGroups = [ "stackgres.io" ];
        apiVersions = [ "*" ];
        operations = [
          "CREATE"
          "UPDATE"
          "DELETE"
        ];
        resources = [ res.plural ];
        scope = "*";
      }
    ];
  };

  mkMutatingWebhook = operatorServiceName: res: {
    name = "${res.singular}.mutating-webhook.stackgres.io";
    admissionReviewVersions = [ "v1" ];
    sideEffects = "None";
    failurePolicy = "Fail";
    matchPolicy = "Equivalent";
    reinvocationPolicy = "Never";
    timeoutSeconds = 10;
    clientConfig.service = {
      name = operatorServiceName;
      namespace = scope.namespaceName;
      path = "/stackgres/mutation/${res.singular}";
    };
    rules = [
      {
        apiGroups = [ "stackgres.io" ];
        apiVersions = [ "*" ];
        operations = [
          "CREATE"
          "UPDATE"
        ];
        resources = [ res.plural ];
        scope = "*";
      }
    ];
  };

in
{
  meta = {
    version = "1.16.3";
  };

  options = {
    operator.image.repository = lib.mkOption {
      type = lib.types.str;
      default = "quay.io/stackgres/operator";
    };
    operator.image.tag = lib.mkOption {
      type = lib.types.str;
      default = "1.16.3";
    };
    restapi.image.repository = lib.mkOption {
      type = lib.types.str;
      default = "quay.io/stackgres/restapi";
    };
    restapi.image.tag = lib.mkOption {
      type = lib.types.str;
      default = "1.16.3";
    };
    adminui.image.repository = lib.mkOption {
      type = lib.types.str;
      default = "quay.io/stackgres/admin-ui";
    };
    adminui.image.tag = lib.mkOption {
      type = lib.types.str;
      default = "1.16.3";
    };
    operator.resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "512Mi";
        };
        limits = {
          cpu = "2";
          memory = "4Gi";
        };
      };
    };
    restapi.resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "100m";
          memory = "256Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
      };
    };
    authentication.user = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };
    grafana.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    collector.enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      operatorLabels = operatorSelectorLabels // {
        version = config.operator.image.tag;
      };
    in
    {

      # ===== ServiceAccount =====

      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = name;
        labels = selectorLabels;
      };

      # ===== ClusterRole =====

      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = name;
        labels = selectorLabels;
        extra.rules = [
          # Core + apps + rbac + batch resources the operator manages
          {
            apiGroups = [
              ""
              "apps"
              "extensions"
              "rbac.authorization.k8s.io"
              "batch"
            ];
            resources = [
              "pods"
              "pods/exec"
              "pods/log"
              "services"
              "endpoints"
              "endpoints/restricted"
              "persistentvolumeclaims"
              "configmaps"
              "secrets"
              "deployments"
              "statefulsets"
              "serviceaccounts"
              "namespaces"
              "roles"
              "rolebindings"
              "events"
              "cronjobs"
              "jobs"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
              "delete"
              "deletecollection"
              "patch"
            ];
          }
          # Finalizers
          {
            apiGroups = [
              ""
              "apps"
              "batch"
            ];
            resources = [
              "statefulsets/finalizers"
              "persistentvolumeclaims/finalizers"
              "deployments/finalizers"
              "services/finalizers"
              "endpoints/finalizers"
              "cronjobs/finalizers"
              "jobs/finalizers"
              "pods/finalizers"
            ];
            verbs = [ "update" ];
          }
          # Namespace read
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [
              "get"
              "list"
            ];
          }
          # Admissionregistration — scoped to own resources
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resourceNames = [ name ];
            resources = [
              "mutatingwebhookconfigurations"
              "validatingwebhookconfigurations"
            ];
            verbs = [
              "get"
              "patch"
            ];
          }
          # CRD read — scoped to SG CRDs
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resourceNames = sgCrdNames;
            resources = [ "customresourcedefinitions" ];
            verbs = [ "get" ];
          }
          # CRD list
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [ "list" ];
          }
          # CRD create
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [ "create" ];
          }
          # CRD update — scoped to SG CRDs
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resourceNames = sgCrdNames;
            resources = [ "customresourcedefinitions" ];
            verbs = [
              "patch"
              "update"
            ];
          }
          # Prometheus CRD read
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resourceNames = [ "prometheuses.monitoring.coreos.com" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [ "get" ];
          }
          # VPA
          {
            apiGroups = [ "autoscaling.k8s.io" ];
            resources = [ "verticalpodautoscalers" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
              "delete"
              "patch"
            ];
          }
          # KEDA
          {
            apiGroups = [ "keda.sh" ];
            resources = [
              "scaledobjects"
              "triggerauthentications"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
              "delete"
              "patch"
            ];
          }
          # Prometheus Operator — servicemonitors and podmonitors management
          {
            apiGroups = [ "monitoring.coreos.com" ];
            resources = [
              "servicemonitors"
              "podmonitors"
            ];
            verbs = [
              "list"
              "get"
              "create"
              "delete"
              "update"
              "patch"
            ];
          }
          # Prometheus Operator — read access
          {
            apiGroups = [ "monitoring.coreos.com" ];
            resources = [
              "prometheus"
              "prometheuses"
              "podmonitors"
            ];
            verbs = [
              "list"
              "get"
            ];
          }
          # Knative
          {
            apiGroups = [ "serving.knative.dev" ];
            resources = [ "services" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
              "delete"
              "patch"
            ];
          }
          # ShardingSphere
          {
            apiGroups = [ "shardingsphere.apache.org" ];
            resources = [ "computenodes" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
              "delete"
              "patch"
            ];
          }
          # Volume Snapshots
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [ "volumesnapshots" ];
            verbs = [
              "list"
              "get"
              "watch"
              "create"
            ];
          }
          # StackGres CRDs — full control (derived from crdDefs)
          {
            apiGroups = [ "stackgres.io" ];
            resources = lib.mapAttrsToList (_: names: names.plural) resolvedNames;
            verbs = [
              "create"
              "watch"
              "list"
              "get"
              "update"
              "patch"
              "delete"
            ];
          }
          # StackGres CRDs — status and finalizers (derived from crdDefs)
          {
            apiGroups = [ "stackgres.io" ];
            resources =
              (map (p: "${p}/status") (lib.mapAttrsToList (_: names: names.plural) resolvedNames))
              ++ (map (p: "${p}/finalizers") (lib.mapAttrsToList (_: names: names.plural) resolvedNames));
            verbs = [ "update" ];
          }
          # Storage
          {
            apiGroups = [ "storage.k8s.io" ];
            resources = [ "storageclasses" ];
            verbs = [
              "get"
              "list"
            ];
          }
        ];
      };

      # ===== ClusterRoleBinding =====

      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = name;
        labels = selectorLabels;
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

      # ===== Deployment (operator) =====

      operatorDeployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = name;
        labels = operatorLabels;
        spec = {
          replicas = 1;
          selector.matchLabels = operatorSelectorLabels;
          template = {
            metadata.labels = operatorSelectorLabels;
            spec = {
              serviceAccountName = self.serviceAccount.out.name;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 1000;
                runAsGroup = 1000;
                fsGroup = 1000;
              };
              containers = [
                {
                  name = name;
                  image = "${config.operator.image.repository}:${config.operator.image.tag}";
                  imagePullPolicy = "IfNotPresent";
                  env = [
                    {
                      name = "OPERATOR_NAME";
                      value = name;
                    }
                    {
                      name = "OPERATOR_NAMESPACE";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.namespace";
                      };
                    }
                    {
                      name = "OPERATOR_SERVICE_ACCOUNT";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "spec.serviceAccountName";
                      };
                    }
                    {
                      name = "OPERATOR_POD_NAME";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "metadata.name";
                      };
                    }
                    {
                      name = "OPERATOR_IP";
                      valueFrom.fieldRef = {
                        apiVersion = "v1";
                        fieldPath = "status.podIP";
                      };
                    }
                    {
                      name = "OPERATOR_IMAGE_VERSION";
                      value = config.operator.image.tag;
                    }
                    {
                      name = "OPERATOR_NATIVE_IMAGE_VERSION";
                      value = config.operator.image.tag;
                    }
                    {
                      name = "OPERATOR_JVM_IMAGE_VERSION";
                      value = "${config.operator.image.tag}-jvm";
                    }
                    {
                      name = "SG_CONTAINER_REGISTRY";
                      value = "quay.io";
                    }
                    {
                      name = "SG_IMAGE_PULL_POLICY";
                      value = "IfNotPresent";
                    }
                    {
                      name = "INSTALL_CRDS";
                      value = "true";
                    }
                    {
                      name = "INSTALL_WEBHOOKS";
                      value = "true";
                    }
                    {
                      name = "INSTALL_CONVERSION_WEBHOOKS";
                      value = "true";
                    }
                    {
                      name = "INSTALL_CERTS";
                      value = "true";
                    }
                    {
                      name = "INSTALL_CONFIG";
                      value = "true";
                    }
                    {
                      name = "CLUSTER_ROLE_DISABLED";
                      value = "false";
                    }
                    {
                      name = "DISABLE_RECONCILIATION";
                      value = "false";
                    }
                    {
                      name = "WAIT_CRDS_UPGRADE";
                      value = "false";
                    }
                    {
                      name = "EXTENSIONS_REPOSITORY_URLS";
                      value = "https://extensions.stackgres.io/postgres/repository";
                    }
                    {
                      name = "PROMETHEUS_AUTOBIND";
                      value = "true";
                    }
                    {
                      name = "GRAFANA_EMBEDDED";
                      value = if config.grafana.enabled then "true" else "false";
                    }
                    {
                      name = "SGCONFIG_NAMESPACE";
                      value = scope.namespaceName;
                    }
                  ];
                  ports = [
                    {
                      name = "http";
                      containerPort = 8080;
                      protocol = "TCP";
                    }
                    {
                      name = "https";
                      containerPort = 8443;
                      protocol = "TCP";
                    }
                  ];
                  livenessProbe = {
                    httpGet = {
                      path = "/q/health/live";
                      port = 8080;
                      scheme = "HTTP";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 60;
                    timeoutSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/q/health/ready";
                      port = 8080;
                      scheme = "HTTP";
                    };
                    periodSeconds = 2;
                    timeoutSeconds = 1;
                    failureThreshold = 3;
                  };
                  resources = config.operator.resources;
                  volumeMounts = [
                    {
                      name = "operator-certs";
                      mountPath = "/etc/operator/certs";
                      readOnly = true;
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "operator-certs";
                  secret = {
                    secretName = "${name}-certs";
                    optional = true;
                    defaultMode = 420;
                  };
                }
              ];
            };
          };
        };
      };

      # ===== Service (operator — webhook endpoint on 443) =====

      operatorService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = name;
        spec = {
          type = "ClusterIP";
          selector = {
            app = name;
          };
          ports = [
            {
              name = "https";
              port = 443;
              targetPort = "https";
              protocol = "TCP";
            }
          ];
        };
      };

      # ===== CRDs =====
      # Built from crdDefs (single source of truth). Structural minimum
      # only — full OpenAPI schemas are enforced by the operator webhook.

      crds = lib.mapAttrs (_: def: scope.mkCRD (mkCrdInput def)) crdDefs;

      # ===== ValidatingWebhookConfiguration =====

      validatingWebhook = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingWebhookConfiguration";
        name = name;
        annotations = {
          # The operator will inject the caBundle at startup.
          "stackgres.io/operator-version" = config.operator.image.tag;
        };
        extra.webhooks = map (mkValidatingWebhook self.operatorService.out.name) webhookResources;
      };

      # ===== MutatingWebhookConfiguration =====

      mutatingWebhook = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "MutatingWebhookConfiguration";
        name = name;
        annotations = {
          "stackgres.io/operator-version" = config.operator.image.tag;
        };
        extra.webhooks = map (mkMutatingWebhook self.operatorService.out.name) webhookResources;
      };

      # ===== Entry point =====

      root = {
        resource = self.operatorDeployment;
        requires = [
          self.serviceAccount
          self.clusterRole
          self.clusterRoleBinding
          self.operatorService
          self.validatingWebhook
          self.mutatingWebhook
        ]
        ++ lib.attrValues self.crds;
      };
    };
}
