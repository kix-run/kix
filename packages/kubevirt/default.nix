# KubeVirt package.
#
# Deploys the virt-operator which manages KubeVirt components (virt-api,
# virt-controller, virt-handler) via the KubeVirt custom resource.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding,
#            Deployment (virt-operator), KubeVirt CR, CRDs.
#
# root = Deployment (virt-operator)

{
  scope,
  lib,
}:

let
  name = scope.instanceName;

  # Common label for all kubevirt resources
  kubevirtLabels = {
    "kubevirt.io" = "";
  };

  # Labels for operator deployment selector
  operatorLabels = {
    "kubevirt.io" = "virt-operator";
  };

  # Labels used for the operator's pod template
  podLabels = operatorLabels // {
    "name" = "virt-operator";
    "prometheus.kubevirt.io" = "true";
  };

in
{
  meta = {
    version = "v1.5.0";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/kubevirt/virt-operator";
        tag = "v1.5.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "10m";
          memory = "450Mi";
        };
      };
    };
    featureGates = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ExperimentalVirtiofsSupport" ];
    };
    configuration = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { }; # KubeVirt CR spec.configuration overrides
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {

      # --- ServiceAccount ---
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-operator";
        labels = kubevirtLabels;
      };

      # --- ClusterRole ---
      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-operator";
        labels = kubevirtLabels;
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
        labels = kubevirtLabels;
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

      # --- Deployment (virt-operator) ---
      deployment = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "virt-operator";
        labels = operatorLabels;
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = operatorLabels;
          strategy = {
            type = "RollingUpdate";
          };
          template = {
            metadata = {
              labels = podLabels;
            };
            spec = {
              serviceAccountName = self.serviceAccount.out.name;
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
              priorityClassName = "kubevirt-cluster-critical";
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
              ];
              affinity = {
                podAntiAffinity = {
                  preferredDuringSchedulingIgnoredDuringExecution = [
                    {
                      weight = 1;
                      podAffinityTerm = {
                        labelSelector = {
                          matchExpressions = [
                            {
                              key = "kubevirt.io";
                              operator = "In";
                              values = [ "virt-operator" ];
                            }
                          ];
                        };
                        topologyKey = "kubernetes.io/hostname";
                      };
                    }
                  ];
                };
              };
              containers = [
                {
                  name = "virt-operator";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "virt-operator" ];
                  args = [
                    "--port"
                    "8443"
                    "-v"
                    "2"
                  ];
                  env = [
                    {
                      name = "KUBEVIRT_VERSION";
                      value = config.image.tag;
                    }
                    {
                      name = "VIRT_OPERATOR_IMAGE";
                      value = "${config.image.repository}:${config.image.tag}";
                    }
                    {
                      name = "WATCH_NAMESPACE";
                      valueFrom.fieldRef.fieldPath = "metadata.annotations['olm.targetNamespaces']";
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
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    seccompProfile.type = "RuntimeDefault";
                  };
                  volumeMounts = [
                    {
                      name = "kubevirt-operator-certs";
                      mountPath = "/etc/virt-operator/certificates";
                      readOnly = true;
                    }
                    {
                      name = "profile-data";
                      mountPath = "/profile-data";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "kubevirt-operator-certs";
                  secret = {
                    secretName = "kubevirt-operator-certs";
                    optional = true;
                  };
                }
                {
                  name = "profile-data";
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
        spec = {
          imagePullPolicy = config.image.pullPolicy;
          configuration = {
            developerConfiguration = {
              featureGates = config.featureGates;
            };
          }
          // config.configuration;
        };
        requires = [ self.deployment ];
      };

      # --- CRDs ---
      # Minimal CRD stubs. Production would include full OpenAPI validation schemas
      # from the upstream kubevirt-operator.yaml manifest.

      crds = {
        kubeVirt = scope.mkCRD (scope.crd.fromKind "KubeVirt" { spec.group = "kubevirt.io"; });

        virtualMachine = scope.mkCRD (
          scope.crd.fromKind "VirtualMachine" { spec.group = "kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vm"
            "vms"
          ]
        );

        virtualMachineInstance = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineInstance" { spec.group = "kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmi"
            "vmis"
          ]
        );

        virtualMachineInstanceMigration = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineInstanceMigration" { spec.group = "kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmim"
            "vmims"
          ]
        );

        virtualMachineInstancePreset = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineInstancePreset" { spec.group = "kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmipreset"
            "vmipresets"
          ]
        );

        virtualMachineInstanceReplicaSet = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineInstanceReplicaSet" { spec.group = "kubevirt.io"; }
          |> scope.crd.withShortNames [ "vmirs" ]
        );

        virtualMachineClone = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineClone" { spec.group = "clone.kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmclone"
            "vmclones"
          ]
          |> scope.crd.withVersion "v1beta1"
        );

        virtualMachineExport = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineExport" { spec.group = "export.kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmexport"
            "vmexports"
          ]
          |> scope.crd.withVersion "v1beta1"
        );

        virtualMachineSnapshot = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineSnapshot" { spec.group = "snapshot.kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmsnapshot"
            "vmsnapshots"
          ]
          |> scope.crd.withVersion "v1beta1"
        );

        virtualMachineSnapshotContent = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineSnapshotContent" { spec.group = "snapshot.kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmsnapshotcontent"
            "vmsnapshotcontents"
          ]
          |> scope.crd.withVersion "v1beta1"
        );

        virtualMachineRestore = scope.mkCRD (
          scope.crd.fromKind "VirtualMachineRestore" { spec.group = "snapshot.kubevirt.io"; }
          |> scope.crd.withShortNames [
            "vmrestore"
            "vmrestores"
          ]
          |> scope.crd.withVersion "v1beta1"
        );
      };

      # --- Entry point ---
      root = {
        resource = self.deployment;
        requires = [
          self.serviceAccount
          self.clusterRole
          self.clusterRoleBinding
          self.kubevirtCR
          # CRDs
          self.crds.kubeVirt
          self.crds.virtualMachine
          self.crds.virtualMachineInstance
          self.crds.virtualMachineInstanceMigration
          self.crds.virtualMachineInstancePreset
          self.crds.virtualMachineInstanceReplicaSet
          self.crds.virtualMachineClone
          self.crds.virtualMachineExport
          self.crds.virtualMachineSnapshot
          self.crds.virtualMachineSnapshotContent
          self.crds.virtualMachineRestore
        ];
      };
    };
}
