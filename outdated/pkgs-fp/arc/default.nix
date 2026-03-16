# GitHub Actions Runner Controller (ARC) — fixpoint pattern.
#
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
#     the other based on their function.
#   - PriorityClass as main: Since there's no Deployment or Service we own,
#     `main` is the PriorityClass with withRequires pulling in everything else.
#     The PriorityClass is cluster-scoped and is the most important resource
#     (ensures runner pods get scheduled).
#   - KubeVirt support is gated via `enableKubevirtSupport`. When disabled,
#     the KubeVirt RBAC and VMI cleanup CronJob are excluded from main's
#     requires, so they exist in the fixpoint but aren't in the closure.
#   - Listener restart CronJob: ARC listeners can get stuck in a bad state
#     where they stop picking up jobs. The CronJob deletes listener pods
#     every 5 minutes, and the controller recreates them. This is a known
#     workaround documented in ARC's GitHub issues.
#   - VMI cleanup CronJob: KubeVirt VMIs in "Succeeded" state consume
#     resources and clutter the namespace. Hourly cleanup is sufficient
#     since succeeded VMIs are harmless, just noisy.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments (replaces Helm values.yaml) ---

      # Controller namespace — where ARC's controller and listener pods run.
      controllerNamespace ? "arc-system",

      # Runner namespace — where runner pods and KubeVirt VMs are created.
      runnersNamespace ? "arc-runners",

      # PriorityClass value. 100 is low — above default (0) but below most
      # workloads. ARC runners are ephemeral and tolerant of preemption,
      # so they shouldn't preempt production workloads.
      priorityClassValue ? 100,

      # Whether to create KubeVirt-related RBAC and cleanup CronJobs.
      # Disable if the cluster doesn't have KubeVirt installed.
      enableKubevirtSupport ? true,

      # Whether to label the runner namespace for Velero backup exclusion.
      # Runner namespaces contain ephemeral workloads that shouldn't be
      # backed up — it wastes backup storage and slows restores.
      excludeFromBackup ? true,

      # Image for CronJob containers. alpine/k8s bundles kubectl and other
      # K8s tools in a small image, perfect for maintenance scripts.
      k8sToolImage ? {
        repository = "alpine/k8s";
        tag = "1.33.1";
      },

      # Cluster-wide labels merged into every resource.
      clusterLabels ? { },

      # Instance name for app.kubernetes.io/instance label.
      instance ? "release-name",
    }:
    self:
    let
      # --- Derived values ---
      toolImageRef = "${k8sToolImage.repository}:${k8sToolImage.tag}";

      # --- Labels ---
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "arc";
      };

      allLabels =
        clusterLabels
        // selectorLabels
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

    in
    {

      # ====================================================================
      # CONTROLLER NAMESPACE RESOURCES (arc-system)
      # ====================================================================

      # -- PriorityClass ---------------------------------------------------
      #
      # Cluster-scoped. Ensures runner pods get scheduled with the configured
      # priority. Value=100 is intentionally low — runners are ephemeral and
      # should yield to production workloads.

      priorityClass = k8s.mkResource {
        apiVersion = "scheduling.k8s.io/v1";
        kind = "PriorityClass";
        name = "arc-runners";
        namespace = null; # cluster-scoped
        labels = allLabelsWithComponent "scheduling";
        extra = {
          value = priorityClassValue;
          globalDefault = false;
          description = "Priority class for GitHub Actions runner pods";
        };
      };

      # -- Listener restart RBAC -------------------------------------------
      #
      # The restart CronJob needs permission to list and delete pods in the
      # controller namespace. Scoped to a Role (not ClusterRole) because it
      # only operates on pods in its own namespace.

      listenerRestartSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "actions-listener-restart-sa";
        namespace = controllerNamespace;
        labels = allLabelsWithComponent "listener-restart";
        requires = [ self.listenerRestartRoleBinding ];
      };

      listenerRestartRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "actions-listener-restart-role";
        namespace = controllerNamespace;
        labels = allLabelsWithComponent "listener-restart";
        rules = [
          # Needs to list pods (to find listeners) and delete them
          # (to trigger controller recreation).
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

      listenerRestartRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "actions-listener-restart-rolebinding";
        namespace = controllerNamespace;
        labels = allLabelsWithComponent "listener-restart";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.listenerRestartRole.ref;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.listenerRestartSa.ref;
            namespace = controllerNamespace;
          }
        ];
      };

      # -- Listener restart CronJob ----------------------------------------
      #
      # Runs every 5 minutes. Finds pods with "listener" in the name and
      # deletes them. The ARC controller will recreate them automatically.
      #
      # Why: ARC listeners occasionally get wedged and stop picking up jobs.
      # This is a known issue (actions/actions-runner-controller#2852 and
      # similar). The restart is safe because listeners are stateless — the
      # controller handles job assignment, not the listener.
      #
      # The script uses `kubectl get pods` with grep to find listener pods,
      # then `kubectl delete pod` to remove them. Simple and reliable.

      listenerRestartCron = k8s.mkResource {
        apiVersion = "batch/v1";
        kind = "CronJob";
        name = "actions-listener-restart-cron";
        namespace = controllerNamespace;
        labels = allLabelsWithComponent "listener-restart";
        requires = [ self.listenerRestartSa ];
        spec = {
          schedule = "*/5 * * * *";
          jobTemplate.spec.template.spec = {
            serviceAccountName = self.listenerRestartSa.ref;
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
                    kubectl delete pods -n ${controllerNamespace} -l app.kubernetes.io/component=runner-scale-set-listener --wait=false || true
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
      # ====================================================================

      # -- Runner namespace ------------------------------------------------
      #
      # Created explicitly so we can attach the Velero backup exclusion label.
      # Without this, someone would need to manually create the namespace and
      # remember the label — easy to forget during cluster bootstrapping.

      runnerNamespace = k8s.mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        name = runnersNamespace;
        namespace = null; # Namespace is cluster-scoped
        labels =
          allLabelsWithComponent "runners"
          // lib.optionalAttrs excludeFromBackup {
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

      kubevirtRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "kubevirt-vm-manager";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "kubevirt";
        # Verbs are scoped to what each resource actually needs — the runner
        # workflow creates VMs/VMIs/DVs and reads snapshots, no more.
        # Translated from the Ansible source roles/kubernetes_apps/tasks/actions-runner-controller.yml
        rules = [
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

      kubevirtSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "kubevirt-actions-runner";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "kubevirt";
        requires = [ self.kubevirtRoleBinding ];
      };

      kubevirtRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "kubevirt-vm-manager";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "kubevirt";
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.kubevirtRole.ref;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.kubevirtSa.ref;
            namespace = runnersNamespace;
          }
        ];
      };

      # -- VMI cleanup RBAC ------------------------------------------------
      #
      # Separate SA for the VMI cleanup CronJob. Uses the same kubevirtRole
      # (needs list/delete on VMIs) but a separate binding so we can audit
      # who is doing what in RBAC logs.

      vmiCleanupSa = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "vmi-cleanup-sa";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "vmi-cleanup";
        requires = [ self.vmiCleanupRoleBinding ];
      };

      vmiCleanupRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "vmi-cleanup-rolebinding";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "vmi-cleanup";
        # Re-uses the kubevirtRole — the cleanup job needs the same
        # VMI list/delete permissions as the runner SA.
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = self.kubevirtRole.ref;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.vmiCleanupSa.ref;
            namespace = runnersNamespace;
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

      vmiCleanupCron = k8s.mkResource {
        apiVersion = "batch/v1";
        kind = "CronJob";
        name = "vmi-succeeded-cleanup";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "vmi-cleanup";
        requires = [ self.vmiCleanupSa ];
        spec = {
          schedule = "0 * * * *";
          jobTemplate.spec.template.spec = {
            serviceAccountName = self.vmiCleanupSa.ref;
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
                    kubectl get vmi -n ${runnersNamespace} --field-selector=status.phase=Succeeded --no-headers -o custom-columns=NAME:.metadata.name | xargs -r kubectl delete vmi -n ${runnersNamespace} --wait=false || true
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

      prometheusRule = k8s.mkResource {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "PrometheusRule";
        name = "actions-runner-rules";
        namespace = runnersNamespace;
        labels = allLabelsWithComponent "monitoring";
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
                  expr = ''absent(kube_pod_info{namespace="${runnersNamespace}", created_by_kind="EphemeralRunner", pod=~".*container.*"}) or count(kube_pod_info{namespace="${runnersNamespace}", created_by_kind="EphemeralRunner", pod=~".*container.*"}) < 2'';
                  "for" = "5m";
                  labels.severity = "warning";
                  annotations = {
                    summary = "GitHub Actions container runner pods missing";
                    description = "Fewer than 2 container runner pods found in namespace ${runnersNamespace}";
                  };
                }
                # Ubuntu (KubeVirt VM) runners: same threshold. These are the
                # VM-based runners that provide better isolation for untrusted builds.
                {
                  alert = "UbuntuRunnerPodsMissing";
                  expr = ''absent(kube_pod_info{namespace="${runnersNamespace}", created_by_kind="EphemeralRunner", pod=~".*ubuntu.*"}) or count(kube_pod_info{namespace="${runnersNamespace}", created_by_kind="EphemeralRunner", pod=~".*ubuntu.*"}) < 2'';
                  "for" = "5m";
                  labels.severity = "warning";
                  annotations = {
                    summary = "GitHub Actions ubuntu runner pods insufficient";
                    description = "Fewer than 2 ubuntu runner pods found in namespace ${runnersNamespace}";
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
      # important resource. All other resources are pulled in via
      # withRequires.
      #
      # KubeVirt resources are conditionally included via lib.optional,
      # gated by the enableKubevirtSupport flag. When disabled, they exist
      # in the fixpoint but aren't part of the closure (won't be rendered).

      main = k8s.withRequires (
        [
          # Controller-namespace resources
          self.listenerRestartCron
          self.runnerNamespace
          self.prometheusRule
        ]
        # KubeVirt resources — only included when enableKubevirtSupport=true
        ++ lib.optionals enableKubevirtSupport [
          self.kubevirtSa
          self.vmiCleanupCron
        ]
      ) self.priorityClass;
    }
  )
  {
    # Default arguments — the minimal set needed to deploy.
    controllerNamespace = "arc-system";
    runnersNamespace = "arc-runners";
  }
