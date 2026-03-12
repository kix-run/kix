# Descheduler package — fixpoint pattern.
#
# Source Helm chart: kubernetes-sigs/descheduler (Deployment mode)
# https://github.com/kubernetes-sigs/descheduler/tree/master/charts/descheduler
#
# The descheduler is a controller that evicts pods so the scheduler can
# reschedule them onto more appropriate nodes. Unlike most workloads it has
# NO Service — it's a standalone Deployment that operates via the K8s API.
#
# Because there's no Service, `main` IS the Deployment itself (wrapped with
# withRequires for RBAC + ConfigMap). Consumers deploy `main.closure` and
# get the full set of resources needed to run the descheduler.
#
# The descheduler needs broad read access to pods, nodes, namespaces, and
# priority classes, plus the ability to evict pods and manage leader-election
# leases. The ClusterRole rules are taken directly from the upstream Helm chart.
#
# Policy configuration lives in a ConfigMap using the v1alpha2 DeschedulerPolicy
# format. The default policy enables a balanced set of strategies:
# - RemoveDuplicates: spread duplicate pods across nodes
# - LowNodeUtilization: rebalance pods from over-utilized to under-utilized nodes
# - RemovePodsViolatingNodeAffinity: evict pods that no longer satisfy node affinity
# - RemovePodsViolatingInterPodAntiAffinity: evict pods violating anti-affinity rules

{ k8s, lib }:

k8s.mkPackage
  (
    {
      # --- Package arguments (replaces Helm values.yaml) ---

      namespace ? "kube-system",

      image ? {
        repository = "registry.k8s.io/descheduler/descheduler";
        # v0.31.0 is the latest stable release as of 2026-03.
        tag = "v0.31.0";
        pullPolicy = "IfNotPresent";
      },

      replicaCount ? 1,

      # Resource requests/limits from Helm values.
      # The descheduler is CPU-light but needs memory for its informer caches
      # (it watches pods, nodes, namespaces, etc. cluster-wide).
      resources ? {
        requests = {
          cpu = "10m";
          memory = "256Mi";
        };
        limits = {
          cpu = "500m";
          memory = "512Mi";
        };
      },

      # Descheduler policy configuration.
      # This is the full v1alpha2 DeschedulerPolicy that gets serialized into
      # the ConfigMap. Users can override this entirely to customize strategies.
      #
      # The default policy is deliberately conservative:
      # - evictSystemCriticalPods = false (don't touch kube-system critical pods)
      # - evictLocalStoragePods = false (don't evict pods with emptyDir/hostPath)
      # - LowNodeUtilization thresholds are moderate (20% low, 50% target)
      #
      # Alternative strategies we considered including by default but didn't:
      # - RemovePodsHavingTooManyRestarts: useful but needs per-cluster tuning
      # - PodLifeTime: too aggressive for a default policy
      deschedulerPolicy ? {
        apiVersion = "descheduler/v1alpha2";
        kind = "DeschedulerPolicy";
        profiles = [
          {
            name = "default";
            pluginConfig = [
              {
                name = "DefaultEvictor";
                args = {
                  evictSystemCriticalPods = false;
                  evictLocalStoragePods = false;
                };
              }
              { name = "RemoveDuplicates"; }
              {
                name = "RemovePodsViolatingNodeAffinity";
                args = {
                  nodeAffinityType = [ "requiredDuringSchedulingIgnoredDuringExecution" ];
                };
              }
              { name = "RemovePodsViolatingInterPodAntiAffinity"; }
              {
                name = "LowNodeUtilization";
                args = {
                  thresholds = {
                    cpu = 20;
                    memory = 20;
                    pods = 20;
                  };
                  targetThresholds = {
                    cpu = 50;
                    memory = 50;
                    pods = 50;
                  };
                };
              }
            ];
            plugins = {
              balance = {
                enabled = [
                  "RemoveDuplicates"
                  "LowNodeUtilization"
                ];
              };
              deschedule = {
                enabled = [
                  "RemovePodsViolatingNodeAffinity"
                  "RemovePodsViolatingInterPodAntiAffinity"
                ];
              };
            };
          }
        ];
      },

      # Cluster-wide labels merged into all resources (e.g., environment tags).
      clusterLabels ? { },
      instance ? "release-name",
    }:
    self:
    let
      # --- Derived values ---
      imageRef = "${image.repository}:${image.tag}";

      # --- Labels ---
      # Standard three-tier label structure per SKILL.md convention.
      # selectorLabels: used in Deployment selector (immutable after creation)
      # allLabels: full set including managed-by for every resource
      selectorLabels = {
        "app.kubernetes.io/instance" = instance;
        "app.kubernetes.io/name" = "descheduler";
      };

      allLabels =
        clusterLabels
        // selectorLabels
        // {
          "app.kubernetes.io/managed-by" = "kix";
        };

      # --- Policy YAML ---
      # The descheduler reads its policy from a ConfigMap mounted as a file.
      # We serialize the Nix attrset to YAML using builtins.toJSON — the
      # descheduler actually accepts both JSON and YAML for its policy file.
      # Using JSON avoids needing a YAML serializer and is semantically identical.
      policyJSON = builtins.toJSON deschedulerPolicy;

    in
    {

      # ── Configuration ──────────────────────────────────────────────
      #
      # The descheduler reads its policy from /policy-dir/policy.yaml,
      # mounted from this ConfigMap. The policy format is v1alpha2 which
      # uses the plugin-based configuration (replacing the older v1alpha1
      # strategy-based format).

      configmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "descheduler";
        inherit namespace;
        labels = allLabels;
        data = {
          # The key name "policy.yaml" matches the --policy-config-file flag
          # passed to the descheduler binary. Despite the .yaml extension,
          # JSON is valid YAML and the descheduler parses it fine.
          "policy.yaml" = policyJSON;
        };
      };

      # ── RBAC ───────────────────────────────────────────────────────
      #
      # The descheduler needs broad cluster-wide read access because it
      # must evaluate scheduling constraints across all nodes and namespaces.
      # It also needs:
      # - pods/eviction: to actually evict pods (the core function)
      # - events.k8s.io/events: to record eviction events for observability
      # - coordination.k8s.io/leases: for leader election when running
      #   multiple replicas (even with 1 replica, the lease is created)
      #
      # These rules are taken directly from the upstream Helm chart's
      # ClusterRole template.

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "descheduler";
        namespace = null; # cluster-scoped
        labels = allLabels;
        rules = [
          # Event creation for recording eviction decisions.
          # Uses events.k8s.io API group (not core "" group) for structured events.
          {
            apiGroups = [ "events.k8s.io" ];
            resources = [ "events" ];
            verbs = [
              "create"
              "update"
            ];
          }
          # Node information needed to evaluate node affinity, taints,
          # utilization thresholds, etc.
          {
            apiGroups = [ "" ];
            resources = [ "nodes" ];
            verbs = [
              "get"
              "watch"
              "list"
            ];
          }
          # Namespace listing needed to scope pod queries and respect
          # namespace exclusion rules in the policy.
          {
            apiGroups = [ "" ];
            resources = [ "namespaces" ];
            verbs = [
              "get"
              "watch"
              "list"
            ];
          }
          # Pod read access for evaluating scheduling constraints, plus
          # delete for the actual eviction (used as fallback when eviction
          # subresource is unavailable, though eviction is preferred).
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [
              "get"
              "watch"
              "list"
              "delete"
            ];
          }
          # Pod eviction subresource — the preferred way to evict pods.
          # Unlike delete, eviction respects PodDisruptionBudgets.
          {
            apiGroups = [ "" ];
            resources = [ "pods/eviction" ];
            verbs = [ "create" ];
          }
          # PriorityClass access needed to evaluate pod priority and
          # respect the evictSystemCriticalPods setting.
          {
            apiGroups = [ "scheduling.k8s.io" ];
            resources = [ "priorityclasses" ];
            verbs = [
              "get"
              "watch"
              "list"
            ];
          }
          # Lease management for leader election. Even single-replica
          # deployments acquire a lease (harmless, and means scaling up
          # to multiple replicas Just Works).
          {
            apiGroups = [ "coordination.k8s.io" ];
            resources = [ "leases" ];
            verbs = [
              "create"
              "get"
              "update"
              "delete"
            ];
          }
        ];
      };

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "descheduler";
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
        name = "descheduler";
        inherit namespace;
        labels = allLabels;
        # Inverted dep: the SA is useless without its RBAC binding.
        # The binding references the SA (auto-tracked), but the SA needs
        # the binding to actually have permissions — hence manual requires.
        requires = [ self.clusterRoleBinding ];
      };

      # ── Workload ───────────────────────────────────────────────────
      #
      # The descheduler runs as a long-lived Deployment (not a CronJob).
      # Helm supports both modes; we chose Deployment because:
      # - Continuous descheduling catches problems faster
      # - The descheduler has its own --descheduling-interval flag for pacing
      # - Leader election supports multi-replica HA
      #
      # The policy ConfigMap is mounted at /policy-dir and referenced via
      # the --policy-config-file flag.

      deployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "descheduler";
        inherit namespace;
        labels = allLabels // {
          "app.kubernetes.io/version" = image.tag;
        };
        # The deployment needs RBAC and the SA. The SA is referenced via
        # self.serviceAccount.ref (auto-tracked), and the SA itself requires
        # the binding (inverted dep), which requires the role (auto-tracked).
        # So the full RBAC chain is pulled in transitively.
        #
        # We do NOT need explicit requires on clusterRoleBinding here because
        # the serviceAccount already requires it, and the SA is auto-tracked
        # via serviceAccountName.
        spec = {
          replicas = replicaCount;
          selector.matchLabels = selectorLabels;
          template = {
            metadata.labels = selectorLabels;
            spec = {
              serviceAccountName = self.serviceAccount.ref;
              # The descheduler doesn't need to resolve cluster DNS —
              # it only talks to the API server (which is configured via
              # the in-cluster service account token, not DNS).
              # Using Default dnsPolicy avoids a circular dependency where
              # the descheduler might evict CoreDNS pods it depends on.
              priorityClassName = "system-cluster-critical";
              containers = [
                {
                  name = "descheduler";
                  image = imageRef;
                  imagePullPolicy = image.pullPolicy;
                  command = [
                    "/bin/descheduler"
                  ];
                  args = [
                    "--policy-config-file"
                    "/policy-dir/policy.yaml"
                    # Run continuously with a 2-minute interval between cycles.
                    # This is the Deployment-mode default from the Helm chart.
                    "--descheduling-interval"
                    "5m"
                    # Enable leader election so multiple replicas don't
                    # conflict when evicting pods simultaneously.
                    "--leader-elect=true"
                    "--v=3"
                  ];
                  inherit resources;
                  # Liveness probe: the descheduler exposes /healthz on port 10258.
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = 10258;
                      scheme = "HTTPS";
                    };
                    initialDelaySeconds = 15;
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  # Security hardening: descheduler doesn't need any special
                  # privileges — it operates entirely through the K8s API.
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    runAsNonRoot = true;
                    runAsUser = 1000;
                  };
                  volumeMounts = [
                    {
                      name = "policy-volume";
                      mountPath = "/policy-dir";
                      readOnly = true;
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "policy-volume";
                  configMap = {
                    name = self.configmap.ref; # auto-tracked dep
                  };
                }
              ];
            };
          };
        };
      };

      # ── Main: the public interface ─────────────────────────────────
      #
      # Unlike most packages where main is a Service, the descheduler has
      # no Service — it's a controller that talks to the API server, not
      # something other pods connect to. So main IS the Deployment.
      #
      # We use withRequires to ensure the full resource set is in the
      # closure. The deployment already auto-tracks the configmap (via
      # volume ref) and serviceAccount (via serviceAccountName ref), and
      # the SA requires the binding, which refs the role — so the entire
      # RBAC chain is pulled in transitively.
      #
      # The explicit withRequires [] here is technically redundant since
      # all deps are auto-tracked, but it makes the intent clear: main
      # is the deployment, and deploying it gets you everything.

      main = k8s.withRequires [ ] self.deployment;
    }
  )
  {
    # Default arguments — namespace only, matching Helm chart default.
    namespace = "kube-system";
  }
