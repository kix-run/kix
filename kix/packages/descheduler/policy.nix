# Types, default profile, checks, and renderer for the descheduler's
# DeschedulerPolicy (apiVersion descheduler/v1alpha2), mirrored from
# descheduler v0.36.0: pkg/api/v1alpha2/types.go, pkg/api/types.go, and each
# plugin's types.go and validation.go under pkg/framework/plugins.
#
# Every field carries its upstream JSON name. Scalars are null until set and
# lists empty; `render` drops nulls, empty lists, and empty attrsets, so the
# rendered policy holds only what was set. A profile's pluginConfig renders
# DefaultEvictor and the plugins that profile enables, nothing else.
#
# Not declared:
# - plugins.presort, plugins.sort: no v0.36.0 plugin implements them.
# - plugins.filter, plugins.preevictionfilter: the binary always enables
#   DefaultEvictor at both (pkg/descheduler/policyconfig.go).
# - every plugins.<point>.disabled list: the binary never reads it.
# - metricsCollector, the Prometheus metrics source and
#   LowNodeUtilization.metricsUtilization.prometheus: a Prometheus URL is not
#   a Kix dependency, so derived network policy would block it, and its
#   authToken Secret needs RBAC this package does not grant.
# - DefaultEvictor's deprecated booleans (evictLocalStoragePods and the rest)
#   and LowNodeUtilization.metricsUtilization.metricsServer: replaced
#   upstream by podProtections and metricsUtilization.source.
{ lib }:
let
  t = lib.types;

  # An unsigned Go time.Duration as time.ParseDuration reads it ("90s",
  # "1h30m", ".5s", "0"). Both micro signs (U+00B5, U+03BC) spell "µs".
  durationRegex = "^(0|(([0-9]+(\\.[0-9]*)?|\\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+)$";
  duration = t.strMatching durationRegex;

  nullable =
    type: description:
    lib.mkOption {
      type = t.nullOr type;
      default = null;
      inherit description;
    };
  listOf =
    type: description:
    lib.mkOption {
      type = t.listOf type;
      default = [ ];
      inherit description;
    };
  sub =
    options: description:
    lib.mkOption {
      type = t.submodule { inherit options; };
      default = { };
      inherit description;
    };

  deschedulePlugins = [
    "PodLifeTime"
    "RemoveFailedPods"
    "RemovePodsHavingTooManyRestarts"
    "RemovePodsViolatingInterPodAntiAffinity"
    "RemovePodsViolatingNodeAffinity"
    "RemovePodsViolatingNodeTaints"
  ];
  balancePlugins = [
    "HighNodeUtilization"
    "LowNodeUtilization"
    "RemoveDuplicates"
    "RemovePodsViolatingTopologySpreadConstraint"
  ];

  labelSelector = nullable (t.submodule {
    options = {
      matchLabels = lib.mkOption {
        type = t.attrsOf t.str;
        default = { };
        description = "Labels a pod must carry.";
      };
      matchExpressions = listOf (t.submodule {
        options = {
          key = lib.mkOption {
            type = t.str;
            description = "Label key.";
          };
          operator = lib.mkOption {
            type = t.enum [
              "In"
              "NotIn"
              "Exists"
              "DoesNotExist"
            ];
            description = "Relation between the key and the values.";
          };
          values = listOf t.str "Values for In and NotIn.";
        };
      }) "Label requirements, all of which must hold.";
    };
  }) "Kubernetes label selector limiting the pods this applies to. Null selects every pod.";

  namespaces = sub {
    include = listOf t.str "Only these namespaces. Set include or exclude, not both.";
    exclude = listOf t.str "Every namespace except these. Set include or exclude, not both.";
  } "Namespaces the plugin considers.";

  # LowNodeUtilization and HighNodeUtilization reject `include`
  # (nodeutilization/validation.go).
  evictableNamespaces = sub {
    exclude = listOf t.str "Namespaces whose pods are never evicted.";
  } "Namespaces whose pods the plugin may evict.";

  # Percent of node allocatable, keyed by resource name (cpu, memory, pods,
  # or an extended resource). Upstream's Percentage is a float64.
  thresholds =
    description:
    lib.mkOption {
      type = t.attrsOf (t.numbers.between 0 100);
      default = { };
      inherit description;
    };

  # DefaultEvictor accepts only these two sets (defaultevictor/types.go,
  # validation.go).
  defaultProtections = [
    "PodsWithLocalStorage"
    "DaemonSetPods"
    "SystemCriticalPods"
    "FailedBarePods"
  ];
  extraProtections = [
    "PodsWithPVC"
    "PodsWithoutPDB"
    "PodsWithResourceClaims"
  ];

  pluginArgs = {
    DefaultEvictor = {
      nodeSelector = nullable t.str "Label selector string; only pods on matching nodes are evicted.";
      inherit labelSelector;
      namespaceLabelSelector = labelSelector // {
        description = "Kubernetes label selector on namespaces; only pods in matching namespaces are evicted.";
      };
      priorityThreshold = nullable (t.submodule {
        options = {
          name = nullable t.str "PriorityClass name whose value is the threshold.";
          value = nullable t.int "Priority value threshold.";
        };
      }) "Pods at or above this priority are not evicted. Set name or value, not both.";
      nodeFit = nullable t.bool "Evict a pod only when another node could run it.";
      minReplicas = nullable t.ints.unsigned "Evict only pods whose owner has at least this many replicas (values above 1 take effect).";
      minPodAge = nullable duration "Evict only pods older than this duration.";
      noEvictionPolicy = nullable (t.enum [
        "Preferred"
        "Mandatory"
      ]) "How the descheduler.alpha.kubernetes.io/prefer-no-eviction annotation is treated.";
      podProtections = sub {
        extraEnabled = listOf (t.enum extraProtections) "Protections added to the binary's default set.";
        defaultDisabled = listOf (t.enum defaultProtections) "Protections of the binary's default set to turn off.";
        config = sub {
          PodsWithPVC = sub {
            protectedStorageClasses =
              listOf
                (t.submodule {
                  options.name = lib.mkOption {
                    type = t.nonEmptyStr;
                    description = "StorageClass name.";
                  };
                })
                "With PodsWithPVC enabled, protect only pods whose claims use these classes. Empty protects every pod with a claim.";
          } "PodsWithPVC settings.";
        } "Settings for individual protections.";
      } "Which pods are never evicted.";
    };

    LowNodeUtilization = {
      useDeviationThresholds = nullable t.bool "Read thresholds as deviations from the mean node utilization.";
      thresholds = thresholds "Nodes below every one of these percentages are underutilized.";
      targetThresholds = thresholds "Nodes above any of these percentages are overutilized. Uses the same resource names as thresholds.";
      numberOfNodes = nullable t.ints.unsigned "Run only when more than this many nodes are underutilized.";
      metricsUtilization = sub {
        source =
          nullable (t.enum [ "KubernetesMetrics" ])
            "Read actual usage from metrics.k8s.io instead of pod requests. Needs a KubernetesMetrics entry in policy.metricsProviders.";
      } "Where utilization is read from.";
      inherit evictableNamespaces;
      evictionLimits = sub {
        node = nullable t.ints.unsigned "Most pods evicted from one node per run.";
      } "Eviction limits for this plugin.";
    };

    HighNodeUtilization = {
      thresholds = thresholds "Nodes below every one of these percentages are drained so they can be scaled down.";
      numberOfNodes = nullable t.ints.unsigned "Run only when more than this many nodes are underutilized.";
      evictionModes = listOf (t.enum [ "OnlyThresholdingResources" ]) "Extra eviction modes.";
      inherit evictableNamespaces;
    };

    PodLifeTime = {
      inherit namespaces labelSelector;
      ownerKinds = sub {
        include = listOf t.str "Only pods owned by these kinds.";
        exclude = listOf t.str "Not pods owned by these kinds.";
      } "Owner kinds considered. Set include or exclude, not both.";
      maxPodLifeTimeSeconds = nullable t.ints.unsigned "Evict pods older than this many seconds.";
      states = listOf (t.enum [
        "Running"
        "Pending"
        "Succeeded"
        "Failed"
        "Unknown"
        "NodeAffinity"
        "NodeLost"
        "Shutdown"
        "UnexpectedAdmissionError"
        "PodInitializing"
        "ContainerCreating"
        "ImagePullBackOff"
        "CrashLoopBackOff"
        "CreateContainerConfigError"
        "ErrImagePull"
        "CreateContainerError"
        "InvalidImageName"
        "OOMKilled"
        "Error"
        "Completed"
        "DeadlineExceeded"
        "Evicted"
        "ContainerCannotRun"
        "StartError"
      ]) "Pod phases or container state reasons that make a pod a candidate.";
      conditions = listOf (t.submodule {
        options = {
          type = nullable t.str "Pod condition type.";
          status = nullable t.str "Condition status.";
          reason = nullable t.str "Condition reason.";
          minTimeSinceLastTransitionSeconds = nullable t.ints.unsigned "Seconds since the condition last changed.";
        };
      }) "Pod conditions that make a pod a candidate.";
      exitCodes = listOf t.int "Container exit codes that make a pod a candidate.";
      includingInitContainers = nullable t.bool "Also read init container states and exit codes.";
      includingEphemeralContainers = nullable t.bool "Also read ephemeral container states.";
    };

    RemoveDuplicates = {
      inherit namespaces;
      excludeOwnerKinds = listOf t.str "Owner kinds whose duplicates are left alone.";
    };

    RemoveFailedPods = {
      inherit namespaces labelSelector;
      excludeOwnerKinds = listOf t.str "Owner kinds whose failed pods are left alone.";
      minPodLifetimeSeconds = nullable t.ints.unsigned "Evict only failed pods older than this many seconds (upstream default 3600).";
      reasons = listOf t.str "Only pods failed for one of these reasons.";
      exitCodes = listOf t.int "Only pods with one of these container exit codes.";
      includingInitContainers = nullable t.bool "Also read init containers.";
    };

    RemovePodsHavingTooManyRestarts = {
      inherit namespaces labelSelector;
      podRestartThreshold = nullable t.ints.positive "Evict pods whose containers restarted at least this many times in total. Required when the plugin is enabled.";
      includingInitContainers = nullable t.bool "Count init container restarts too.";
      states = listOf (t.enum [
        "Running"
        "CrashLoopBackOff"
      ]) "Only pods in one of these states.";
    };

    RemovePodsViolatingInterPodAntiAffinity = {
      inherit namespaces labelSelector;
    };

    RemovePodsViolatingNodeAffinity = {
      inherit namespaces labelSelector;
      nodeAffinityType = listOf (t.enum [
        "requiredDuringSchedulingIgnoredDuringExecution"
        "preferredDuringSchedulingIgnoredDuringExecution"
      ]) "Node affinity kinds to enforce. Required when the plugin is enabled.";
    };

    RemovePodsViolatingNodeTaints = {
      inherit namespaces labelSelector;
      includePreferNoSchedule = nullable t.bool "Also evict for PreferNoSchedule taints.";
      excludedTaints = listOf t.str "Taints (key or key=value) that never cause an eviction. Set excludedTaints or includedTaints, not both.";
      includedTaints = listOf t.str "Only these taints (key or key=value) cause an eviction. Set excludedTaints or includedTaints, not both.";
    };

    RemovePodsViolatingTopologySpreadConstraint = {
      inherit namespaces labelSelector;
      constraints = listOf (t.enum [
        "DoNotSchedule"
        "ScheduleAnyway"
      ]) "whenUnsatisfiable values to enforce. Empty means DoNotSchedule.";
      topologyBalanceNodeFit = nullable t.bool "Move a pod only to a node it fits (upstream default true).";
    };
  };

  pluginNames = builtins.attrNames pluginArgs;

  profileType = t.submodule (
    { config, ... }:
    {
      options = {
        plugins = sub {
          deschedule = sub {
            enabled = listOf (t.enum deschedulePlugins) "Deschedule plugins this profile runs.";
          } "Plugins that evict pods one by one.";
          balance = sub {
            enabled = listOf (t.enum balancePlugins) "Balance plugins this profile runs.";
          } "Plugins that evict pods to rebalance groups or nodes.";
        } "Plugins this profile runs, by extension point.";
        pluginConfig = sub (lib.mapAttrs (
          plugin: options: sub options "Arguments of ${plugin}."
        ) pluginArgs) "Plugin arguments, one attrset per plugin.";
      };
      # Safety defaults on every profile. extraEnabled is at normal priority,
      # so an instance's list adds to it and removing PodsWithPVC takes
      # lib.mkForce.
      config.pluginConfig = {
        DefaultEvictor = {
          nodeFit = lib.mkDefault true;
          podProtections.extraEnabled = [ "PodsWithPVC" ];
        };
        # `kubectl cordon` adds this taint. Excluding it keeps a cordon as
        # "no new pods" instead of draining the node within one interval.
        # Upstream rejects excludedTaints beside includedTaints, so the
        # default steps aside when the profile sets includedTaints.
        RemovePodsViolatingNodeTaints.excludedTaints = lib.mkIf (
          builtins.elem "RemovePodsViolatingNodeTaints" config.plugins.deschedule.enabled
          && config.pluginConfig.RemovePodsViolatingNodeTaints.includedTaints == [ ]
        ) (lib.mkDefault [ "node.kubernetes.io/unschedulable" ]);
      };
    }
  );

  # The package's profile, as a definition of `policy.profiles` with one
  # lib.mkDefault per leaf so an instance can change one value and keep the
  # rest.
  defaultProfile = {
    default = {
      plugins = {
        balance.enabled = lib.mkDefault [
          "RemoveDuplicates"
          "RemovePodsViolatingTopologySpreadConstraint"
          "LowNodeUtilization"
        ];
        deschedule.enabled = lib.mkDefault [
          "RemovePodsHavingTooManyRestarts"
          "RemovePodsViolatingNodeTaints"
          "RemovePodsViolatingNodeAffinity"
          "RemovePodsViolatingInterPodAntiAffinity"
        ];
      };
      pluginConfig = {
        RemovePodsHavingTooManyRestarts = {
          podRestartThreshold = lib.mkDefault 100;
          includingInitContainers = lib.mkDefault true;
        };
        RemovePodsViolatingNodeAffinity.nodeAffinityType = lib.mkDefault [
          "requiredDuringSchedulingIgnoredDuringExecution"
        ];
        LowNodeUtilization = {
          thresholds = lib.mapAttrs (_: lib.mkDefault) {
            cpu = 20;
            memory = 20;
            pods = 20;
          };
          targetThresholds = lib.mapAttrs (_: lib.mkDefault) {
            cpu = 50;
            memory = 50;
            pods = 50;
          };
        };
      };
    };
  };

  policyType = t.submodule {
    options = {
      profiles = lib.mkOption {
        type = t.attrsOf profileType;
        default = { };
        description = "Descheduler profiles by name. Each runs its own plugins with its own DefaultEvictor; they run in name order.";
      };
      nodeSelector = nullable t.str "Label selector string limiting the nodes the descheduler considers.";
      maxNoOfPodsToEvictPerNode = nullable t.ints.unsigned "Most pods evicted from one node per run.";
      maxNoOfPodsToEvictPerNamespace = nullable t.ints.unsigned "Most pods evicted from one namespace per run.";
      maxNoOfPodsToEvictTotal = nullable t.ints.unsigned "Most pods evicted per run.";
      gracePeriodSeconds = nullable t.ints.unsigned "Grace period passed with each eviction. Null uses each pod's own.";
      evictionFailureEventNotification = nullable t.bool "Emit an Event when an eviction fails.";
      metricsProviders = listOf (t.submodule {
        options.source = lib.mkOption {
          type = t.enum [ "KubernetesMetrics" ];
          description = "Metrics source. KubernetesMetrics reads metrics.k8s.io (metrics-server).";
        };
      }) "Sources of actual usage for the node-utilization plugins. At most one entry.";
    };
  };

  enabledIn = profile: profile.plugins.deschedule.enabled ++ profile.plugins.balance.enabled;

  # Problems the descheduler reports at startup and then exits on, as
  # messages naming the profile. They mirror each plugin's validation.go and
  # validateDeschedulerConfiguration (pkg/descheduler/policyconfig.go), which
  # validates every pluginConfig entry. Plugin rules are checked only for
  # enabled plugins, because `render` writes no other plugin's args.
  checkPolicy =
    policy:
    let
      perProfile =
        name: profile:
        let
          on = p: builtins.elem p (enabledIn profile);
          args = profile.pluginConfig;
          low = args.LowNodeUtilization;
          lowNames = builtins.attrNames low.thresholds;
          lowTargets = builtins.attrNames low.targetThresholds;
          aboveTarget = builtins.filter (
            r: low.targetThresholds ? ${r} && low.thresholds.${r} > low.targetThresholds.${r}
          ) lowNames;
          taints = args.RemovePodsViolatingNodeTaints;
          lifetime = args.PodLifeTime;
          priority = args.DefaultEvictor.priorityThreshold;
          at = "policy.profiles.${name}.pluginConfig";
          bothSet = s: s.include != [ ] && s.exclude != [ ];
          namespacesBoth = builtins.filter (p: args.${p} ? namespaces && bothSet args.${p}.namespaces) (
            lib.unique (enabledIn profile)
          );
          emptyConditions = builtins.filter (
            i: lib.all (v: v == null) (builtins.attrValues (builtins.elemAt lifetime.conditions i))
          ) (lib.range 0 (builtins.length lifetime.conditions - 1));
        in
        lib.optional (priority != null && priority.name != null && priority.value != null)
          "${at}.DefaultEvictor.priorityThreshold sets both name and value; the descheduler exits at startup. Keep one."
        ++
          lib.optional
            (
              on "LowNodeUtilization"
              && low.metricsUtilization.source == "KubernetesMetrics"
              && !(builtins.any (p: p.source == "KubernetesMetrics") policy.metricsProviders)
            )
            "${at}.LowNodeUtilization.metricsUtilization.source is KubernetesMetrics, but policy.metricsProviders has no KubernetesMetrics entry, so the descheduler has no metrics client and the plugin fails each run. Add policy.metricsProviders = [ { source = \"KubernetesMetrics\"; } ]."
        ++
          lib.optional (on "LowNodeUtilization" && (lowNames == [ ] || lowTargets == [ ]))
            "profile ${name} enables LowNodeUtilization with empty ${at}.LowNodeUtilization.thresholds or targetThresholds; the descheduler exits at startup. Set both, with the same resource names."
        ++
          lib.optional
            (on "LowNodeUtilization" && lowNames != [ ] && lowTargets != [ ] && lowNames != lowTargets)
            "${at}.LowNodeUtilization.thresholds names ${lib.concatStringsSep ", " lowNames} and targetThresholds names ${lib.concatStringsSep ", " lowTargets}; the descheduler exits at startup unless both name the same resources."
        ++
          lib.optional (on "LowNodeUtilization" && aboveTarget != [ ] && low.useDeviationThresholds != true)
            "${at}.LowNodeUtilization.thresholds is above targetThresholds for ${lib.concatStringsSep ", " aboveTarget}; the descheduler exits at startup. Lower thresholds or raise targetThresholds."
        ++
          lib.optional (on "HighNodeUtilization" && args.HighNodeUtilization.thresholds == { })
            "profile ${name} enables HighNodeUtilization with empty ${at}.HighNodeUtilization.thresholds; the descheduler exits at startup. Set thresholds."
        ++
          lib.optional
            (on "RemovePodsViolatingNodeTaints" && taints.includedTaints != [ ] && taints.excludedTaints != [ ])
            "${at}.RemovePodsViolatingNodeTaints sets both includedTaints and excludedTaints; the descheduler exits at startup. Keep one. excludedTaints defaults to [ \"node.kubernetes.io/unschedulable\" ] only while includedTaints is empty, so setting includedTaints alone drops it."
        ++
          lib.optional
            (
              on "RemovePodsHavingTooManyRestarts"
              && args.RemovePodsHavingTooManyRestarts.podRestartThreshold == null
            )
            "profile ${name} enables RemovePodsHavingTooManyRestarts without ${at}.RemovePodsHavingTooManyRestarts.podRestartThreshold; the descheduler exits at startup. Set it."
        ++
          lib.optional
            (
              on "RemovePodsViolatingNodeAffinity" && args.RemovePodsViolatingNodeAffinity.nodeAffinityType == [ ]
            )
            "profile ${name} enables RemovePodsViolatingNodeAffinity without ${at}.RemovePodsViolatingNodeAffinity.nodeAffinityType; the descheduler exits at startup. Set it."
        ++
          lib.optional
            (
              on "PodLifeTime"
              && lifetime.maxPodLifeTimeSeconds == null
              && lifetime.states == [ ]
              && lifetime.conditions == [ ]
              && lifetime.exitCodes == [ ]
            )
            "profile ${name} enables PodLifeTime with none of maxPodLifeTimeSeconds, states, conditions, or exitCodes under ${at}.PodLifeTime; the descheduler exits at startup. Set at least one."
        ++
          lib.optional (on "PodLifeTime" && bothSet lifetime.ownerKinds)
            "${at}.PodLifeTime.ownerKinds sets both include and exclude; the descheduler exits at startup. Keep one."
        ++ lib.optionals (on "PodLifeTime") (
          map (
            i:
            "${at}.PodLifeTime.conditions entry ${toString i} sets none of type, status, reason, or minTimeSinceLastTransitionSeconds; the descheduler exits at startup. Set at least one."
          ) emptyConditions
        )
        ++ map (
          p:
          "${at}.${p}.namespaces sets both include and exclude; the descheduler exits at startup. Keep one."
        ) namespacesBoth;
    in
    lib.optional (builtins.length policy.metricsProviders > 1)
      "policy.metricsProviders has ${toString (builtins.length policy.metricsProviders)} entries; the descheduler accepts each source once and exits at startup otherwise. Keep one."
    ++ lib.concatLists (lib.mapAttrsToList perProfile policy.profiles);

  # Drops nulls, empty lists, and empty attrsets at every depth.
  clean =
    v:
    if builtins.isAttrs v then
      lib.filterAttrs (_: x: x != null && x != [ ] && x != { }) (lib.mapAttrs (_: clean) v)
    else if builtins.isList v then
      map clean v
    else
      v;

  renderProfile =
    name: profile:
    let
      enabled = enabledIn profile;
      evictor = profile.pluginConfig.DefaultEvictor;
      # Upstream rejects a protection listed twice.
      evictorArgs = evictor // {
        podProtections = evictor.podProtections // {
          extraEnabled = lib.unique evictor.podProtections.extraEnabled;
          defaultDisabled = lib.unique evictor.podProtections.defaultDisabled;
        };
      };
      argsOf = p: clean (if p == "DefaultEvictor" then evictorArgs else profile.pluginConfig.${p});
      # A plugin enabled without a pluginConfig entry stops the binary at
      # startup, so every enabled plugin gets one, even with no args. The
      # binary validates every entry but reads only the enabled plugins'
      # args, so a disabled plugin's settings are left out.
      configured = builtins.filter (p: p == "DefaultEvictor" || builtins.elem p enabled) pluginNames;
    in
    {
      inherit name;
      pluginConfig = map (p: {
        name = p;
        args = argsOf p;
      }) configured;
      plugins = lib.filterAttrs (_: s: s.enabled != [ ]) {
        deschedule.enabled = profile.plugins.deschedule.enabled;
        balance.enabled = profile.plugins.balance.enabled;
      };
    };

  render =
    policy:
    {
      apiVersion = "descheduler/v1alpha2";
      kind = "DeschedulerPolicy";
      profiles = lib.mapAttrsToList renderProfile policy.profiles;
    }
    // clean (removeAttrs policy [ "profiles" ]);
in
{
  inherit
    duration
    policyType
    defaultProfile
    checkPolicy
    render
    ;
}
