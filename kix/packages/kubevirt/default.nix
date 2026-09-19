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
  kix,
  availability,
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
      # virt-operator holds a leader election lease, so a restart is not
      # user-visible; from "node" up a standby survives a lost node.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of virt-operator replicas. Defaults from the cluster's
        availability level (v2_discussions/145).
      '';
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
          # Core: serviceaccounts, services, endpoints, pods/exec
          {
            apiGroups = [ "" ];
            resources = [
              "serviceaccounts"
              "services"
              "endpoints"
              "pods/exec"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
              "patch"
            ];
          }
          # Core: configmaps (patch, delete)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "patch"
              "delete"
            ];
          }
          # Core: namespaces (get, list, watch, patch)
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [
              "get"
              "list"
              "watch"
              "patch"
            ];
          }
          # Core: pods (get, list, delete, patch)
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [
              "get"
              "list"
              "delete"
              "patch"
            ];
          }
          # Core: persistentvolumeclaims (get)
          {
            apiGroups = [ "" ];
            resources = [ "persistentvolumeclaims" ];
            verbs = [ "get" ];
          }
          # Core: configmaps (get, list, watch)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core: limitranges
          {
            apiGroups = [ "" ];
            resources = [ "limitranges" ];
            verbs = [
              "watch"
              "list"
            ];
          }
          # Core: namespaces (get, list, watch)
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core: namespaces (get, list, watch, patch)
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [
              "get"
              "list"
              "watch"
              "patch"
            ];
          }
          # Core: pods, configmaps, endpoints, services (full)
          {
            apiGroups = [ "" ];
            resources = [
              "pods"
              "configmaps"
              "endpoints"
              "services"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "delete"
              "update"
              "create"
              "patch"
            ];
          }
          # Core: events
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [
              "update"
              "create"
              "patch"
            ];
          }
          # Core: secrets (create)
          {
            apiGroups = [ "" ];
            resources = [ "secrets" ];
            verbs = [ "create" ];
          }
          # Core: pods/finalizers
          {
            apiGroups = [ "" ];
            resources = [ "pods/finalizers" ];
            verbs = [ "update" ];
          }
          # Core: pods/eviction
          {
            apiGroups = [ "" ];
            resources = [ "pods/eviction" ];
            verbs = [ "create" ];
          }
          # Core: pods/status
          {
            apiGroups = [ "" ];
            resources = [ "pods/status" ];
            verbs = [ "patch" ];
          }
          # Core: nodes
          {
            apiGroups = [ "" ];
            resources = [ "nodes" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "patch"
            ];
          }
          # Core: persistentvolumeclaims (full)
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
              "patch"
            ];
          }
          # Core: namespaces (get)
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [ "get" ];
          }
          # Core: resourcequotas
          {
            apiGroups = [ "" ];
            resources = [ "resourcequotas" ];
            verbs = [
              "list"
              "watch"
            ];
          }
          # Core: nodes (patch, list, watch, get)
          {
            apiGroups = [ "" ];
            resources = [ "nodes" ];
            verbs = [
              "patch"
              "list"
              "watch"
              "get"
            ];
          }
          # Core: configmaps (get, list, watch)
          {
            apiGroups = [ "" ];
            resources = [ "configmaps" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Core: events (create, patch)
          {
            apiGroups = [ "" ];
            resources = [ "events" ];
            verbs = [
              "create"
              "patch"
            ];
          }
          # Admission webhooks
          {
            apiGroups = [ "admissionregistration.k8s.io" ];
            resources = [
              "validatingwebhookconfigurations"
              "mutatingwebhookconfigurations"
              "validatingadmissionpolicybindings"
              "validatingadmissionpolicies"
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
          # CRDs (get, list, watch, create, delete, patch)
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
              "patch"
            ];
          }
          # CRDs (get, list, watch)
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CRDs (get, list, watch)
          {
            apiGroups = [ "apiextensions.k8s.io" ];
            resources = [ "customresourcedefinitions" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CRDs (get, list, watch)
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
              "delete"
              "update"
              "patch"
            ];
          }
          # Apps: controllerrevisions (watch, list, create, delete, patch)
          {
            apiGroups = [ "apps" ];
            resources = [ "controllerrevisions" ];
            verbs = [
              "watch"
              "list"
              "create"
              "delete"
              "patch"
            ];
          }
          # Apps: deployments, daemonsets
          {
            apiGroups = [ "apps" ];
            resources = [
              "deployments"
              "daemonsets"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
              "patch"
            ];
          }
          # Apps: controllerrevisions (create, list, get)
          {
            apiGroups = [ "apps" ];
            resources = [ "controllerrevisions" ];
            verbs = [
              "create"
              "list"
              "get"
            ];
          }
          # Apps: daemonsets (list)
          {
            apiGroups = [ "apps" ];
            resources = [ "daemonsets" ];
            verbs = [ "list" ];
          }
          # Apps: controllerrevisions (watch, list, create, delete, get, update)
          {
            apiGroups = [ "apps" ];
            resources = [ "controllerrevisions" ];
            verbs = [
              "watch"
              "list"
              "create"
              "delete"
              "get"
              "update"
            ];
          }
          # Authentication: tokenreviews
          {
            apiGroups = [ "authentication.k8s.io" ];
            resources = [ "tokenreviews" ];
            verbs = [ "create" ];
          }
          # Authorization: subjectaccessreviews
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
          # Authorization: subjectaccessreviews
          {
            apiGroups = [ "authorization.k8s.io" ];
            resources = [ "subjectaccessreviews" ];
            verbs = [ "create" ];
          }
          # Batch: jobs (get, list, watch, create, delete, patch)
          {
            apiGroups = [ "batch" ];
            resources = [ "jobs" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "delete"
              "patch"
            ];
          }
          # Batch: jobs (create, get, delete)
          {
            apiGroups = [ "batch" ];
            resources = [ "jobs" ];
            verbs = [
              "create"
              "get"
              "delete"
            ];
          }
          # CDI: datasources, datavolumes (get, list, watch)
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [
              "datasources"
              "datavolumes"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # CDI: wildcard
          {
            apiGroups = [ "cdi.kubevirt.io" ];
            resources = [ "*" ];
            verbs = [ "*" ];
          }
          # Clone: virtualmachineclones (status, finalizers)
          {
            apiGroups = [ "clone.kubevirt.io" ];
            resources = [
              "virtualmachineclones"
              "virtualmachineclones/status"
              "virtualmachineclones/finalizers"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "patch"
              "delete"
            ];
          }
          # Clone: virtualmachineclones (full + deletecollection)
          {
            apiGroups = [ "clone.kubevirt.io" ];
            resources = [ "virtualmachineclones" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Clone: virtualmachineclones (no deletecollection)
          {
            apiGroups = [ "clone.kubevirt.io" ];
            resources = [ "virtualmachineclones" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # Clone: virtualmachineclones (get, list, watch)
          {
            apiGroups = [ "clone.kubevirt.io" ];
            resources = [ "virtualmachineclones" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Export: virtualmachineexports (status, finalizers)
          {
            apiGroups = [ "export.kubevirt.io" ];
            resources = [
              "virtualmachineexports"
              "virtualmachineexports/status"
              "virtualmachineexports/finalizers"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
              "patch"
            ];
          }
          # Export: virtualmachineexports (get, list, watch)
          {
            apiGroups = [ "export.kubevirt.io" ];
            resources = [ "virtualmachineexports" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Export: virtualmachineexports (full + deletecollection)
          {
            apiGroups = [ "export.kubevirt.io" ];
            resources = [ "virtualmachineexports" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Export: virtualmachineexports (no deletecollection)
          {
            apiGroups = [ "export.kubevirt.io" ];
            resources = [ "virtualmachineexports" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # Export: virtualmachineexports (get, list, watch)
          {
            apiGroups = [ "export.kubevirt.io" ];
            resources = [ "virtualmachineexports" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Instancetype: all types (get, list, watch)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineinstancetypes"
              "virtualmachineclusterinstancetypes"
              "virtualmachinepreferences"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Instancetype: all types (get, list, watch)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineinstancetypes"
              "virtualmachineclusterinstancetypes"
              "virtualmachinepreferences"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Instancetype: all types (full + deletecollection)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineinstancetypes"
              "virtualmachineclusterinstancetypes"
              "virtualmachinepreferences"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Instancetype: all types (no deletecollection)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineinstancetypes"
              "virtualmachineclusterinstancetypes"
              "virtualmachinepreferences"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # Instancetype: all types (get, list, watch)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineinstancetypes"
              "virtualmachineclusterinstancetypes"
              "virtualmachinepreferences"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Instancetype: cluster types only (get, list, watch)
          {
            apiGroups = [ "instancetype.kubevirt.io" ];
            resources = [
              "virtualmachineclusterinstancetypes"
              "virtualmachineclusterpreferences"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # k8s.cni.cncf.io: network-attachment-definitions
          {
            apiGroups = [ "k8s.cni.cncf.io" ];
            resources = [ "network-attachment-definitions" ];
            verbs = [ "get" ];
          }
          # KubeVirt: kubevirts (get, list, watch, patch, update)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
              "watch"
              "patch"
              "update"
              "patch"
            ];
          }
          # KubeVirt: virtualmachines, virtualmachineinstances
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [
              "virtualmachines"
              "virtualmachineinstances"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "patch"
              "update"
            ];
          }
          # KubeVirt: virtualmachines/status
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachines/status" ];
            verbs = [ "patch" ];
          }
          # KubeVirt: virtualmachineinstancemigrations
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstancemigrations" ];
            verbs = [
              "create"
              "get"
              "list"
              "watch"
              "patch"
            ];
          }
          # KubeVirt: virtualmachineinstancepresets
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstancepresets" ];
            verbs = [
              "watch"
              "list"
            ];
          }
          # KubeVirt: kubevirts (get, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt: wildcard
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "*" ];
            verbs = [ "*" ];
          }
          # KubeVirt: finalizers
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [
              "virtualmachines/finalizers"
              "virtualmachineinstances/finalizers"
            ];
            verbs = [ "update" ];
          }
          # KubeVirt: virtualmachineinstances (update, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstances" ];
            verbs = [
              "update"
              "list"
              "watch"
            ];
          }
          # KubeVirt: kubevirts (get, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt: kubevirts (list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "list"
              "watch"
            ];
          }
          # KubeVirt: kubevirts (get, list)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
            ];
          }
          # KubeVirt: VMs, VMIs, presets, replicasets (full + deletecollection)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [
              "virtualmachines"
              "virtualmachineinstances"
              "virtualmachineinstancepresets"
              "virtualmachineinstancereplicasets"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # KubeVirt: virtualmachineinstancemigrations (get, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstancemigrations" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt: VMs, VMIs, presets, replicasets (no deletecollection)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [
              "virtualmachines"
              "virtualmachineinstances"
              "virtualmachineinstancepresets"
              "virtualmachineinstancereplicasets"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # KubeVirt: virtualmachineinstancemigrations (get, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstancemigrations" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt: kubevirts (get, list)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
            ];
          }
          # KubeVirt: kubevirts (get, list)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "kubevirts" ];
            verbs = [
              "get"
              "list"
            ];
          }
          # KubeVirt: all main resources (get, list, watch)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [
              "virtualmachines"
              "virtualmachineinstances"
              "virtualmachineinstancepresets"
              "virtualmachineinstancereplicasets"
              "virtualmachineinstancemigrations"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # KubeVirt: virtualmachineinstancemigrations (full + deletecollection)
          {
            apiGroups = [ "kubevirt.io" ];
            resources = [ "virtualmachineinstancemigrations" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Migrations: migrationpolicies
          {
            apiGroups = [ "migrations.kubevirt.io" ];
            resources = [ "migrationpolicies" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Monitoring: servicemonitors, prometheusrules
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
          # Policy: poddisruptionbudgets
          {
            apiGroups = [ "policy" ];
            resources = [ "poddisruptionbudgets" ];
            verbs = [
              "get"
              "list"
              "watch"
              "delete"
              "create"
              "patch"
            ];
          }
          # Pool: virtualmachinepools (status, finalizers, scale)
          {
            apiGroups = [ "pool.kubevirt.io" ];
            resources = [
              "virtualmachinepools"
              "virtualmachinepools/finalizers"
              "virtualmachinepools/status"
              "virtualmachinepools/scale"
            ];
            verbs = [
              "watch"
              "list"
              "create"
              "delete"
              "update"
              "patch"
              "get"
            ];
          }
          # Pool: virtualmachinepools (full + deletecollection)
          {
            apiGroups = [ "pool.kubevirt.io" ];
            resources = [ "virtualmachinepools" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Pool: virtualmachinepools (no deletecollection)
          {
            apiGroups = [ "pool.kubevirt.io" ];
            resources = [ "virtualmachinepools" ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # Pool: virtualmachinepools (get, list, watch)
          {
            apiGroups = [ "pool.kubevirt.io" ];
            resources = [ "virtualmachinepools" ];
            verbs = [
              "get"
              "list"
              "watch"
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
              "delete"
              "patch"
              "update"
            ];
          }
          # Security: securitycontextconstraints (create, get, list, watch)
          {
            apiGroups = [ "security.openshift.io" ];
            resources = [ "securitycontextconstraints" ];
            verbs = [
              "create"
              "get"
              "list"
              "watch"
            ];
          }
          # Security: securitycontextconstraints (resourceNames: privileged)
          {
            apiGroups = [ "security.openshift.io" ];
            resourceNames = [ "privileged" ];
            resources = [ "securitycontextconstraints" ];
            verbs = [
              "get"
              "patch"
              "update"
            ];
          }
          # Security: securitycontextconstraints (resourceNames: kubevirt-handler, kubevirt-controller)
          {
            apiGroups = [ "security.openshift.io" ];
            resourceNames = [
              "kubevirt-handler"
              "kubevirt-controller"
            ];
            resources = [ "securitycontextconstraints" ];
            verbs = [
              "get"
              "list"
              "watch"
              "update"
              "delete"
            ];
          }
          # Snapshot: virtualmachinesnapshots, restores, contents (get, list, watch)
          {
            apiGroups = [ "snapshot.kubevirt.io" ];
            resources = [
              "virtualmachinesnapshots"
              "virtualmachinerestores"
              "virtualmachinesnapshotcontents"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Snapshot: all with status/finalizers
          {
            apiGroups = [ "snapshot.kubevirt.io" ];
            resources = [
              "virtualmachinesnapshots"
              "virtualmachinesnapshots/status"
              "virtualmachinesnapshots/finalizers"
              "virtualmachinesnapshotcontents"
              "virtualmachinesnapshotcontents/status"
              "virtualmachinesnapshotcontents/finalizers"
              "virtualmachinerestores"
              "virtualmachinerestores/status"
            ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
              "patch"
            ];
          }
          # Snapshot: main resources (full + deletecollection)
          {
            apiGroups = [ "snapshot.kubevirt.io" ];
            resources = [
              "virtualmachinesnapshots"
              "virtualmachinesnapshotcontents"
              "virtualmachinerestores"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
              "deletecollection"
            ];
          }
          # Snapshot: main resources (no deletecollection)
          {
            apiGroups = [ "snapshot.kubevirt.io" ];
            resources = [
              "virtualmachinesnapshots"
              "virtualmachinesnapshotcontents"
              "virtualmachinerestores"
            ];
            verbs = [
              "get"
              "delete"
              "create"
              "update"
              "patch"
              "list"
              "watch"
            ];
          }
          # Snapshot: main resources (get, list, watch)
          {
            apiGroups = [ "snapshot.kubevirt.io" ];
            resources = [
              "virtualmachinesnapshots"
              "virtualmachinesnapshotcontents"
              "virtualmachinerestores"
            ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Snapshot storage: volumesnapshotclasses
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [ "volumesnapshotclasses" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Snapshot storage: volumesnapshots
          {
            apiGroups = [ "snapshot.storage.k8s.io" ];
            resources = [ "volumesnapshots" ];
            verbs = [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "delete"
            ];
          }
          # Storage: storageclasses
          {
            apiGroups = [ "storage.k8s.io" ];
            resources = [ "storageclasses" ];
            verbs = [
              "get"
              "list"
              "watch"
            ];
          }
          # Subresources: stop, addvolume, removevolume, freeze, unfreeze, reset, softreboot, sev
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/stop"
              "virtualmachineinstances/addvolume"
              "virtualmachineinstances/removevolume"
              "virtualmachineinstances/freeze"
              "virtualmachineinstances/unfreeze"
              "virtualmachineinstances/reset"
              "virtualmachineinstances/softreboot"
              "virtualmachineinstances/sev/setupsession"
              "virtualmachineinstances/sev/injectlaunchsecret"
            ];
            verbs = [ "update" ];
          }
          # Subresources: version, guestfs
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "version"
              "guestfs"
            ];
            verbs = [
              "get"
              "list"
            ];
          }
          # Subresources: console, vnc, portforward, guestosinfo, etc (get)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachineinstances/console"
              "virtualmachineinstances/vnc"
              "virtualmachineinstances/vnc/screenshot"
              "virtualmachineinstances/portforward"
              "virtualmachineinstances/guestosinfo"
              "virtualmachineinstances/filesystemlist"
              "virtualmachineinstances/userlist"
              "virtualmachineinstances/sev/fetchcertchain"
              "virtualmachineinstances/sev/querylaunchmeasurement"
              "virtualmachineinstances/usbredir"
            ];
            verbs = [ "get" ];
          }
          # Subresources: pause, unpause, addvolume, removevolume, freeze, unfreeze, softreboot, reset, sev
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachineinstances/pause"
              "virtualmachineinstances/unpause"
              "virtualmachineinstances/addvolume"
              "virtualmachineinstances/removevolume"
              "virtualmachineinstances/freeze"
              "virtualmachineinstances/unfreeze"
              "virtualmachineinstances/softreboot"
              "virtualmachineinstances/reset"
              "virtualmachineinstances/sev/setupsession"
              "virtualmachineinstances/sev/injectlaunchsecret"
            ];
            verbs = [ "update" ];
          }
          # Subresources: expand-spec, portforward (get)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/expand-spec"
              "virtualmachines/portforward"
            ];
            verbs = [ "get" ];
          }
          # Subresources: start, stop, restart, addvolume, removevolume, memorydump (update)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/start"
              "virtualmachines/stop"
              "virtualmachines/restart"
              "virtualmachines/addvolume"
              "virtualmachines/removevolume"
              "virtualmachines/memorydump"
            ];
            verbs = [ "update" ];
          }
          # Subresources: expand-vm-spec (update)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [ "expand-vm-spec" ];
            verbs = [ "update" ];
          }
          # Subresources: console, vnc, portforward, guestosinfo, etc (get) — duplicate
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachineinstances/console"
              "virtualmachineinstances/vnc"
              "virtualmachineinstances/vnc/screenshot"
              "virtualmachineinstances/portforward"
              "virtualmachineinstances/guestosinfo"
              "virtualmachineinstances/filesystemlist"
              "virtualmachineinstances/userlist"
              "virtualmachineinstances/sev/fetchcertchain"
              "virtualmachineinstances/sev/querylaunchmeasurement"
              "virtualmachineinstances/usbredir"
            ];
            verbs = [ "get" ];
          }
          # Subresources: pause, unpause, addvolume, removevolume, freeze, unfreeze, softreboot, reset, sev — duplicate
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachineinstances/pause"
              "virtualmachineinstances/unpause"
              "virtualmachineinstances/addvolume"
              "virtualmachineinstances/removevolume"
              "virtualmachineinstances/freeze"
              "virtualmachineinstances/unfreeze"
              "virtualmachineinstances/softreboot"
              "virtualmachineinstances/reset"
              "virtualmachineinstances/sev/setupsession"
              "virtualmachineinstances/sev/injectlaunchsecret"
            ];
            verbs = [ "update" ];
          }
          # Subresources: expand-spec, portforward (get) — duplicate
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/expand-spec"
              "virtualmachines/portforward"
            ];
            verbs = [ "get" ];
          }
          # Subresources: start, stop, restart, addvolume, removevolume, memorydump (update) — duplicate
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/start"
              "virtualmachines/stop"
              "virtualmachines/restart"
              "virtualmachines/addvolume"
              "virtualmachines/removevolume"
              "virtualmachines/memorydump"
            ];
            verbs = [ "update" ];
          }
          # Subresources: expand-vm-spec (update) — duplicate
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [ "expand-vm-spec" ];
            verbs = [ "update" ];
          }
          # Subresources: expand-spec, guestosinfo, filesystemlist, userlist, sev (get)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [
              "virtualmachines/expand-spec"
              "virtualmachineinstances/guestosinfo"
              "virtualmachineinstances/filesystemlist"
              "virtualmachineinstances/userlist"
              "virtualmachineinstances/sev/fetchcertchain"
              "virtualmachineinstances/sev/querylaunchmeasurement"
            ];
            verbs = [ "get" ];
          }
          # Subresources: expand-vm-spec (update)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [ "expand-vm-spec" ];
            verbs = [ "update" ];
          }
          # Subresources: virtualmachines/migrate (update)
          {
            apiGroups = [ "subresources.kubevirt.io" ];
            resources = [ "virtualmachines/migrate" ];
            verbs = [ "update" ];
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
              name = "virt-operator";
              labels = podLabels;
              annotations = {
                "openshift.io/required-scc" = "restricted-v2";
              };
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
                    # Created by the kubevirt operator at runtime, not by kix.
                    secretName = kix.untrackedRef "kubevirt-operator-certs";
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
