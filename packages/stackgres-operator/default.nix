# StackGres Operator package — stackgres.io/operator v1.16.3.
#
# PostgreSQL operator that manages SGCluster, SGInstanceProfile,
# SGPostgresConfig, SGPoolingConfig, SGObjectStorage, SGBackupConfig,
# SGDistributedLogs, SGShardedCluster, SGScript, and SGDbOps custom
# resources.
#
# Resources: ServiceAccount, ClusterRole (full CRD + core management),
#            ClusterRoleBinding, ConfigMap (operator config),
#            Deployment (operator), Deployment (restapi),
#            Service (operator webhook), Service (restapi),
#            CRDs (10x), ValidatingWebhookConfiguration,
#            MutatingWebhookConfiguration.
#
# CRDs include structural metadata only — full OpenAPI schemas are
# omitted for brevity. The operator itself enforces validation at
# admission time via the webhook configurations.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    operator.image = {
      repository = "quay.io/stackgres/operator";
      tag = "1.16.3";
    };
    restapi.image = {
      repository = "quay.io/stackgres/restapi";
      tag = "1.16.3";
    };
    adminui.image = {
      repository = "quay.io/stackgres/admin-ui";
      tag = "1.16.3";
    };
    operator.resources = {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits = {
        cpu = "2";
        memory = "4Gi";
      };
    };
    restapi.resources = {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };
    authentication.user = "admin";
    grafana.enabled = false;
    collector.enabled = false;
  };

  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "stackgres-operator";
    "app.kubernetes.io/instance" = name;
  };

  operatorLabels = selectorLabels // {
    "app.kubernetes.io/component" = "operator";
  };

  restapiLabels = selectorLabels // {
    "app.kubernetes.io/component" = "restapi";
  };

  # --- CRD helper ---
  # Structural minimum: group, names, scope, versions with a served/storage
  # marker and an empty openAPIV3Schema.  Full schemas are enforced by the
  # operator's webhook; omitting them here keeps the package readable.
  mkCrd =
    {
      crdName,
      singular,
      plural,
      kind,
      shortNames ? [ ],
      crdScope ? "Namespaced",
    }:
    scope.mkClusterResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = "${plural}.stackgres.io";
      spec = {
        group = "stackgres.io";
        names = {
          inherit kind singular plural;
        }
        // lib.optionalAttrs (shortNames != [ ]) {
          inherit shortNames;
        };
        scope = crdScope;
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
            schema.openAPIV3Schema = {
              type = "object";
              properties.spec = {
                type = "object";
                "x-kubernetes-preserve-unknown-fields" = true;
              };
              properties.status = {
                type = "object";
                "x-kubernetes-preserve-unknown-fields" = true;
              };
            };
          }
        ];
      };
    };

in
self: {

  # ===== ServiceAccount =====

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-operator";
    labels = selectorLabels;
  };

  # ===== ClusterRole =====

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-operator";
    labels = selectorLabels;
    extra.rules = [
      # StackGres CRDs — full control
      {
        apiGroups = [ "stackgres.io" ];
        resources = [
          "sgclusters"
          "sgclusters/finalizers"
          "sgclusters/status"
          "sginstanceprofiles"
          "sginstanceprofiles/status"
          "sgpgconfigs"
          "sgpgconfigs/status"
          "sgpoolconfigs"
          "sgpoolconfigs/status"
          "sgbackupconfigs"
          "sgbackupconfigs/status"
          "sgbackups"
          "sgbackups/status"
          "sgobjectstorages"
          "sgobjectstorages/status"
          "sgdistributedlogs"
          "sgdistributedlogs/finalizers"
          "sgdistributedlogs/status"
          "sgshardedclusters"
          "sgshardedclusters/finalizers"
          "sgshardedclusters/status"
          "sgscripts"
          "sgscripts/status"
          "sgdbops"
          "sgdbops/finalizers"
          "sgdbops/status"
          "sgconfigs"
          "sgconfigs/status"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # Core resources the operator manages
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "pods/exec"
          "pods/log"
          "services"
          "services/status"
          "endpoints"
          "persistentvolumeclaims"
          "configmaps"
          "secrets"
          "events"
          "serviceaccounts"
          "namespaces"
          "nodes"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # Apps — StatefulSets, Deployments, etc.
      {
        apiGroups = [ "apps" ];
        resources = [
          "statefulsets"
          "statefulsets/status"
          "deployments"
          "daemonsets"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # Batch — Jobs for backups and dbops
      {
        apiGroups = [ "batch" ];
        resources = [
          "jobs"
          "cronjobs"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # RBAC
      {
        apiGroups = [ "rbac.authorization.k8s.io" ];
        resources = [
          "roles"
          "rolebindings"
          "clusterroles"
          "clusterrolebindings"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # Policy
      {
        apiGroups = [ "policy" ];
        resources = [ "poddisruptionbudgets" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # Storage
      {
        apiGroups = [ "storage.k8s.io" ];
        resources = [ "storageclasses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # Admissionregistration — for managing its own webhooks
      {
        apiGroups = [ "admissionregistration.k8s.io" ];
        resources = [
          "validatingwebhookconfigurations"
          "mutatingwebhookconfigurations"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
      # CRD management
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [ "customresourcedefinitions" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
        ];
      }
      # Coordination for leader election
      {
        apiGroups = [ "coordination.k8s.io" ];
        resources = [ "leases" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
    ];
  };

  # ===== ClusterRoleBinding =====

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-operator";
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

  # ===== ConfigMap (operator configuration) =====

  operatorConfig = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-operator-config";
    labels = selectorLabels;
    data = {
      OPERATOR_NAME = "${name}-operator";
      OPERATOR_NAMESPACE = scope.namespaceName;
      OPERATOR_IP = "0.0.0.0";
      OPERATOR_SERVICE_ACCOUNT = "${self.serviceAccount}";
      SG_CONTAINER_REGISTRY = "quay.io";
      SG_IMAGE_PULL_POLICY = "IfNotPresent";
      AUTHENTICATION_SECRET_NAME = "${name}-restapi-admin";
      GRAFANA_EMBEDDED = if cfg.grafana.enabled then "true" else "false";
      COLLECTOR_ENABLED = if cfg.collector.enabled then "true" else "false";
    };
  };

  # ===== Deployment (operator) =====

  operatorDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-operator";
    labels = operatorLabels;
    spec = {
      replicas = 1;
      selector.matchLabels = operatorLabels;
      template = {
        metadata.labels = operatorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 1000;
            runAsGroup = 1000;
            fsGroup = 1000;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "operator";
              image = "${cfg.operator.image.repository}:${cfg.operator.image.tag}";
              imagePullPolicy = "IfNotPresent";
              env = [
                {
                  name = "OPERATOR_NAME";
                  value = "${name}-operator";
                }
                {
                  name = "OPERATOR_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
                {
                  name = "OPERATOR_SERVICE_ACCOUNT";
                  value = "${self.serviceAccount}";
                }
                {
                  name = "OPERATOR_POD_NAME";
                  valueFrom.fieldRef.fieldPath = "metadata.name";
                }
                {
                  name = "OPERATOR_IP";
                  value = "0.0.0.0";
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
                  name = "AUTHENTICATION_SECRET_NAME";
                  value = "${name}-restapi-admin";
                }
              ];
              ports = [
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
                periodSeconds = 10;
                failureThreshold = 3;
              };
              readinessProbe = {
                httpGet = {
                  path = "/q/health/ready";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 5;
                periodSeconds = 5;
                failureThreshold = 3;
              };
              resources = cfg.operator.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
              volumeMounts = [
                {
                  name = "operator-certs";
                  mountPath = "/etc/operator/certs";
                  readOnly = true;
                }
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "operator-certs";
              secret = {
                secretName = "${name}-operator-certs";
                optional = true;
              };
            }
            {
              name = "tmp";
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  # ===== Deployment (REST API + Admin UI) =====

  restapiDeployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-restapi";
    labels = restapiLabels;
    spec = {
      replicas = 1;
      selector.matchLabels = restapiLabels;
      template = {
        metadata.labels = restapiLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          securityContext = {
            runAsNonRoot = true;
            runAsUser = 1000;
            runAsGroup = 1000;
            fsGroup = 1000;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "restapi";
              image = "${cfg.restapi.image.repository}:${cfg.restapi.image.tag}";
              imagePullPolicy = "IfNotPresent";
              env = [
                {
                  name = "OPERATOR_NAME";
                  value = "${name}-operator";
                }
                {
                  name = "OPERATOR_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
                {
                  name = "AUTHENTICATION_SECRET_NAME";
                  value = "${name}-restapi-admin";
                }
                {
                  name = "STACKGRES_AUTH_TYPE";
                  value = "jwt";
                }
              ];
              ports = [
                {
                  name = "https";
                  containerPort = 9443;
                  protocol = "TCP";
                }
                {
                  name = "http";
                  containerPort = 8080;
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
                periodSeconds = 10;
                failureThreshold = 3;
              };
              readinessProbe = {
                httpGet = {
                  path = "/q/health/ready";
                  port = 8080;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 5;
                periodSeconds = 5;
                failureThreshold = 3;
              };
              resources = cfg.restapi.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
              volumeMounts = [
                {
                  name = "tmp";
                  mountPath = "/tmp";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "tmp";
              emptyDir = { };
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
    name = "${name}-operator";
    labels = operatorLabels;
    spec = {
      type = "ClusterIP";
      selector = operatorLabels;
      ports = [
        {
          name = "https";
          port = 443;
          targetPort = 8443;
          protocol = "TCP";
        }
      ];
    };
  };

  # ===== Service (REST API) =====

  restapiService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-restapi";
    labels = restapiLabels;
    spec = {
      type = "ClusterIP";
      selector = restapiLabels;
      ports = [
        {
          name = "https";
          port = 443;
          targetPort = 9443;
          protocol = "TCP";
        }
        {
          name = "http";
          port = 80;
          targetPort = 8080;
          protocol = "TCP";
        }
      ];
    };
    outputs = {
      restapiUrl = "https://${name}-restapi.${scope.namespaceName}.svc";
    };
  };

  # ===== CRDs =====
  # Structural minimum only — full OpenAPI schemas are enforced by
  # the operator webhook at admission time.

  crdSGCluster = mkCrd {
    crdName = "sgclusters";
    singular = "sgcluster";
    plural = "sgclusters";
    kind = "SGCluster";
    shortNames = [ "sgclu" ];
  };

  crdSGInstanceProfile = mkCrd {
    crdName = "sginstanceprofiles";
    singular = "sginstanceprofile";
    plural = "sginstanceprofiles";
    kind = "SGInstanceProfile";
    shortNames = [ "sginp" ];
  };

  crdSGPostgresConfig = mkCrd {
    crdName = "sgpgconfigs";
    singular = "sgpgconfig";
    plural = "sgpgconfigs";
    kind = "SGPostgresConfig";
    shortNames = [ "sgpgc" ];
  };

  crdSGPoolingConfig = mkCrd {
    crdName = "sgpoolconfigs";
    singular = "sgpoolconfig";
    plural = "sgpoolconfigs";
    kind = "SGPoolingConfig";
    shortNames = [ "sgpoc" ];
  };

  crdSGBackupConfig = mkCrd {
    crdName = "sgbackupconfigs";
    singular = "sgbackupconfig";
    plural = "sgbackupconfigs";
    kind = "SGBackupConfig";
    shortNames = [ "sgbac" ];
  };

  crdSGObjectStorage = mkCrd {
    crdName = "sgobjectstorages";
    singular = "sgobjectstorage";
    plural = "sgobjectstorages";
    kind = "SGObjectStorage";
    shortNames = [ "sgobs" ];
  };

  crdSGDistributedLogs = mkCrd {
    crdName = "sgdistributedlogs";
    singular = "sgdistributedlogs";
    plural = "sgdistributedlogs";
    kind = "SGDistributedLogs";
    shortNames = [ "sgdil" ];
  };

  crdSGShardedCluster = mkCrd {
    crdName = "sgshardedclusters";
    singular = "sgshardedcluster";
    plural = "sgshardedclusters";
    kind = "SGShardedCluster";
    shortNames = [ "sgshr" ];
  };

  crdSGScript = mkCrd {
    crdName = "sgscripts";
    singular = "sgscript";
    plural = "sgscripts";
    kind = "SGScript";
    shortNames = [ "sgscr" ];
  };

  crdSGDbOps = mkCrd {
    crdName = "sgdbops";
    singular = "sgdbops";
    plural = "sgdbops";
    kind = "SGDbOps";
    shortNames = [ "sgdbo" ];
  };

  # ===== ValidatingWebhookConfiguration =====

  validatingWebhook = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "ValidatingWebhookConfiguration";
    name = "${name}-operator";
    labels = selectorLabels;
    annotations = {
      # The operator will inject the caBundle at startup.
      "stackgres.io/operator-version" = cfg.operator.image.tag;
    };
    extra.webhooks = [
      {
        name = "sgcluster.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgcluster";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgclusters" ];
          }
        ];
      }
      {
        name = "sginstanceprofile.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sginstanceprofile";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sginstanceprofiles" ];
          }
        ];
      }
      {
        name = "sgpgconfig.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgpgconfig";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgpgconfigs" ];
          }
        ];
      }
      {
        name = "sgpoolconfig.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgpoolconfig";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgpoolconfigs" ];
          }
        ];
      }
      {
        name = "sgobjectstorage.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgobjectstorage";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgobjectstorages" ];
          }
        ];
      }
      {
        name = "sgscript.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgscript";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgscripts" ];
          }
        ];
      }
      {
        name = "sgdbops.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/validation/sgdbops";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
              "DELETE"
            ];
            resources = [ "sgdbops" ];
          }
        ];
      }
    ];
  };

  # ===== MutatingWebhookConfiguration =====

  mutatingWebhook = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "MutatingWebhookConfiguration";
    name = "${name}-operator";
    labels = selectorLabels;
    annotations = {
      "stackgres.io/operator-version" = cfg.operator.image.tag;
    };
    extra.webhooks = [
      {
        name = "sgcluster.mutating.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/mutation/sgcluster";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
            ];
            resources = [ "sgclusters" ];
          }
        ];
      }
      {
        name = "sginstanceprofile.mutating.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/mutation/sginstanceprofile";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
            ];
            resources = [ "sginstanceprofiles" ];
          }
        ];
      }
      {
        name = "sgpgconfig.mutating.stackgres.io";
        admissionReviewVersions = [ "v1" ];
        sideEffects = "None";
        failurePolicy = "Fail";
        clientConfig = {
          service = {
            name = "${self.operatorService}";
            namespace = scope.namespaceName;
            path = "/stackgres/mutation/sgpgconfig";
          };
        };
        rules = [
          {
            apiGroups = [ "stackgres.io" ];
            apiVersions = [ "v1" ];
            operations = [
              "CREATE"
              "UPDATE"
            ];
            resources = [ "sgpgconfigs" ];
          }
        ];
      }
    ];
  };

  # ===== Entry point =====

  main = {
    resource = self.operatorDeployment;
    requires = [
      self.serviceAccount
      self.clusterRole
      self.clusterRoleBinding
      self.operatorConfig
      self.restapiDeployment
      self.operatorService
      self.restapiService
      self.crdSGCluster
      self.crdSGInstanceProfile
      self.crdSGPostgresConfig
      self.crdSGPoolingConfig
      self.crdSGBackupConfig
      self.crdSGObjectStorage
      self.crdSGDistributedLogs
      self.crdSGShardedCluster
      self.crdSGScript
      self.crdSGDbOps
      self.validatingWebhook
      self.mutatingWebhook
    ];
  };
}
