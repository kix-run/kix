# Kubernetes Event Logger package — fixpoint pattern.
#
# Migrated from Ansible playbook (deploy_k8s_event_logger.yml).
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
# Deploying `main.closure` includes the ConfigMap, RBAC, and the Deployment.

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments (replaces Ansible variables) ---

      # Namespace where all namespaced resources live.
      # The Ansible playbook hardcodes monitoring-system.
      namespace ? "monitoring-system",

      # Container image. Using astral-sh/uv which bundles uv + Python.
      # The script uses uv's inline script metadata to install kubernetes
      # and PyYAML at startup — no custom image build needed.
      image ? {
        repository = "ghcr.io/astral-sh/uv";
        tag = "python3.12-bookworm-slim";
        pullPolicy = "IfNotPresent";
      },

      replicaCount ? 1,

      # Resource limits/requests.
      # The original Ansible playbook sets these values. The event watcher
      # is typically light on CPU but can spike on memory if the cluster
      # generates a lot of events (e.g., during rollouts).
      resources ? {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
      },

      # Cluster-wide labels merged into every resource.
      clusterLabels ? { },

      # Instance name for app.kubernetes.io/instance label.
      instance ? "release-name",
    }:
    self:
    let
      # --- Derived values ---
      imageRef = "${image.repository}:${image.tag}";

      # --- Labels ---
      # Standard label hierarchy: selectorLabels (for matchLabels) ->
      # allLabels (for metadata). Every resource gets managed-by=kix.
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "event-logger";
      };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        };

    in
    {

      # -- Configuration ------------------------------------------------------
      #
      # The Python script is stored in a ConfigMap and mounted into the pod.
      # This avoids building a custom container image — the script uses uv's
      # inline dependency metadata to install packages at startup.
      #
      # defaultMode 493 (= 0o755) makes the script executable so it can be
      # invoked directly via its shebang line.

      configmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "event-logger";
        inherit namespace;
        labels = allLabels;
        data = {
          "k8s_event_logger.py" = builtins.readFile ./scripts/k8s_event_logger.py;
        };
      };

      # -- RBAC ----------------------------------------------------------------
      #
      # YAML ref direction:   binding -> role, binding -> SA
      # Semantic dep direction: SA -> binding -> role
      #
      # The event logger needs read-only access to events across all namespaces.
      # This is the minimum permission set: get/list/watch on events in the
      # core API group. No write access, no access to other resource types.

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "event-logger";
        namespace = null; # cluster-scoped
        labels = allLabels;
        rules = [
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

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "event-logger";
        namespace = null; # cluster-scoped
        labels = allLabels;
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = self.clusterRole.ref; # auto-tracked dep
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.ref; # auto-tracked dep
            inherit namespace;
          }
        ];
      };

      serviceAccount = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "event-logger";
        inherit namespace;
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

      deployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "event-logger";
        inherit namespace;
        labels = allLabels // {
          "app.kubernetes.io/version" = image.tag;
        };
        # The deployment always needs RBAC. The SA is referenced via .ref
        # (auto-tracked), and the SA requires the binding (inverted dep),
        # so the full RBAC chain is in the closure.
        spec = {
          replicas = replicaCount;
          selector.matchLabels = selectorLabels;
          template = {
            metadata.labels = selectorLabels;
            spec = {
              serviceAccountName = self.serviceAccount.ref;
              containers = [
                {
                  name = "event-logger";
                  image = imageRef;
                  imagePullPolicy = image.pullPolicy;
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
                  inherit resources;
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
                    name = self.configmap.ref; # auto-tracked dep
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
      # k8s.withRequires is used (not //) to ensure closure recomputation.
      # The deployment already auto-tracks the configmap (via volume ref)
      # and the serviceAccount (via serviceAccountName ref), so no extra
      # requires are needed here. We use withRequires with an empty list
      # to properly wrap the deployment as the main entry point.

      main = k8s.withRequires [ ] self.deployment;
    }
  )
  {
    # Default arguments
    namespace = "monitoring-system";
  }
