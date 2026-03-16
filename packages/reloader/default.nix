# Reloader package — v2.
#
# Migrated from pkgs-fp/reloader/ (v1 fixpoint pattern).
# Source Helm chart: stakater/reloader
# https://github.com/stakater/Reloader
#
# Reloader is a Kubernetes controller that watches ConfigMaps and Secrets,
# then triggers rolling upgrades on Deployments, DaemonSets, StatefulSets,
# and other workloads when their referenced config changes. It has no
# Service — it's a pure controller, so `main` is the Deployment itself.
#
# Resources:
#   - PriorityClass (cluster-scoped) — ensures Reloader pods get scheduled
#     before lower-priority workloads. This matters because if Reloader is
#     not running when a ConfigMap changes, dependent workloads won't restart.
#   - ServiceAccount + ClusterRole + ClusterRoleBinding — standard RBAC.
#     Reloader needs broad read access across the cluster to watch for
#     config changes, plus update/patch on workloads to trigger rollouts.
#   - Deployment — single-replica controller, stateless.
#
# Design decisions:
#   - No Service resource: Reloader is a controller that watches the K8s API,
#     it doesn't serve traffic. Therefore `main` IS the Deployment directly,
#     not a Service with requires. This differs from CoreDNS/Valkey where
#     `main` is a Service.
#   - PriorityClass is always created: In production you always want Reloader
#     to have scheduling priority. Could be made conditional via requires
#     gating if needed later.
#   - logFormat is exposed as a top-level config option because it's the most
#     commonly changed Helm value (json for structured logging in prod,
#     "" for human readable in dev).

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    image = {
      repository = "ghcr.io/stakater/reloader";
      tag = "v1.3.0";
      pullPolicy = "IfNotPresent";
    };
    replicaCount = 1;
    # Resource requests/limits. The defaults here match the Ansible-driven
    # Helm values from the source cluster: modest requests (10m CPU) with
    # room to burst (500m CPU). Memory limit at 512Mi is generous for
    # Reloader — it typically uses ~50-100Mi, but spikes during large
    # cluster reconciliation loops.
    resources = {
      requests = {
        cpu = "10m";
        memory = "128Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };
    # Log format: "json" for production (structured, parseable by log
    # aggregators like Loki/Elasticsearch), empty string for human-readable.
    # The Helm chart passes this as --log-format flag to the binary.
    logFormat = "json";
    # PriorityClass configuration. Value 2000 is intentionally low —
    # it's above default (0) but well below system-critical (2000000000).
    # preemptionPolicy "PreemptLowerPriority" is the K8s default but we
    # set it explicitly for clarity.
    priorityClass = {
      name = "reloader-priority-class";
      value = 2000;
      preemptionPolicy = "PreemptLowerPriority";
      globalDefault = false;
      description = "Priority class for Reloader controller pods";
    };
  };

  # --- Derived values ---
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";

  # --- Labels ---
  # Standard Kubernetes recommended labels.
  # selectorLabels: used in Deployment selector.matchLabels (immutable).
  # allLabels: superset used on all resources (includes managed-by).
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "reloader";
  };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    };

in self: {

  # -- PriorityClass ────────────────────────────────────────────────
  #
  # Cluster-scoped. Ensures Reloader gets scheduled even under resource
  # pressure. The Deployment references this by name via
  # "${self.priorityClassRes}", so the dependency is auto-tracked.

  # PriorityClass fields (value, preemptionPolicy, etc.) are top-level
  # in the K8s API — they're NOT under spec. We use `extra` to pass them
  # through, since mkResource only knows about spec/data/rules/subjects/etc.
  priorityClassRes = scope.mkClusterResource {
    apiVersion = "scheduling.k8s.io/v1";
    kind = "PriorityClass";
    name = cfg.priorityClass.name;
    labels = allLabels;
    extra = {
      inherit (cfg.priorityClass)
        value
        preemptionPolicy
        globalDefault
        description
        ;
    };
  };

  # -- RBAC ─────────────────────────────────────────────────────────
  #
  # Reloader needs broad cluster-wide read access to detect config
  # changes, plus write access to workloads to trigger rollouts.
  #
  # YAML ref direction:   binding -> role, binding -> SA
  # Semantic dep direction: SA -> binding -> role

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-role";
    labels = allLabels;
    # These rules are taken directly from the Reloader Helm chart.
    # The controller needs:
    #   - Read access to secrets/configmaps (to detect changes)
    #   - Read+write on workloads (to trigger rolling restarts)
    #   - Event creation (to record what it did)
    #   - OpenShift DeploymentConfig + Argo Rollout support
    extra.rules = [
      # Core: watch for config changes
      {
        apiGroups = [ "" ];
        resources = [
          "secrets"
          "configmaps"
        ];
        verbs = [
          "list"
          "get"
          "watch"
        ];
      }
      # Apps: trigger rollouts on standard workloads
      {
        apiGroups = [ "apps" ];
        resources = [
          "deployments"
          "daemonsets"
          "statefulsets"
        ];
        verbs = [
          "list"
          "get"
          "update"
          "patch"
        ];
      }
      # Extensions: legacy API group, still used by some older clusters.
      # Reloader supports both apps/v1 and extensions/v1beta1 workloads.
      {
        apiGroups = [ "extensions" ];
        resources = [
          "deployments"
          "daemonsets"
        ];
        verbs = [
          "list"
          "get"
          "update"
          "patch"
        ];
      }
      # Events: Reloader creates events on workloads to record that
      # it triggered a restart and why (which configmap/secret changed).
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
        ];
      }
      # OpenShift: DeploymentConfig is OpenShift-specific. Included
      # for compatibility even if we don't run OpenShift — the rules
      # are harmless on vanilla K8s (the API group simply doesn't exist).
      {
        apiGroups = [ "apps.openshift.io" ];
        resources = [ "deploymentconfigs" ];
        verbs = [
          "list"
          "get"
          "update"
          "patch"
        ];
      }
      # Argo Rollouts: same story as OpenShift — included for compat.
      # If Argo Rollouts CRD isn't installed, these rules are no-ops.
      {
        apiGroups = [ "argoproj.io" ];
        resources = [ "rollouts" ];
        verbs = [
          "list"
          "get"
          "update"
          "patch"
        ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-role-binding";
    labels = allLabels;
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

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-reloader";
    labels = allLabels;
    # Inverted dep: the SA is useless without its binding granting
    # the cluster role permissions. Without this, deploying just the
    # SA wouldn't pull in the RBAC chain.
    requires = [ self.clusterRoleBinding ];
  };

  # -- Workload ─────────────────────────────────────────────────────
  #
  # Single-replica Deployment. Reloader is stateless — it watches the
  # K8s API server and triggers rollouts. Running multiple replicas
  # would cause duplicate rollout triggers, so replicaCount=1 is the
  # norm. The Helm chart supports scaling, so we expose it anyway.

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-reloader";
    labels = allLabels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    # Explicit requires:
    #   - serviceAccount: referenced via interpolation (auto-tracked), but we
    #     also need the SA's transitive deps (clusterRoleBinding -> role)
    #   - priorityClass: referenced via interpolation in the pod spec
    requires = [
      self.serviceAccount
      self.priorityClassRes
    ];
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = selectorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          priorityClassName = "${self.priorityClassRes}";
          containers = [
            {
              name = "reloader";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              inherit (cfg) resources;
              # Command-line args for the Reloader binary.
              # --log-format=json ensures structured logging for prod.
              # Additional flags could be added here (e.g.,
              # --resources-to-watch, --namespaces-to-watch) but the
              # defaults (watch everything) are correct for our use case.
              args = lib.optional (cfg.logFormat != "") "--log-format=${cfg.logFormat}";
              # Reloader exposes /metrics on port 9090 but we don't
              # create a Service for it (no inbound traffic needed).
              # If Prometheus scraping is desired, add a metrics Service
              # resource and gate it via requires.
              ports = [
                {
                  name = "http";
                  containerPort = 9090;
                  protocol = "TCP";
                }
              ];
            }
          ];
        };
      };
    };
  };

  # -- Main: the public interface ───────────────────────────────────
  #
  # Unlike CoreDNS or Valkey, Reloader has no Service — it's a pure
  # controller that talks to the K8s API server. The "main" resource
  # is therefore the Deployment itself.

  main = self.deployment // {
    requires = [
      self.serviceAccount
      self.priorityClassRes
    ];
  };
}
