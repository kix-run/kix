# Kubernetes Event Logger package — v2.
#
# Migrated from pkgs-fp/event-logger/ (v1 fixpoint pattern).
# This is NOT a Helm chart migration — it's a direct translation of raw K8s
# resources from an Ansible task file.
#
# The event logger watches all Kubernetes events across all namespaces and
# emits them as structured JSON to stdout. This is useful for shipping cluster
# events to a log aggregation system (Loki, Elasticsearch, etc.) via the
# standard container log pipeline.
#
# Architecture:
#   - A ConfigMap holds the Python script (k8s_event_logger.py)
#   - The script runs inside a uv-based Python image (astral-sh/uv)
#   - RBAC grants read-only access to events cluster-wide
#   - No Service is needed — this is a log-producing workload, not a network service
#
# The `main` resource is the Deployment itself (no Service to front it).
# Deploying the closure includes the ConfigMap, RBAC, and the Deployment.

{ scope, config, lib }:

let
  cfg = scope.defaults config {
    # Container image. Using astral-sh/uv which bundles uv + Python.
    # The script uses uv's inline script metadata to install kubernetes
    # and PyYAML at startup — no custom image build needed.
    image = {
      repository = "ghcr.io/astral-sh/uv";
      tag = "python3.12-bookworm-slim";
      pullPolicy = "IfNotPresent";
    };

    replicaCount = 1;

    # Resource limits/requests.
    # The original Ansible playbook sets these values. The event watcher
    # is typically light on CPU but can spike on memory if the cluster
    # generates a lot of events (e.g., during rollouts).
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };
  };

  # --- Derived values ---
  imageRef = "${cfg.image.repository}:${cfg.image.tag}";

  # --- Labels ---
  # Standard label hierarchy: selectorLabels (for matchLabels) ->
  # allLabels (for metadata). Every resource gets managed-by=kix.
  selectorLabels = {
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/name" = "event-logger";
  };

  allLabels =
    selectorLabels
    // {
      "app.kubernetes.io/managed-by" = "kix";
    };

in self: {

  # -- Configuration ------------------------------------------------------
  #
  # The Python script is stored in a ConfigMap and mounted into the pod.
  # This avoids building a custom container image — the script uses uv's
  # inline dependency metadata to install packages at startup.
  #
  # defaultMode 493 (= 0o755) makes the script executable so it can be
  # invoked directly via its shebang line.

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-event-logger";
    labels = allLabels;
    data = {
      "k8s_event_logger.py" = builtins.readFile ./scripts/k8s_event_logger.py;
    };
  };

  # -- RBAC ----------------------------------------------------------------
  #
  # The event logger needs read-only access to events across all namespaces.
  # This is the minimum permission set: get/list/watch on events in the
  # core API group. No write access, no access to other resource types.

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-event-logger";
    labels = allLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [ "events" ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-event-logger";
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
    name = "${scope.instanceName}-event-logger";
    labels = allLabels;
    # Inverted dep: the SA is useless without its binding granting
    # permissions. The binding references the SA (auto-tracked), but
    # the SA must explicitly declare it needs the binding.
    requires = [ self.clusterRoleBinding ];
  };

  # -- Workload ------------------------------------------------------------
  #
  # Single-replica Deployment running the event logger script.
  # The script is mounted from the ConfigMap and executed directly
  # (the shebang invokes uv which handles dependency installation).
  #
  # PYTHONUNBUFFERED=1 ensures log lines are flushed immediately,
  # which is critical for real-time log shipping.

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-event-logger";
    labels = allLabels // {
      "app.kubernetes.io/version" = cfg.image.tag;
    };
    spec = {
      replicas = cfg.replicaCount;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = selectorLabels;
        spec = {
          serviceAccountName = "${self.serviceAccount}";
          containers = [
            {
              name = "event-logger";
              image = imageRef;
              imagePullPolicy = cfg.image.pullPolicy;
              command = [
                "/app/k8s_event_logger.py"
              ];
              env = [
                {
                  # Ensure Python output is unbuffered so log lines
                  # appear immediately in container logs. Without this,
                  # Python buffers stdout and logs can be delayed by
                  # minutes.
                  name = "PYTHONUNBUFFERED";
                  value = "1";
                }
              ];
              inherit (cfg) resources;
              volumeMounts = [
                {
                  name = "scripts";
                  mountPath = "/app";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "scripts";
              configMap = {
                name = "${self.configmap}";
                # 493 decimal = 0o755 octal. Makes the Python script
                # executable so it can be invoked directly via its
                # shebang line. Nix doesn't support octal literals,
                # so we use the decimal equivalent.
                defaultMode = 493;
              };
            }
          ];
        };
      };
    };
  };

  # -- Main: the public interface ------------------------------------------
  #
  # Unlike most packages, the event logger has no Service — it's a pure
  # log-producing workload. The main resource IS the Deployment.

  main = self.deployment;
}
