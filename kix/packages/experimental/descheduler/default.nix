# descheduler: runs the Kubernetes descheduler, which evicts pods that break
# their placement rules or crowd busy nodes, through the eviction API, so the
# scheduler places them again and PodDisruptionBudgets hold. root = the
# Deployment.
#
# Installs a ServiceAccount; ConfigMap <name>-policy with the policy; a
# ClusterRole and ClusterRoleBinding <name>-<namespace> for the nodes, pods,
# claims, namespaces, PDBs, and PriorityClasses the descheduler reads, the
# evictions it creates, and its Events; a Role and RoleBinding
# <name>-leader-election for its Lease; and the Deployment. With the optional
# `prometheus` dep and `metrics.enabled`, also Service <name>-metrics and a
# ServiceMonitor that scrapes it over HTTPS.
#
# The policy (`policy`, typed in policy.nix) goes into the ConfigMap; a
# change rolls the pods through a checksum annotation, because the binary
# reads the file once at startup. Leader election is always on, with the
# Lease named after the instance in the instance's namespace, so the
# replicas the availability level gives run the policy one at a time.
#
# A KubernetesMetrics entry in `policy.metricsProviders` reads
# metrics.k8s.io, so evaluation refuses it on a cluster that binds the
# metricsApi role absent with no metrics-server instance.
#
# No dependency or option is required:
#
#   instances.descheduler.descheduler = {
#     package = packages.experimental.descheduler;
#     # config.policy.profiles.default.pluginConfig.LowNodeUtilization.thresholds.cpu = 30;
#   };
#
# `out`: `version`, the descheduler version `image.tag` names, beyond what
# root (the Deployment) provides; no package depends on the descheduler.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   DeschedulerDown (warning)  no replica answers a scrape, so pods that
#                              break their placement rules stay where they
#                              are.
# Failed evictions are not an alert: the descheduler counts a
# PodDisruptionBudget's refusal as an error in
# `descheduler_pods_evicted_total`, and that refusal is the budget working.
# Its other metrics (evictions and loop durations) are for dashboards.
#
# Escape hatches: `extraArgs` for flags (the flags the package sets from
# other options are refused), and `partsOverlays` replacing the
# `policyConfigMap` part for policy fields policy.nix does not declare.
#
# Never evicted by default: pods with an emptyDir, hostPath, or
# PersistentVolumeClaim volume, system-critical pods, DaemonSet pods, and
# failed bare pods. Many Kix workloads mount an emptyDir at /tmp
# (kix.mount.emptyDir), so the default profile moves few of them; the
# `policy` description shows a profile that opts a selected workload in.
# Every profile that enables RemovePodsViolatingNodeTaints leaves the taint
# `kubectl cordon` adds alone, so a cordon does not drain the node.
#
# DefaultEvictor's nodeFit is on, so a pod is evicted only when another node
# could run it. On a single-node cluster nothing is ever evicted, and each
# run logs "pod does not fit on any other node" at Info for every candidate.
#
# Version bump: the policy types mirror upstream by hand and upstream
# publishes no schema. In a descheduler clone, read
#
#   git diff v0.36.0 v<new> -- pkg/api/types.go pkg/api/v1alpha2/types.go \
#     pkg/framework/plugins/{defaultevictor,nodeutilization,podlifetime,removeduplicates,removefailedpods,removepodshavingtoomanyrestarts,removepodsviolatinginterpodantiaffinity,removepodsviolatingnodeaffinity,removepodsviolatingnodetaints,removepodsviolatingtopologyspreadconstraint}/{types,validation}.go \
#     pkg/descheduler/setupplugins.go cmd/descheduler/app/options/options.go
#
# and mirror each change in policy.nix (types, enums, checkPolicy) or in the
# owned flags below, or add it to policy.nix's "Not declared" list. Then
# resolve the image digest again.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "0.36.0";
  name = scope.instanceName;
  ns = scope.namespaceName;
  policyLib = import ./policy.nix { inherit lib; };
  metricsPort = 10258;
  policyDir = "/policy-dir";
in
{
  meta = {
    version = release;
    owner = "platform";
    description = "Kubernetes descheduler, which evicts pods that break their placement rules or crowd busy nodes so the scheduler can place them again";
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/descheduler/descheduler";
      tag = "v${release}";
      digest = "sha256:7ca92c0a7b4f1c51d306409da6b832005fcadb224e384795646376726734c6e5";
    };

    deschedulingInterval = lib.mkOption {
      type = policyLib.duration;
      default = "5m";
      description = "Time between two descheduler runs (--descheduling-interval), a Go duration such as \"5m\" or \"90s\". Must be greater than zero.";
    };

    policy = lib.mkOption {
      type = policyLib.policyType;
      default = { };
      defaultText = lib.literalMD "profile `default`: balance RemoveDuplicates, RemovePodsViolatingTopologySpreadConstraint, and LowNodeUtilization (thresholds 20, targetThresholds 50 for cpu, memory, and pods); deschedule RemovePodsHavingTooManyRestarts (100, init containers included), RemovePodsViolatingNodeTaints (excluding `node.kubernetes.io/unschedulable`), RemovePodsViolatingNodeAffinity (required), and RemovePodsViolatingInterPodAntiAffinity";
      example = lib.literalExpression ''
        {
          profiles.default.pluginConfig.LowNodeUtilization.thresholds.cpu = 30;
          profiles.spread-tmp = {
            plugins.balance.enabled = [ "RemovePodsViolatingTopologySpreadConstraint" ];
            pluginConfig.DefaultEvictor = {
              labelSelector.matchLabels."app.kubernetes.io/name" = "web";
              podProtections.defaultDisabled = [ "PodsWithLocalStorage" ];
            };
          };
        }
      '';
      description = ''
        The DeschedulerPolicy, typed field by field with upstream's names;
        the package adds `apiVersion` and `kind`. Profiles run in name order.

        Every profile gets DefaultEvictor `nodeFit = true` and
        `podProtections.extraEnabled = [ "PodsWithPVC" ]`; the binary's own
        protections (PodsWithLocalStorage, DaemonSetPods, SystemCriticalPods,
        and FailedBarePods) stay on. So a pod with an emptyDir, hostPath, or
        PersistentVolumeClaim volume is never evicted. The example's
        `spread-tmp` profile lets the topology-spread plugin move one
        selected workload whose emptyDir holds nothing worth keeping.

        A profile that enables RemovePodsViolatingNodeTaints gets
        `excludedTaints = [ "node.kubernetes.io/unschedulable" ]` while its
        `includedTaints` is empty, so `kubectl cordon` does not drain the
        node. Setting `excludedTaints` replaces that list; keep
        `"node.kubernetes.io/unschedulable"` in yours to keep that.

        Each value of profile `default` is a default of its own:
        `thresholds.cpu = 30` keeps the other thresholds, while
        `plugins.balance.enabled = [ … ]` replaces that list.
        `profiles = lib.mkForce { mine = { … }; }` replaces the default
        profile; the safety defaults above still apply. An `extraEnabled`
        list adds to PodsWithPVC; removing it takes `lib.mkForce`.

        A profile's `pluginConfig` renders DefaultEvictor and the plugins
        that profile enables. Settings of a plugin it does not enable are
        left out of the ConfigMap.

        For a field a newer image accepts and this option does not declare,
        replace the `policyConfigMap` part through `partsOverlays` with a
        ConfigMap of the same name holding your own `policy.yaml`; the mount
        and the rollout checksum follow it.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--v=4"
        "--client-connection-qps=20"
      ];
      description = "Flags appended after the package's own, which include `--v=3` (a later `--v` wins). `--dry-run` also turns leader election off in the binary. Flags the package sets from other options are refused.";
    };

    # No CPU limit, as in upstream's own Deployment
    # (kubernetes/deployment/deployment.yaml).
    resources = kix.options.resources {
      requests = {
        cpu = "500m";
        memory = "256Mi";
      };
      limits.memory = "256Mi";
    };

    metrics = kix.options.monitor;
  };

  config =
    { ... }:
    {
      policy.profiles = policyLib.defaultProfile;
    };

  assertions =
    { config, ... }:
    map
      (message: {
        assertion = false;
        inherit message;
      })
      (
        lib.optional (builtins.match ".*[1-9].*" config.deschedulingInterval == null)
          "deschedulingInterval is \"${config.deschedulingInterval}\"; it must be greater than zero, because leader election is on and the descheduler exits at startup otherwise."
        ++ policyLib.checkPolicy config.policy
      );

  build = [
    (
      {
        self,
        config,
        prometheus ? null,
        ...
      }:
      let
        who = "descheduler ${scope.namespaceName}/${name}";

        inherit (scope.rbac)
          core
          group
          grant
          watch
          emit
          allow
          sub
          restrictTo
          mkClusterRoleSet
          mkRoleSet
          ;
        events = group "events.k8s.io" [ "events" ];
        scheduling = group "scheduling.k8s.io" [ "priorityclasses" ];
        policyGroup = group "policy" [ "poddisruptionbudgets" ];
        metricsGroup = group "metrics.k8s.io" [
          "nodes"
          "pods"
        ];
        coordination = group "coordination.k8s.io" [ "leases" ];

        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];

        baseArgs = [
          "--policy-config-file=${policyDir}/policy.yaml"
          "--descheduling-interval=${config.deschedulingInterval}"
          "--leader-elect=true"
          "--leader-elect-resource-name=${name}"
          # Upstream defaults the Lease to kube-system; the instance's
          # namespace keeps the Lease and its Role with the instance.
          "--leader-elect-resource-namespace=${scope.namespaceName}"
          "--v=3"
        ]
        ++ lib.optional (!config.metrics.enabled) "--disable-metrics";

        leaderElection = "leader election follows the instance's availability level; remove it.";
        args =
          baseArgs
          ++ kix.guardArgs {
            inherit who;
            owned = {
              "--policy-config-file" = "set policy instead.";
              "--descheduling-interval" = "set deschedulingInterval instead.";
              "--leader-elect" = leaderElection;
              "--leader-elect-resource-name" = leaderElection;
              "--leader-elect-resource-namespace" = leaderElection;
              "--leader-elect-resource-lock" = leaderElection;
              "--secure-port" =
                "the probes and the ServiceMonitor need the metrics server on 0.0.0.0:${toString metricsPort}; remove it.";
              "--bind-address" =
                "the probes and the ServiceMonitor need the metrics server on 0.0.0.0:${toString metricsPort}; remove it.";
              "--disable-metrics" = "set metrics.enabled = false instead.";
            };
          } config.extraArgs;
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };

        # A KubernetesMetrics provider makes the descheduler read
        # metrics.k8s.io, which the cluster's metricsApi role must serve.
        policyConfigMap =
          builtins.seq
            (
              if config.policy.metricsProviders != [ ] then
                scope.requireMetricsApi "policy.metricsProviders (KubernetesMetrics)"
              else
                null
            )
            (
              scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "${name}-policy";
                data."policy.yaml" = builtins.toJSON (policyLib.render config.policy);
              }
            );

        policyMount = kix.mount.configMap self.policyConfigMap {
          mountPath = policyDir;
          readOnly = true;
        };

        deployment =
          {
            inherit name;
            spec = {
              replicas = kix.availability.pick availability {
                none = 1;
                pod = 1;
                node = 2;
                zone = 2;
              };
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.annotations."checksum/policy" = self.policyConfigMap.out.contentHash;
                spec = {
                  serviceAccount = self.serviceAccount;
                  # SIGTERM cancels the run in progress and releases the
                  # Lease. 30 is the Kubernetes default, written out because
                  # the reliability.gracefulShutdown scorecard rule reports a
                  # pod spec without the field.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "descheduler";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      command = [ "/bin/descheduler" ];
                      inherit args;
                      ports = [ (kix.port "metrics" metricsPort) ];
                      livenessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "metrics";
                          scheme = "HTTPS";
                        };
                        initialDelaySeconds = 3;
                        periodSeconds = 10;
                      };
                      readinessProbe = {
                        httpGet = {
                          path = "/healthz";
                          port = "metrics";
                          scheme = "HTTPS";
                        };
                        periodSeconds = 10;
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [ self.policyMount ]
          |> scope.mkDeployment;

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment |> kix.service.fromWorkload { name = "${name}-metrics"; } |> scope.mkResource
          else
            null;

        root = {
          resource = self.deployment;
          out.version = kix.image.version config.image;
        };
      }
      // mkClusterRoleSet scope {
        inherit subjects;
        labels = scope.selectorLabels;
        roles."${name}-${scope.namespaceName}" = grant (
          [
            # The event recorder creates and patches events.k8s.io Events
            # and never updates them, so `update` (in upstream's role) is
            # left out.
            (events.events |> emit)
            (
              [
                core.nodes
                core.namespaces
                core.pods
                core.persistentvolumeclaims
                scheduling.priorityclasses
                policyGroup.poddisruptionbudgets
              ]
              |> watch
            )
            (core.pods |> sub "eviction" |> allow [ "create" ])
          ]
          ++ lib.optional (config.policy.metricsProviders != [ ]) (
            [
              metricsGroup.nodes
              metricsGroup.pods
            ]
            |> allow [
              "get"
              "list"
            ]
          )
        );
      }
      // mkRoleSet scope {
        inherit subjects;
        labels = scope.selectorLabels;
        roles."${name}-leader-election" = grant [
          (coordination.leases |> allow [ "create" ])
          (
            coordination.leases
            |> restrictTo [ name ]
            |> allow [
              "get"
              "update"
            ]
          )
        ];
      }
    )

    # /metrics is served only on the secure port, with a self-signed
    # certificate and no client authentication, so the scrape skips
    # verification.
    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        scheme = "https";
        tlsConfig.insecureSkipVerify = true;
        alerts.DeschedulerDown = {
          expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
          "for" = "10m";
          severity = "warning";
          summary = "The descheduler is down.";
          description = "No replica of the descheduler ${ns}/${name} has answered a scrape for 10 minutes, so pods that break their placement rules or crowd busy nodes stay where they are. Check its Deployment in ${ns}.";
        };
      }
    )
  ];
}
