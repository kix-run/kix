# CDI (Containerized Data Importer) package.
#
# Deploys the cdi-operator which manages CDI components (cdi-apiserver,
# cdi-controller/uploadcontroller, cdi-uploadproxy) via the CDI custom resource.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Service (metrics),
#            Deployment (cdi-operator), CDI CR, CRDs.
#
# main = Deployment (cdi-operator)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "quay.io/kubevirt/cdi-operator";
      tag = "v1.62.0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    resources = {
      requests = {
        cpu = "100m";
        memory = "150Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "cdi";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "cdi-operator";
  };

in
self: {

  # --- ServiceAccount ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${name}-operator";
    labels = selectorLabels;
  };

  # --- ClusterRole ---
  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${name}-operator";
    labels = selectorLabels;
    extra.rules = [
      # CDI resources
      {
        apiGroups = [ "cdi.kubevirt.io" ];
        resources = [
          "cdis"
          "cdis/status"
          "cdis/finalizers"
          "datavolumes"
          "datavolumes/status"
          "datavolumes/finalizers"
          "datasources"
          "datasources/status"
          "dataimportcrons"
          "dataimportcrons/status"
          "dataimportcrons/finalizers"
          "objecttransfers"
          "objecttransfers/status"
          "objecttransfers/finalizers"
          "storageprofiles"
          "storageprofiles/status"
          "volumeclonesources"
          "volumeimportsources"
          "volumeimportsources/status"
          "volumeuploadsources"
          "volumeuploadsources/status"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
          "deletecollection"
        ];
      }
      # Upload resources
      {
        apiGroups = [ "upload.cdi.kubevirt.io" ];
        resources = [ "uploadtokenrequests" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
        ];
      }
      # Core resources
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "pods/log"
          "services"
          "endpoints"
          "persistentvolumeclaims"
          "events"
          "configmaps"
          "secrets"
          "nodes"
          "serviceaccounts"
          "namespaces"
          "resourcequotas"
          "persistentvolumes"
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
      # Apps
      {
        apiGroups = [ "apps" ];
        resources = [
          "deployments"
          "daemonsets"
          "replicasets"
          "statefulsets"
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
      # Batch
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
          "clusterroles"
          "clusterrolebindings"
          "roles"
          "rolebindings"
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
      # CRDs
      {
        apiGroups = [ "apiextensions.k8s.io" ];
        resources = [
          "customresourcedefinitions"
          "customresourcedefinitions/status"
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
      # API services
      {
        apiGroups = [ "apiregistration.k8s.io" ];
        resources = [ "apiservices" ];
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
      # Admission webhooks
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
      # Storage
      {
        apiGroups = [ "storage.k8s.io" ];
        resources = [
          "storageclasses"
          "csidrivers"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # Coordination (leader election)
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
      # Snapshot support
      {
        apiGroups = [ "snapshot.storage.k8s.io" ];
        resources = [
          "volumesnapshots"
          "volumesnapshotcontents"
          "volumesnapshotclasses"
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
      # Networking (for uploadproxy ingress)
      {
        apiGroups = [ "networking.k8s.io" ];
        resources = [ "ingresses" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
      # Route (OpenShift compat)
      {
        apiGroups = [ "route.openshift.io" ];
        resources = [ "routes" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
        ];
      }
    ];
  };

  # --- ClusterRoleBinding ---
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

  # --- Service (operator metrics) ---
  metricsService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${name}-operator-metrics";
    labels = selectorLabels;
    spec = {
      type = "ClusterIP";
      selector = selectorLabels;
      ports = [
        {
          name = "metrics";
          port = 8080;
          protocol = "TCP";
          targetPort = 8080;
        }
      ];
    };
    outputs = {
      metricsPort = "8080";
    };
  };

  # --- Deployment (cdi-operator) ---
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${name}-operator";
    labels = selectorLabels;
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate = {
          maxSurge = 1;
          maxUnavailable = 0;
        };
      };
      template = {
        metadata = {
          labels = selectorLabels;
          annotations = {
            "kubectl.kubernetes.io/default-container" = "cdi-operator";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 30;
          securityContext = {
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          containers = [
            {
              name = "cdi-operator";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              env = [
                {
                  name = "DEPLOY_CLUSTER_RESOURCES";
                  value = "true";
                }
                {
                  name = "OPERATOR_VERSION";
                  value = cfg.image.tag;
                }
                {
                  name = "CONTROLLER_IMAGE";
                  value = "quay.io/kubevirt/cdi-controller:${cfg.image.tag}";
                }
                {
                  name = "IMPORTER_IMAGE";
                  value = "quay.io/kubevirt/cdi-importer:${cfg.image.tag}";
                }
                {
                  name = "CLONER_IMAGE";
                  value = "quay.io/kubevirt/cdi-cloner:${cfg.image.tag}";
                }
                {
                  name = "APISERVER_IMAGE";
                  value = "quay.io/kubevirt/cdi-apiserver:${cfg.image.tag}";
                }
                {
                  name = "UPLOAD_SERVER_IMAGE";
                  value = "quay.io/kubevirt/cdi-uploadserver:${cfg.image.tag}";
                }
                {
                  name = "UPLOAD_PROXY_IMAGE";
                  value = "quay.io/kubevirt/cdi-uploadproxy:${cfg.image.tag}";
                }
                {
                  name = "VERBOSITY";
                  value = "1";
                }
                {
                  name = "PULL_POLICY";
                  value = cfg.image.pullPolicy;
                }
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8080;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 8080;
                };
                initialDelaySeconds = 15;
                periodSeconds = 20;
                timeoutSeconds = 5;
              };
              readinessProbe = {
                httpGet = {
                  path = "/healthz";
                  port = 8080;
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
                timeoutSeconds = 5;
              };
              resources = cfg.resources;
              securityContext = {
                allowPrivilegeEscalation = false;
                capabilities.drop = [ "ALL" ];
                readOnlyRootFilesystem = true;
              };
            }
          ];
        };
      };
    };
  };

  # --- CDI CR ---
  # This custom resource tells the cdi-operator to deploy cdi-apiserver,
  # cdi-controller (uploadcontroller), and cdi-uploadproxy.
  cdiCR = scope.mkResource {
    apiVersion = "cdi.kubevirt.io/v1beta1";
    kind = "CDI";
    name = name;
    labels = selectorLabels;
    spec = {
      config = { };
      imagePullPolicy = cfg.image.pullPolicy;
    };
    requires = [ self.deployment ];
  };

  # --- CRDs ---
  # Minimal CRD stubs. Production would include full OpenAPI validation schemas
  # from the upstream cdi-operator.yaml manifest.

  crdCDI = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "cdis.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "cdis";
        singular = "cdi";
        kind = "CDI";
        listKind = "CDIList";
      };
      scope = "Cluster";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdDataVolume = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "datavolumes.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "datavolumes";
        singular = "datavolume";
        kind = "DataVolume";
        shortNames = [
          "dv"
          "dvs"
        ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdDataImportCron = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "dataimportcrons.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "dataimportcrons";
        singular = "dataimportcron";
        kind = "DataImportCron";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdDataSource = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "datasources.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "datasources";
        singular = "datasource";
        kind = "DataSource";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdObjectTransfer = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "objecttransfers.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "objecttransfers";
        singular = "objecttransfer";
        kind = "ObjectTransfer";
      };
      scope = "Cluster";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdStorageProfile = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "storageprofiles.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "storageprofiles";
        singular = "storageprofile";
        kind = "StorageProfile";
      };
      scope = "Cluster";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdVolumeCloneSource = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "volumeclonesources.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "volumeclonesources";
        singular = "volumeclonesource";
        kind = "VolumeCloneSource";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdVolumeImportSource = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "volumeimportsources.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "volumeimportsources";
        singular = "volumeimportsource";
        kind = "VolumeImportSource";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  crdVolumeUploadSource = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "volumeuploadsources.cdi.kubevirt.io";
    extra.spec = {
      group = "cdi.kubevirt.io";
      names = {
        plural = "volumeuploadsources";
        singular = "volumeuploadsource";
        kind = "VolumeUploadSource";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            x-kubernetes-preserve-unknown-fields = true;
          };
        }
      ];
    };
  };

  # --- Entry point ---
  main = {
    resource = self.deployment;
    requires = [
      self.serviceAccount
      self.clusterRole
      self.clusterRoleBinding
      self.metricsService
      self.cdiCR
      # CRDs
      self.crdCDI
      self.crdDataVolume
      self.crdDataImportCron
      self.crdDataSource
      self.crdObjectTransfer
      self.crdStorageProfile
      self.crdVolumeCloneSource
      self.crdVolumeImportSource
      self.crdVolumeUploadSource
    ];
  };
}
