# CDI (Containerized Data Importer) package.
#
# Deploys the cdi-operator which manages CDI components (cdi-apiserver,
# cdi-controller/uploadcontroller, cdi-uploadproxy) via the CDI custom resource.
#
# Resources: ServiceAccount, ClusterRole, ClusterRoleBinding, Role,
#            RoleBinding, Deployment (cdi-operator), CDI CR, the cdis CRD.
#
# Only the cdis.cdi.kubevirt.io CRD is shipped here, as upstream does. The
# operator installs the CRDs for its own kinds (DataVolume, DataImportCron,
# StorageProfile and the rest) with full schemas once it runs; a stub here
# would fight the operator's version on every server-side apply.
#
# root = Deployment (cdi-operator)

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;

  # Labels matching the upstream CDI operator manifest
  operatorLabels = {
    "name" = "cdi-operator";
    "operator.cdi.kubevirt.io" = "";
    "cdi.kubevirt.io" = "cdi-operator";
    "prometheus.cdi.kubevirt.io" = "true";
  };

  selectorLabels = {
    "name" = "cdi-operator";
    "operator.cdi.kubevirt.io" = "";
  };

  metricsProbe = {
    httpGet = {
      path = "/metrics";
      port = "metrics";
    };
    initialDelaySeconds = 5;
    periodSeconds = 10;
    timeoutSeconds = 10;
  };
in
{
  meta = {
    version = "v1.62.0";
    description = "KubeVirt Containerized Data Importer: the cdi-operator and a CDI resource; CDI imports disk images into PVCs";
    owner = "platform";
    # The cdi-operator has no leader election, so one replica is the
    # ceiling it can honour. The components it deploys are unaffected.
    availability.max = "pod";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/kubevirt/cdi-operator";
        tag = "v1.62.0";
        pullPolicy = "IfNotPresent";
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # Fixed at 1: a second cdi-operator would fight the first over the
      # CDI custom resource. See meta.availability.max.
      default = 1;
    };
    # Requests from cdi-operator.yaml (v1.62.0), which sets no limits. An
    # idle cdi-operator held up to 70 MiB on kind with CDI deployed.
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
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
    # CDI CR configuration
    cloneStrategyOverride = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    featureGates = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
    infra = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    workload = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
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
        labels = {
          "operator.cdi.kubevirt.io" = "";
        };
      };

      # --- ClusterRole ---
      clusterRole = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "${name}-operator-cluster";
        labels = {
          "operator.cdi.kubevirt.io" = "";
        };
        extra.rules = [
          # Core resources - configmaps (read)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core resources - PVCs (read)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumeclaims" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core resources - PVs (read)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumes" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core resources - namespaces (read)
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [ "get" ];
          }
          # Core resources - events
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [
              "create"
              "patch"
            ];
          }
          # Core resources - PVCs (full)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumeclaims" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
              "deletecollection"
              "patch"
            ];
          }
          # Core resources - PVs (update)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumes" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
            ];
          }
          # Core resources - finalizers
          {
            apiGroups = [ "" ];
            resources = [
              "persistentvolumeclaims/finalizers"
              "pods/finalizers"
            ];
            verbs = [ "update" ];
          }
          # Core resources - pods, services
          {
            apiGroups = [ "" ];
            resources = [
              "pods"
              "services"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
            ];
          }
          # Core resources - configmaps (get/create)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "create"
            ];
          }
          # Core resources - secrets (create)
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "create" ];
          }
          # Core resources - PVCs (get only)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumeclaims" ];
            verbs = [ "get" ];
          }
          # Admission webhooks - create/list/watch
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resources = [
              "validatingwebhookconfigurations"
              "mutatingwebhookconfigurations"
            ];
            verbs = [
              "create"
              "list"
              "watch"
            ];
          }
          # Admission webhooks - named validating
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resourceNames = [
              "cdi-api-dataimportcron-validate"
              "cdi-api-populator-validate"
              "cdi-api-datavolume-validate"
              "cdi-api-validate"
              "objecttransfer-api-validate"
            ];
            resources = [ "validatingwebhookconfigurations" ];
            verbs = [
              "get"
              "update"
              "delete"
            ];
          }
          # Admission webhooks - named mutating
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resourceNames = [
              "cdi-api-datavolume-mutate"
              "cdi-api-pvc-mutate"
            ];
            resources = [ "mutatingwebhookconfigurations" ];
            verbs = [
              "get"
              "update"
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
              "delete"
            ];
          }
          # CRDs (read)
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [
              "get"
              "list"
              "watch"
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
              "delete"
            ];
          }
          # Authorization
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
          # CDI + upload resources (full)
          {
            apiGroups = [
              "cdi.kubevirt.io"
              "upload.cdi.kubevirt.io"
            ];
            resources = [ "*" ];
            verbs = [ "*" ];
          }
          # CDI datavolumes (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "datavolumes" ];
            verbs = [
              "list"
              "get"
            ];
          }
          # CDI datasources (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "datasources" ];
            verbs = [ "get" ];
          }
          # CDI volumeclonesources (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "volumeclonesources" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CDI storageprofiles (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "storageprofiles" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CDI cdis (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "cdis" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CDI cdiconfigs (read)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "cdiconfigs" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CDI cdis/finalizers
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "cdis/finalizers" ];
            verbs = [ "update" ];
          }
          # CDI all (full)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "*" ];
            verbs = [ "*" ];
          }
          # CDI dataimportcrons
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "dataimportcrons" ];
            verbs = [
              "get"
              "list"
              "update"
            ];
          }
          # OpenShift config - proxies/infrastructures
          {
            apiGroups = [ "config.openshift.io" ];
            resources = [
              "proxies"
              "infrastructures"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # OpenShift config - clusterversions
          {
            apiGroups = [ "config.openshift.io" ];
            resources = [ "clusterversions" ];
            verbs = [ "get" ];
          }
          # Forklift CDI populators
          {
            apiGroups = [ "forklift.cdi.kubevirt.io" ];
            resources = [
              "ovirtvolumepopulators"
              "openstackvolumepopulators"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # OpenShift imagestreams
          {
            apiGroups = [ "image.openshift.io" ];
            resources = [ "imagestreams" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt VM finalizers
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachines/finalizers" ];
            verbs = [ "update" ];
          }
          # RBAC
          {
            apiGroups = [ "rbac.authorization.k8s.io" ];
            resources = [
              "clusterrolebindings"
              "clusterroles"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
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
          # OpenShift security
          {
            apiGroups = [ "security.openshift.io" ];
            resources = [ "securitycontextconstraints" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "create"
            ];
          }
          # Snapshot support (read)
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [ "volumesnapshots" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Snapshot support (full)
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [
              "volumesnapshots"
              "volumesnapshotclasses"
              "volumesnapshotcontents"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
            ];
          }
          # Snapshot support (update/deletecollection)
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [ "volumesnapshots" ];
            verbs = [
              "update"
              "deletecollection"
            ];
          }
          # Storage classes (read)
          {
            apiGroups = [ "storage.k8s.io" ];
            resources = [ "storageclasses" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Storage classes + CSI drivers (read)
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
        ];
      };

      # --- ClusterRoleBinding ---
      clusterRoleBinding = scope.mkClusterResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "${name}-operator";
        labels = {
          "operator.cdi.kubevirt.io" = "";
        };
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

      # --- Role (namespaced) ---
      # The operator manages its operands' namespaced resources and takes a
      # lease for its leader-election helper. Mirrors the upstream namespace
      # Role; upstream's duplicate leases rule is folded into one.
      role = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "${name}-operator";
        labels = {
          "operator.cdi.kubevirt.io" = "";
        };
        extra.rules = [
          # RBAC for the operands
          {
            apiGroups = [ "rbac.authorization.k8s.io" ];
            resources = [
              "rolebindings"
              "roles"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
            ];
          }
          # Core resources the operands are built from
          {
            apiGroups = [ "" ];
            resources = [
              "serviceaccounts"
              "configmaps"
              "events"
              "secrets"
              "services"
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
          # Operand deployments
          {
            apiGroups = [ "apps" ];
            resources = [
              "deployments"
              "deployments/finalizers"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
            ];
          }
          # OpenShift routes
          {
            apiGroups = [ "route.openshift.io" ];
            resources = [
              "routes"
              "routes/custom-host"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
            ];
          }
          # OpenShift proxies
          {
            apiGroups = [ "config.openshift.io" ];
            resources = [ "proxies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Prometheus operator objects
          {
            apiGroups = [ "monitoring.coreos.com" ];
            resources = [
              "servicemonitors"
              "prometheusrules"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
              "update"
              "patch"
            ];
          }
          # Leader-election helper lease
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [
              "get"
              "create"
              "update"
            ];
          }
          # Secrets + configmaps (read/create)
          {
            apiGroups = [ "" ];
            resources = [
              "secrets"
              "configmaps"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
            ];
          }
          # Configmaps (full)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
            ];
          }
          # Secrets (read)
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Cronjobs
          {
            apiGroups = [ "batch" ];
            resources = [ "cronjobs" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "deletecollection"
            ];
          }
          # Jobs
          {
            apiGroups = [ "batch" ];
            resources = [ "jobs" ];
            verbs = [
              "create"
              "deletecollection"
              "list"
              "watch"
            ];
          }
          # Ingresses (read)
          {
            apiGroups = [ "networking.k8s.io" ];
            resources = [ "ingresses" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # OpenShift routes (read)
          {
            apiGroups = [ "route.openshift.io" ];
            resources = [ "routes" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Configmaps (get)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [ "get" ];
          }
          # Services, endpoints, pods (read)
          {
            apiGroups = [ "" ];
            resources = [
              "services"
              "endpoints"
              "pods"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
        ];
      };

      # --- RoleBinding ---
      roleBinding = scope.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "${name}-operator";
        labels = {
          "operator.cdi.kubevirt.io" = "";
        };
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = self.role.out.name;
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

      # --- Deployment (cdi-operator) ---
      deployment = scope.mkDeployment {
        name = "${name}-operator";
        labels = operatorLabels;
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = selectorLabels;
          # strategy omitted — K8s defaults to RollingUpdate
          template = {
            metadata = {
              labels = operatorLabels;
              annotations = {
                "openshift.io/required-scc" = "restricted-v2";
              };
            };
            spec = {
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
              };
              nodeSelector = {
                "kubernetes.io/os" = "linux";
              };
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
              ];
              affinity = {
                podAffinity = {
                  preferredDuringSchedulingIgnoredDuringExecution = [
                    {
                      podAffinityTerm = {
                        labelSelector = {
                          matchExpressions = [
                            {
                              key = "cdi.kubevirt.io";
                              operator = "In";
                              values = [ "cdi-operator" ];
                            }
                          ];
                        };
                        topologyKey = "kubernetes.io/hostname";
                      };
                      weight = 1;
                    }
                  ];
                };
              };
              containers = [
                {
                  name = "cdi-operator";
                  image = "${config.image.repository}:${config.image.tag}";
                  imagePullPolicy = config.image.pullPolicy;
                  env = [
                    {
                      name = "APISERVER_IMAGE";
                      value = "quay.io/kubevirt/cdi-apiserver:${config.image.tag}";
                    }
                    {
                      name = "CLONER_IMAGE";
                      value = "quay.io/kubevirt/cdi-cloner:${config.image.tag}";
                    }
                    {
                      name = "CONTROLLER_IMAGE";
                      value = "quay.io/kubevirt/cdi-controller:${config.image.tag}";
                    }
                    {
                      name = "DEPLOY_CLUSTER_RESOURCES";
                      value = "true";
                    }
                    {
                      name = "IMPORTER_IMAGE";
                      value = "quay.io/kubevirt/cdi-importer:${config.image.tag}";
                    }
                    {
                      name = "MONITORING_NAMESPACE";
                    }
                    {
                      name = "OPERATOR_VERSION";
                      value = config.image.tag;
                    }
                    {
                      name = "OVIRT_POPULATOR_IMAGE";
                      value = "quay.io/kubevirt/cdi-importer:${config.image.tag}";
                    }
                    {
                      name = "PULL_POLICY";
                      value = config.image.pullPolicy;
                    }
                    {
                      name = "UPLOAD_PROXY_IMAGE";
                      value = "quay.io/kubevirt/cdi-uploadproxy:${config.image.tag}";
                    }
                    {
                      name = "UPLOAD_SERVER_IMAGE";
                      value = "quay.io/kubevirt/cdi-uploadserver:${config.image.tag}";
                    }
                    {
                      name = "VERBOSITY";
                      value = "1";
                    }
                  ];
                  ports = [
                    {
                      name = "metrics";
                      containerPort = 8080;
                      protocol = "TCP";
                    }
                  ];
                  # cdi-operator.yaml (v1.62.0) sets no probes and the
                  # operator serves no health endpoint. These follow
                  # virt-operator's upstream probe on its metrics endpoint.
                  readinessProbe = metricsProbe;
                  livenessProbe = metricsProbe // {
                    initialDelaySeconds = 15;
                  };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    runAsNonRoot = true;
                    seccompProfile.type = "RuntimeDefault";
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
      cdiCR = scope.mkClusterResource {
        apiVersion = "cdi.kubevirt.io/v1beta1";
        kind = "CDI";
        name = name;
        spec = {
          imagePullPolicy = config.image.pullPolicy;
          config =
            { } // (if config.featureGates != [ ] then { featureGates = config.featureGates; } else { });
        }
        // (
          if config.cloneStrategyOverride != null then
            { cloneStrategyOverride = config.cloneStrategyOverride; }
          else
            { }
        )
        // (if config.infra != { } then { infra = config.infra; } else { })
        // (if config.workload != { } then { workload = config.workload; } else { });
        requires = [
          self.deployment
          self.crds.cdi
        ];
      };

      # --- CRDs ---
      # Only the CDI CR's own definition, vendored from upstream v1.62.0.
      # The operator installs the CRDs for the kinds it serves.
      #
      # The operator rewrites this CRD once it runs: it drops the deprecated
      # v1alpha1 version. That makes `spec.versions` its field, so the
      # package cedes it: kix ships upstream's list at creation, and when
      # the next deploy meets the operator's ownership it applies without
      # the field rather than failing the deploy.
      crds =
        let
          upstream = builtins.fromJSON (builtins.readFile ./crds/cdis.cdi.kubevirt.io.json);
        in
        {
          cdi = scope.mkCRD {
            spec = upstream.spec;
            ownership.cede = [ "spec.versions" ];
          };
        };

      # --- Entry point ---
      root = {
        resource = self.deployment;
        requires = [
          self.serviceAccount
          self.clusterRole
          self.clusterRoleBinding
          self.role
          self.roleBinding
          self.cdiCR
          self.crds.cdi
        ];
      };
    };
}
