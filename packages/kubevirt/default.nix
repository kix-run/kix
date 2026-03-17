# KubeVirt package.
#
# Deploys the virt-operator which manages KubeVirt components (virt-api,
# virt-controller, virt-handler) via the KubeVirt custom resource.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Service (metrics),
#            Deployment (virt-operator), KubeVirt CR, CRDs.
#
# main = Deployment (virt-operator)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "quay.io/kubevirt/virt-operator";
      tag = "v1.5.0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 2;
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
    featureGates = [ "ExperimentalVirtiofsSupport" ];
    configuration = { }; # KubeVirt CR spec.configuration overrides
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "kubevirt";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "virt-operator";
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
      # KubeVirt resources
      {
        apiGroups = [ "kubevirt.io" ];
        resources = [
          "kubevirts"
          "virtualmachines"
          "virtualmachines/status"
          "virtualmachines/finalizers"
          "virtualmachineinstances"
          "virtualmachineinstances/status"
          "virtualmachineinstances/finalizers"
          "virtualmachineinstancemigrations"
          "virtualmachineinstancemigrations/status"
          "virtualmachineinstancemigrations/finalizers"
          "virtualmachineinstancepresets"
          "virtualmachineinstancereplicasets"
          "virtualmachineinstancereplicasets/status"
          "virtualmachineinstancereplicasets/finalizers"
          "virtualmachineclones"
          "virtualmachineclones/status"
          "virtualmachineclones/finalizers"
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
      # Snapshot resources
      {
        apiGroups = [ "snapshot.kubevirt.io" ];
        resources = [
          "virtualmachinesnapshots"
          "virtualmachinesnapshots/status"
          "virtualmachinesnapshotcontents"
          "virtualmachinesnapshotcontents/status"
          "virtualmachinerestores"
          "virtualmachinerestores/status"
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
      # Export resources
      {
        apiGroups = [ "export.kubevirt.io" ];
        resources = [
          "virtualmachineexports"
          "virtualmachineexports/status"
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
      # Core resources
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "pods/exec"
          "pods/status"
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
          "limitranges"
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
          "controllerrevisions"
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
        resources = [ "jobs" ];
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
        resources = [ "customresourcedefinitions" ];
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
      # Security context constraints (OpenShift compat)
      {
        apiGroups = [ "security.openshift.io" ];
        resources = [ "securitycontextconstraints" ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
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
      # CDI integration
      {
        apiGroups = [ "cdi.kubevirt.io" ];
        resources = [
          "datavolumes"
          "datavolumes/source"
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
      # Scheduling
      {
        apiGroups = [ "scheduling.k8s.io" ];
        resources = [ "priorityclasses" ];
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
          port = 8443;
          protocol = "TCP";
          targetPort = 8443;
        }
      ];
    };
    outputs = {
      metricsPort = "8443";
    };
  };

  # --- Deployment (virt-operator) ---
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
          maxUnavailable = 1;
        };
      };
      template = {
        metadata = {
          labels = selectorLabels;
          annotations = {
            "kubectl.kubernetes.io/default-container" = "virt-operator";
          };
        };
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          terminationGracePeriodSeconds = 30;
          securityContext = {
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          priorityClassName = "kubevirt-cluster-critical";
          tolerations = [
            {
              key = "CriticalAddonsOnly";
              operator = "Exists";
            }
          ];
          containers = [
            {
              name = "virt-operator";
              image = "${cfg.image.repository}:${cfg.image.tag}";
              imagePullPolicy = cfg.image.pullPolicy;
              command = [ "virt-operator" ];
              args = [
                "--port=8443"
                "--v=2"
              ];
              env = [
                {
                  name = "OPERATOR_IMAGE";
                  value = "${cfg.image.repository}:${cfg.image.tag}";
                }
                {
                  name = "WATCH_NAMESPACE";
                  valueFrom.fieldRef.fieldPath = "metadata.namespace";
                }
              ];
              ports = [
                {
                  name = "metrics";
                  containerPort = 8443;
                  protocol = "TCP";
                }
                {
                  name = "webhooks";
                  containerPort = 8444;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/metrics";
                  port = 8443;
                  scheme = "HTTPS";
                };
                initialDelaySeconds = 15;
                periodSeconds = 20;
                timeoutSeconds = 10;
              };
              readinessProbe = {
                httpGet = {
                  path = "/metrics";
                  port = 8443;
                  scheme = "HTTPS";
                };
                initialDelaySeconds = 5;
                periodSeconds = 10;
                timeoutSeconds = 10;
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

  # --- KubeVirt CR ---
  # This custom resource tells the virt-operator to deploy virt-api,
  # virt-controller, and virt-handler.
  kubevirtCR = scope.mkResource {
    apiVersion = "kubevirt.io/v1";
    kind = "KubeVirt";
    name = name;
    labels = selectorLabels;
    spec = {
      certificateRotateStrategy = { };
      customizeComponents = { };
      imagePullPolicy = cfg.image.pullPolicy;
      infra = {
        replicas = cfg.replicaCount;
      };
      configuration = {
        developerConfiguration = {
          featureGates = cfg.featureGates;
        };
      }
      // cfg.configuration;
    };
    requires = [ self.deployment ];
  };

  # --- CRDs ---
  # Minimal CRD stubs. Production would include full OpenAPI validation schemas
  # from the upstream kubevirt-operator.yaml manifest.

  crdKubeVirt = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "kubevirts.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "kubevirts";
        singular = "kubevirt";
        kind = "KubeVirt";
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachine = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachines.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "virtualmachines";
        singular = "virtualmachine";
        kind = "VirtualMachine";
        shortNames = [
          "vm"
          "vms"
        ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachineInstance = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineinstances.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "virtualmachineinstances";
        singular = "virtualmachineinstance";
        kind = "VirtualMachineInstance";
        shortNames = [
          "vmi"
          "vmis"
        ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachineInstanceMigration = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineinstancemigrations.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "virtualmachineinstancemigrations";
        singular = "virtualmachineinstancemigration";
        kind = "VirtualMachineInstanceMigration";
        shortNames = [
          "vmim"
          "vmims"
        ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachineInstancePreset = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineinstancepresets.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "virtualmachineinstancepresets";
        singular = "virtualmachineinstancepreset";
        kind = "VirtualMachineInstancePreset";
        shortNames = [
          "vmipreset"
          "vmipresets"
        ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachineInstanceReplicaSet = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineinstancereplicasets.kubevirt.io";
    extra.spec = {
      group = "kubevirt.io";
      names = {
        plural = "virtualmachineinstancereplicasets";
        singular = "virtualmachineinstancereplicaset";
        kind = "VirtualMachineInstanceReplicaSet";
        shortNames = [ "vmirs" ];
      };
      scope = "Namespaced";
      versions = [
        {
          name = "v1";
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

  crdVirtualMachineClone = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineclones.clone.kubevirt.io";
    extra.spec = {
      group = "clone.kubevirt.io";
      names = {
        plural = "virtualmachineclones";
        singular = "virtualmachineclone";
        kind = "VirtualMachineClone";
        shortNames = [
          "vmclone"
          "vmclones"
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

  crdVirtualMachineExport = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachineexports.export.kubevirt.io";
    extra.spec = {
      group = "export.kubevirt.io";
      names = {
        plural = "virtualmachineexports";
        singular = "virtualmachineexport";
        kind = "VirtualMachineExport";
        shortNames = [
          "vmexport"
          "vmexports"
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

  crdVirtualMachineSnapshot = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachinesnapshots.snapshot.kubevirt.io";
    extra.spec = {
      group = "snapshot.kubevirt.io";
      names = {
        plural = "virtualmachinesnapshots";
        singular = "virtualmachinesnapshot";
        kind = "VirtualMachineSnapshot";
        shortNames = [
          "vmsnapshot"
          "vmsnapshots"
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

  crdVirtualMachineSnapshotContent = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachinesnapshotcontents.snapshot.kubevirt.io";
    extra.spec = {
      group = "snapshot.kubevirt.io";
      names = {
        plural = "virtualmachinesnapshotcontents";
        singular = "virtualmachinesnapshotcontent";
        kind = "VirtualMachineSnapshotContent";
        shortNames = [
          "vmsnapshotcontent"
          "vmsnapshotcontents"
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

  crdVirtualMachineRestore = scope.mkClusterResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "virtualmachinerestores.snapshot.kubevirt.io";
    extra.spec = {
      group = "snapshot.kubevirt.io";
      names = {
        plural = "virtualmachinerestores";
        singular = "virtualmachinerestore";
        kind = "VirtualMachineRestore";
        shortNames = [
          "vmrestore"
          "vmrestores"
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

  # --- Entry point ---
  main = {
    resource = self.deployment;
    requires = [
      self.serviceAccount
      self.clusterRole
      self.clusterRoleBinding
      self.metricsService
      self.kubevirtCR
      # CRDs
      self.crdKubeVirt
      self.crdVirtualMachine
      self.crdVirtualMachineInstance
      self.crdVirtualMachineInstanceMigration
      self.crdVirtualMachineInstancePreset
      self.crdVirtualMachineInstanceReplicaSet
      self.crdVirtualMachineClone
      self.crdVirtualMachineExport
      self.crdVirtualMachineSnapshot
      self.crdVirtualMachineSnapshotContent
      self.crdVirtualMachineRestore
    ];
  };
}
