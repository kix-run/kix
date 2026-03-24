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

  # All SG resource types that need webhooks
  webhookResources = [
    {
      singular = "sgcluster";
      plural = "sgclusters";
    }
    {
      singular = "sgpgconfig";
      plural = "sgpgconfigs";
    }
    {
      singular = "sgpoolconfig";
      plural = "sgpoolconfigs";
    }
    {
      singular = "sginstanceprofile";
      plural = "sginstanceprofiles";
    }
    {
      singular = "sgbackup";
      plural = "sgbackups";
    }
    {
      singular = "sgdistributedlogs";
      plural = "sgdistributedlogs";
    }
    {
      singular = "sgdbops";
      plural = "sgdbops";
    }
    {
      singular = "sgobjectstorage";
      plural = "sgobjectstorages";
    }
    {
      singular = "sgscript";
      plural = "sgscripts";
    }
    {
      singular = "sgshardedcluster";
      plural = "sgshardedclusters";
    }
    {
      singular = "sgshardedbackup";
      plural = "sgshardedbackups";
    }
    {
      singular = "sgshardeddbops";
      plural = "sgshardeddbops";
    }
    {
      singular = "sgstream";
      plural = "sgstreams";
    }
  ];

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
        extra.rules =
          let
            sgCrdNames = [
              "sgconfigs.stackgres.io"
              "sgclusters.stackgres.io"
              "sginstanceprofiles.stackgres.io"
              "sgpgconfigs.stackgres.io"
              "sgpoolconfigs.stackgres.io"
              "sgbackups.stackgres.io"
              "sgbackupconfigs.stackgres.io"
              "sgobjectstorages.stackgres.io"
              "sgdbops.stackgres.io"
              "sgdistributedlogs.stackgres.io"
              "sgshardedclusters.stackgres.io"
              "sgshardedbackups.stackgres.io"
              "sgshardeddbops.stackgres.io"
              "sgscripts.stackgres.io"
              "sgstreams.stackgres.io"
            ];
          in
          [
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
            # StackGres CRDs — full control
            {
              apiGroups = [ "stackgres.io" ];
              resources = [
                "sgclusters"
                "sgpgconfigs"
                "sginstanceprofiles"
                "sgpoolconfigs"
                "sgbackupconfigs"
                "sgbackups"
                "sgdistributedlogs"
                "sgdbops"
                "sgobjectstorages"
                "sgscripts"
                "sgshardedclusters"
                "sgshardedbackups"
                "sgshardeddbops"
                "sgstreams"
                "sgconfigs"
              ];
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
            # StackGres CRDs — status and finalizers
            {
              apiGroups = [ "stackgres.io" ];
              resources = [
                "sgconfigs/status"
                "sgclusters/status"
                "sgdistributedlogs/status"
                "sgclusters/finalizers"
                "sgpgconfigs/finalizers"
                "sginstanceprofiles/finalizers"
                "sgpoolconfigs/finalizers"
                "sgbackupconfigs/finalizers"
                "sgbackups/finalizers"
                "sgdistributedlogs/finalizers"
                "sgdbops/finalizers"
                "sgobjectstorages/finalizers"
                "sgscripts/finalizers"
                "sgshardedclusters/finalizers"
                "sgshardedbackups/finalizers"
                "sgshardeddbops/finalizers"
                "sgstreams/finalizers"
                "sgconfigs/finalizers"
              ];
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
      # Structural minimum only — full OpenAPI schemas are enforced by
      # the operator webhook at admission time.

      crds = {
        sgCluster = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgcluster";
          plural = "sgclusters";
          kind = "SGCluster";
          listKind = "SGClusterList";
          shortNames = [ "sgclu" ];
        };

        sgInstanceProfile = scope.mkCRD {
          group = "stackgres.io";
          singular = "sginstanceprofile";
          plural = "sginstanceprofiles";
          kind = "SGInstanceProfile";
          listKind = "SGInstanceProfileList";
          shortNames = [ "sginp" ];
        };

        sgPostgresConfig = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgpgconfig";
          plural = "sgpgconfigs";
          kind = "SGPostgresConfig";
          listKind = "SGPostgresConfigList";
          shortNames = [ "sgpgc" ];
        };

        sgPoolingConfig = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgpoolconfig";
          plural = "sgpoolconfigs";
          kind = "SGPoolingConfig";
          listKind = "SGPoolingConfigList";
          shortNames = [ "sgpoc" ];
        };

        sgBackupConfig = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgbackupconfig";
          plural = "sgbackupconfigs";
          kind = "SGBackupConfig";
          listKind = "SGBackupConfigList";
          shortNames = [ "sgbac" ];
        };

        sgObjectStorage = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgobjectstorage";
          plural = "sgobjectstorages";
          kind = "SGObjectStorage";
          listKind = "SGObjectStorageList";
          shortNames = [ "sgobs" ];
        };

        sgDistributedLogs = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgdistributedlogs";
          plural = "sgdistributedlogs";
          kind = "SGDistributedLogs";
          listKind = "SGDistributedLogsList";
          shortNames = [ "sgdil" ];
        };

        sgShardedCluster = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgshardedcluster";
          plural = "sgshardedclusters";
          kind = "SGShardedCluster";
          listKind = "SGShardedClusterList";
          shortNames = [ "sgshr" ];
        };

        sgScript = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgscript";
          plural = "sgscripts";
          kind = "SGScript";
          listKind = "SGScriptList";
          shortNames = [ "sgscr" ];
        };

        sgDbOps = scope.mkCRD {
          group = "stackgres.io";
          singular = "sgdbops";
          plural = "sgdbops";
          kind = "SGDbOps";
          listKind = "SGDbOpsList";
          shortNames = [ "sgdbo" ];
        };
      };

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

      main = {
        resource = self.operatorDeployment;
        requires = [
          self.serviceAccount
          self.clusterRole
          self.clusterRoleBinding
          self.operatorService
          self.crds.sgCluster
          self.crds.sgInstanceProfile
          self.crds.sgPostgresConfig
          self.crds.sgPoolingConfig
          self.crds.sgBackupConfig
          self.crds.sgObjectStorage
          self.crds.sgDistributedLogs
          self.crds.sgShardedCluster
          self.crds.sgScript
          self.crds.sgDbOps
          self.validatingWebhook
          self.mutatingWebhook
        ];
      };
    };
}
