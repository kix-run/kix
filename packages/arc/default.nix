# GitHub Actions Runner Controller (ARC) — v2.
#
# Migrated from pkgs-fp/arc/ (v1 fixpoint pattern).
# Source: actions/actions-runner-controller Helm chart
# https://github.com/actions/actions-runner-controller
#
# IMPORTANT: This package does NOT contain the ARC controller Deployment or
# runner ScaleSets — those are still Helm-managed (the ARC Helm chart is
# complex, uses webhooks, and has its own CRD lifecycle). This package only
# translates the RAW Kubernetes resources that sit alongside ARC:
#
#   - PriorityClass for runner pods (cluster-scoped)
#   - RBAC for listener restart CronJob (controller namespace)
#   - CronJob to restart stale listener pods (controller namespace)
#   - Runner namespace with optional Velero backup exclusion
#   - KubeVirt RBAC for VM-based runners (runner namespace, conditional)
#   - CronJob to clean up succeeded VMIs (runner namespace, conditional)
#   - PrometheusRule for runner alerting (runner namespace)
#
# Design decisions:
#   - Two namespaces: ARC follows the pattern of separating the controller
#     (arc-system) from the runners (arc-runners). Resources target one or
#     the other based on their function. The scope's namespace is the
#     controller namespace. Runner-namespace resources use mkClusterResource
#     with extra.metadata.namespace to place them in the runner namespace.
#   - PriorityClass as main: Since there's no Deployment or Service we own,
#     `main` is the PriorityClass with requires pulling in everything else.
#     The PriorityClass is cluster-scoped and is the most important resource
#     (ensures runner pods get scheduled).
#   - KubeVirt support is gated via `enableKubevirtSupport`. When disabled,
#     the KubeVirt RBAC and VMI cleanup CronJob are excluded from main's
#     requires, so they exist in the package but aren't in the closure.
#   - Listener restart CronJob: ARC listeners can get stuck in a bad state
#     where they stop picking up jobs. The CronJob deletes listener pods
#     every 5 minutes, and the controller recreates them. This is a known
#     workaround documented in ARC's GitHub issues.
#   - VMI cleanup CronJob: KubeVirt VMIs in "Succeeded" state consume
#     resources and clutter the namespace. Hourly cleanup is sufficient
#     since succeeded VMIs are harmless, just noisy.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    # Runner namespace — where runner pods and KubeVirt VMs are created.
    runnersNamespace = "arc-runners";

    # PriorityClass value. 100 is low — above default (0) but below most
    # workloads. ARC runners are ephemeral and tolerant of preemption,
    # so they shouldn't preempt production workloads.
    priorityClassValue = 100;

    # Whether to create KubeVirt-related RBAC and cleanup CronJobs.
    # Disable if the cluster doesn't have KubeVirt installed.
    enableKubevirtSupport = true;

    # Whether to label the runner namespace for Velero backup exclusion.
    # Runner namespaces contain ephemeral workloads that shouldn't be
    # backed up — it wastes backup storage and slows restores.
    excludeFromBackup = true;

    # Image for CronJob containers. alpine/k8s bundles kubectl and other
    # K8s tools in a small image, perfect for maintenance scripts.
    k8sToolImage = {
      repository = "alpine/k8s";
      tag = "1.33.1";
    };
  };

  # --- Derived values ---
  toolImageRef = "${cfg.k8sToolImage.repository}:${cfg.k8sToolImage.tag}";
  ns = cfg.runnersNamespace;

  # --- Labels ---
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "arc";
  };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    };

  # Component-scoped label helpers. ARC has multiple components
  # (controller-side vs runner-side), so we tag each resource.
  allLabelsWithComponent =
    component:
    allLabels
    // {
      "app.kubernetes.io/component" = component;
    };

in self: {

  # ====================================================================
  # CONTROLLER NAMESPACE RESOURCES (scope's namespace, e.g. arc-system)
  # ====================================================================

  # -- PriorityClass ---------------------------------------------------
  #
  # Cluster-scoped. Ensures runner pods get scheduled with the configured
  # priority. Value=100 is intentionally low — runners are ephemeral and
  # should yield to production workloads.

  priorityClass = scope.mkClusterResource {
    apiVersion = "scheduling.k8s.io/v1";
    kind = "PriorityClass";
    name = "${scope.instanceName}-arc-runners";
    labels = allLabelsWithComponent "scheduling";
    extra = {
      value = cfg.priorityClassValue;
      globalDefault = false;
      description = "Priority class for GitHub Actions runner pods";
    };
  };

  # -- Listener restart RBAC -------------------------------------------
  #
  # The restart CronJob needs permission to list and delete pods in the
  # controller namespace. Scoped to a Role (not ClusterRole) because it
  # only operates on pods in its own namespace.

  listenerRestartSa = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-actions-listener-restart-sa";
    labels = allLabelsWithComponent "listener-restart";
    requires = [ self.listenerRestartRoleBinding ];
  };

  listenerRestartRole = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-actions-listener-restart-role";
    labels = allLabelsWithComponent "listener-restart";
    # Needs to list pods (to find listeners) and delete them
    # (to trigger controller recreation).
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [
          "get"
          "list"
          "delete"
        ];
      }
    ];
  };

  listenerRestartRoleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-actions-listener-restart-rolebinding";
    labels = allLabelsWithComponent "listener-restart";
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.listenerRestartRole}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.listenerRestartSa}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # -- Listener restart CronJob ----------------------------------------
  #
  # Runs every 5 minutes. Finds pods with the listener label and deletes
  # them. The ARC controller will recreate them automatically.
  #
  # Why: ARC listeners occasionally get wedged and stop picking up jobs.
  # This is a known issue (actions/actions-runner-controller#2852 and
  # similar). The restart is safe because listeners are stateless — the
  # controller handles job assignment, not the listener.

  listenerRestartCron = scope.mkResource {
    apiVersion = "batch/v1";
    kind = "CronJob";
    name = "${scope.instanceName}-actions-listener-restart-cron";
    labels = allLabelsWithComponent "listener-restart";
    requires = [ self.listenerRestartSa ];
    spec = {
      schedule = "*/5 * * * *";
      jobTemplate.spec.template.spec = {
        serviceAccountName = "${self.listenerRestartSa}";
        restartPolicy = "Never";
        containers = [
          {
            name = "restart-listeners";
            image = toolImageRef;
            command = [
              "/bin/sh"
              "-c"
            ];
            # Delete listener pods by label (more reliable than grep).
            # The ARC controller labels listener pods with
            # app.kubernetes.io/component=runner-scale-set-listener.
            args = [
              ''
                kubectl delete pods -n ${scope.namespaceName} -l app.kubernetes.io/component=runner-scale-set-listener --wait=false || true
              ''
            ];
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              runAsUser = 999;
            };
          }
        ];
      };
    };
  };

  # ====================================================================
  # RUNNER NAMESPACE RESOURCES (arc-runners)
  #
  # These resources live in the runner namespace, which is different from
  # the scope's namespace. We use mkClusterResource with
  # extra.metadata.namespace to place them in the correct namespace.
  # ====================================================================

  # -- Runner namespace ------------------------------------------------
  #
  # Created explicitly so we can attach the Velero backup exclusion label.
  # Without this, someone would need to manually create the namespace and
  # remember the label — easy to forget during cluster bootstrapping.

  runnerNamespace = scope.mkClusterResource {
    apiVersion = "v1";
    kind = "Namespace";
    name = ns;
    labels =
      allLabelsWithComponent "runners"
      // lib.optionalAttrs cfg.excludeFromBackup {
        # Velero uses this label to exclude namespaces from backup.
        # Runner namespaces are ephemeral — backing them up wastes
        # storage and complicates restores.
        "velero.io/exclude-from-backup" = "true";
      };
  };

  # -- KubeVirt RBAC ---------------------------------------------------
  #
  # These resources enable KubeVirt-based runners. KubeVirt runners spin
  # up full VMs for each CI job, providing better isolation than container
  # runners (no shared kernel). The trade-off is startup time (~30-60s
  # for a VM vs ~5s for a container).
  #
  # The Role grants access to KubeVirt VMs, VMIs, and CDI datavolumes
  # (for VM disk images), plus volumesnapshots (for snapshot-based
  # fast-clone of base images).

  kubevirtRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    name = "${scope.instanceName}-kubevirt-vm-manager";
    labels = allLabelsWithComponent "kubevirt";
    extra.metadata.namespace = ns;
    # Verbs are scoped to what each resource actually needs — the runner
    # workflow creates VMs/VMIs/DVs and reads snapshots, no more.
    # Translated from the Ansible source roles/kubernetes_apps/tasks/actions-runner-controller.yml
    extra.rules = [
      # VMs: the runner creates VMs from templates and deletes them after jobs.
      # Watch/list for the controller to track state.
      {
        apiGroups = [ "kubevirt.io" ];
        resources = [ "virtualmachines" ];
        verbs = [
          "get"
          "watch"
          "list"
        ];
      }
      # VMIs: created by VMs, runners need to watch status and delete completed ones.
      {
        apiGroups = [ "kubevirt.io" ];
        resources = [ "virtualmachineinstances" ];
        verbs = [
          "get"
          "watch"
          "list"
          "create"
          "delete"
        ];
      }
      # CDI DataVolumes: runners clone base images as DataVolumes for each job.
      {
        apiGroups = [ "cdi.kubevirt.io" ];
        resources = [ "datavolumes" ];
        verbs = [
          "get"
          "watch"
          "list"
          "create"
          "delete"
        ];
      }
      # Snapshots: read-only access to volume snapshots used as source
      # for fast-clone base images.
      {
        apiGroups = [ "snapshot.storage.k8s.io" ];
        resources = [ "volumesnapshots" ];
        verbs = [ "get" ];
      }
    ];
  };

  kubevirtSa = scope.mkClusterResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-kubevirt-actions-runner";
    labels = allLabelsWithComponent "kubevirt";
    extra.metadata.namespace = ns;
    requires = [ self.kubevirtRoleBinding ];
  };

  kubevirtRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-kubevirt-vm-manager";
    labels = allLabelsWithComponent "kubevirt";
    extra.metadata.namespace = ns;
    extra.roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "Role";
      name = "${self.kubevirtRole}";
    };
    extra.subjects = [
      {
        kind = "ServiceAccount";
        name = "${self.kubevirtSa}";
        namespace = ns;
      }
    ];
  };

  # -- VMI cleanup RBAC ------------------------------------------------
  #
  # Separate SA for the VMI cleanup CronJob. Uses the same kubevirtRole
  # (needs list/delete on VMIs) but a separate binding so we can audit
  # who is doing what in RBAC logs.

  vmiCleanupSa = scope.mkClusterResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-vmi-cleanup-sa";
    labels = allLabelsWithComponent "vmi-cleanup";
    extra.metadata.namespace = ns;
    requires = [ self.vmiCleanupRoleBinding ];
  };

  vmiCleanupRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    name = "${scope.instanceName}-vmi-cleanup-rolebinding";
    labels = allLabelsWithComponent "vmi-cleanup";
    extra.metadata.namespace = ns;
    # Re-uses the kubevirtRole — the cleanup job needs the same
    # VMI list/delete permissions as the runner SA.
    extra.roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "Role";
      name = "${self.kubevirtRole}";
    };
    extra.subjects = [
      {
        kind = "ServiceAccount";
        name = "${self.vmiCleanupSa}";
        namespace = ns;
      }
    ];
  };

  # -- VMI cleanup CronJob ---------------------------------------------
  #
  # Runs hourly. Finds VMIs in "Succeeded" phase and deletes them.
  # Succeeded VMIs are finished runner jobs — they've completed their
  # work but the VMI object lingers until explicitly deleted. Hourly
  # cleanup is sufficient since succeeded VMIs are harmless, just noisy
  # in `kubectl get vmi` output and consume etcd storage.

  vmiCleanupCron = scope.mkClusterResource {
    apiVersion = "batch/v1";
    kind = "CronJob";
    name = "${scope.instanceName}-vmi-succeeded-cleanup";
    labels = allLabelsWithComponent "vmi-cleanup";
    extra.metadata.namespace = ns;
    requires = [ self.vmiCleanupSa ];
    spec = {
      schedule = "0 * * * *";
      jobTemplate.spec.template.spec = {
        serviceAccountName = "${self.vmiCleanupSa}";
        restartPolicy = "Never";
        containers = [
          {
            name = "cleanup";
            image = toolImageRef;
            command = [
              "/bin/sh"
              "-c"
            ];
            # List VMIs in Succeeded phase via jsonpath and delete them.
            # Uses --wait=false to avoid blocking on VMI finalizers.
            args = [
              ''
                kubectl get vmi -n ${ns} --field-selector=status.phase=Succeeded --no-headers -o custom-columns=NAME:.metadata.name | xargs -r kubectl delete vmi -n ${ns} --wait=false || true
              ''
            ];
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = [ "ALL" ];
              runAsUser = 999;
            };
          }
        ];
      };
    };
  };

  # -- PrometheusRule --------------------------------------------------
  #
  # Alert rules for the Actions runner infrastructure. Uses the
  # Prometheus Operator CRD (monitoring.coreos.com/v1). These rules
  # live in the runner namespace because that's where the runner
  # metrics are scraped from.
  #
  # TODO: Add more rules as we learn what failure modes matter.
  # Current rules are a starting point based on operational experience.

  prometheusRule = scope.mkClusterResource {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "PrometheusRule";
    name = "${scope.instanceName}-actions-runner-rules";
    labels = allLabelsWithComponent "monitoring";
    extra.metadata.namespace = ns;
    # Alert rules translated from the Ansible source:
    # roles/kubernetes_apps/files/actions-runner-alerts.yml
    spec = {
      groups = [
        {
          name = "actions-runner";
          rules = [
            # Container runners: expect at least 2 pods matching "container" in
            # their name, created by the EphemeralRunner controller. If fewer
            # than 2 exist for 5 minutes, something is wrong with ARC scaling.
            {
              alert = "ContainerRunnerPodsMissing";
              expr = ''absent(kube_pod_info{namespace="${ns}", created_by_kind="EphemeralRunner", pod=~".*container.*"}) or count(kube_pod_info{namespace="${ns}", created_by_kind="EphemeralRunner", pod=~".*container.*"}) < 2'';
              "for" = "5m";
              labels.severity = "warning";
              annotations = {
                summary = "GitHub Actions container runner pods missing";
                description = "Fewer than 2 container runner pods found in namespace ${ns}";
              };
            }
            # Ubuntu (KubeVirt VM) runners: same threshold. These are the
            # VM-based runners that provide better isolation for untrusted builds.
            {
              alert = "UbuntuRunnerPodsMissing";
              expr = ''absent(kube_pod_info{namespace="${ns}", created_by_kind="EphemeralRunner", pod=~".*ubuntu.*"}) or count(kube_pod_info{namespace="${ns}", created_by_kind="EphemeralRunner", pod=~".*ubuntu.*"}) < 2'';
              "for" = "5m";
              labels.severity = "warning";
              annotations = {
                summary = "GitHub Actions ubuntu runner pods insufficient";
                description = "Fewer than 2 ubuntu runner pods found in namespace ${ns}";
              };
            }
          ];
        }
      ];
    };
  };

  # -- Main: the public interface --------------------------------------
  #
  # Since this package doesn't own a Deployment or Service (those are
  # Helm-managed), `main` is the PriorityClass — the most universally
  # important resource. All other resources are pulled in via requires.
  #
  # KubeVirt resources are conditionally included via lib.optional,
  # gated by the enableKubevirtSupport flag. When disabled, they exist
  # in the package but aren't part of the closure (won't be rendered).

  main = self.priorityClass // {
    requires =
      [
        # Controller-namespace resources
        self.listenerRestartCron
        self.runnerNamespace
        self.prometheusRule
      ]
      # KubeVirt resources — only included when enableKubevirtSupport=true
      ++ lib.optionals cfg.enableKubevirtSupport [
        self.kubevirtSa
        self.vmiCleanupCron
      ];
  };
}
