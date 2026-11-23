# Tests for the descheduler package and the kix/lib behaviour it relies on:
# kix.monitor scrapes over HTTPS when asked; the policy's startup checks,
# defaults, merge behaviour, and renderer (policy.nix); the interval
# assertion, owned flags, replica mapping, and alert rules (default.nix).

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  multiZone,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  # The ServiceMonitor endpoints kix.monitor builds for `args`, with a
  # prometheus stub whose builder returns the arguments it was given.
  endpointsOf =
    args:
    let
      parts = kixlib.monitor ({ service = "metricsService"; } // args) {
        inherit lib;
        self.metricsService.out.selector.app = "descheduler";
        config.metrics.enabled = true;
        scope = {
          instanceName = "descheduler";
          namespaceName = "kube-system";
        };
        prometheus.out.mkServiceMonitor = _scope: monitorArgs: monitorArgs;
      };
    in
    parts.serviceMonitor.spec.endpoints;

  packagePath = ../../../packages/experimental/descheduler;
  policyLib = import (packagePath + "/policy.nix") { inherit lib; };
  package = import packagePath {
    inherit lib;
    kix = kixlib;
    scope = {
      instanceName = "descheduler";
      namespaceName = "descheduler";
    };
    availability = "none";
  };

  # The `policy` option as the package evaluates it: its type, the default
  # profile from the package's config, and `def` from the instance.
  evalPolicy =
    def:
    (lib.evalModules {
      modules = [
        {
          options.policy = lib.mkOption {
            type = policyLib.policyType;
            default = { };
          };
        }
        { policy.profiles = policyLib.defaultProfile; }
        { policy = def; }
      ];
    }).config.policy;

  checksOf = def: policyLib.checkPolicy (evalPolicy def);
  renderOf = def: policyLib.render (evalPolicy def);

  profileOf = name: rendered: lib.findFirst (p: p.name == name) null rendered.profiles;
  pluginNamesOf = profile: map (c: c.name) profile.pluginConfig;
  argsOf =
    plugin: profile: (lib.findFirst (c: c.name == plugin) { args = null; } profile.pluginConfig).args;

  # Each case is an instance's `policy` and a phrase the one resulting
  # message must contain.
  startupCases = {
    above-target = {
      def.profiles.default.pluginConfig.LowNodeUtilization.thresholds.cpu = 60;
      says = "LowNodeUtilization.thresholds is above targetThresholds for cpu";
    };
    different-resources = {
      def.profiles.default.pluginConfig.LowNodeUtilization.thresholds.nvidia = 10;
      says = "unless both name the same resources";
    };
    low-empty = {
      def.profiles.low.plugins.balance.enabled = [ "LowNodeUtilization" ];
      says = "profile low enables LowNodeUtilization with empty";
    };
    high-empty = {
      def.profiles.high.plugins.balance.enabled = [ "HighNodeUtilization" ];
      says = "profile high enables HighNodeUtilization with empty";
    };
    metrics-source-without-provider = {
      def.profiles.default.pluginConfig.LowNodeUtilization.metricsUtilization.source =
        "KubernetesMetrics";
      says = "policy.metricsProviders has no KubernetesMetrics entry";
    };
    two-providers = {
      def.metricsProviders = [
        { source = "KubernetesMetrics"; }
        { source = "KubernetesMetrics"; }
      ];
      says = "policy.metricsProviders has 2 entries";
    };
    both-taint-lists = {
      def.profiles.default.pluginConfig.RemovePodsViolatingNodeTaints = {
        includedTaints = [ "example.com/a" ];
        excludedTaints = [ "example.com/b" ];
      };
      says = "sets both includedTaints and excludedTaints";
    };
    restarts-without-threshold = {
      def.profiles.r.plugins.deschedule.enabled = [ "RemovePodsHavingTooManyRestarts" ];
      says = "without policy.profiles.r.pluginConfig.RemovePodsHavingTooManyRestarts.podRestartThreshold";
    };
    node-affinity-without-type = {
      def.profiles.a.plugins.deschedule.enabled = [ "RemovePodsViolatingNodeAffinity" ];
      says = "enables RemovePodsViolatingNodeAffinity without";
    };
    lifetime-without-filter = {
      def.profiles.p.plugins.deschedule.enabled = [ "PodLifeTime" ];
      says = "enables PodLifeTime with none of maxPodLifeTimeSeconds, states, conditions, or exitCodes";
    };
    lifetime-owner-kinds-both = {
      def.profiles.p = {
        plugins.deschedule.enabled = [ "PodLifeTime" ];
        pluginConfig.PodLifeTime = {
          maxPodLifeTimeSeconds = 3600;
          ownerKinds = {
            include = [ "Job" ];
            exclude = [ "ReplicaSet" ];
          };
        };
      };
      says = "PodLifeTime.ownerKinds sets both include and exclude";
    };
    lifetime-empty-condition = {
      def.profiles.p = {
        plugins.deschedule.enabled = [ "PodLifeTime" ];
        pluginConfig.PodLifeTime.conditions = [ { } ];
      };
      says = "PodLifeTime.conditions entry 0 sets none of";
    };
    namespaces-both = {
      def.profiles.default.pluginConfig.RemoveDuplicates.namespaces = {
        include = [ "a" ];
        exclude = [ "b" ];
      };
      says = "policy.profiles.default.pluginConfig.RemoveDuplicates.namespaces sets both include and exclude";
    };
    priority-threshold-both = {
      def.profiles.default.pluginConfig.DefaultEvictor.priorityThreshold = {
        name = "system-cluster-critical";
        value = 1000;
      };
      says = "DefaultEvictor.priorityThreshold sets both name and value";
    };
  };

  startupResults = lib.mapAttrs (_: c: checksOf c.def) startupCases;
  startupFailures = lib.filterAttrs (
    n: msgs: !(builtins.length msgs == 1 && lib.hasInfix startupCases.${n}.says (builtins.head msgs))
  ) startupResults;

  descheduler =
    instance:
    mkCluster [
      multiZone
      {
        namespaces.descheduler = { };
        instances.descheduler.descheduler = {
          package = import packagePath;
        }
        // instance;
      }
    ];
  replicasAt =
    level:
    (byName "descheduler" (
      ofKind "Deployment" (
        manifests (descheduler {
          availability = level;
        })
      )
    )).spec.replicas;
in
{
  # A KubernetesMetrics provider on a cluster that leaves the metricsApi
  # role unset warns on that role's binding. No provider, no warning.
  descheduler-metrics-provider-warns =
    let
      metricsWarnings =
        instance:
        builtins.filter (
          w: (w.clusterOption or null) == "cluster.roles.metricsApi.binding"
        ) (descheduler instance).instances.descheduler.descheduler._diagnostics.warnings;
    in
    (
      builtins.length (metricsWarnings {
        config.policy.metricsProviders = [ { source = "KubernetesMetrics"; } ];
      }) == 1
      && metricsWarnings { } == [ ]
    )
    || throw "descheduler metrics API warning";

  # scheme = "https" and a tlsConfig render on the primary endpoint. Left
  # out, the endpoint is `scheme: http` with no tlsConfig.
  descheduler-monitor-https =
    let
      https = endpointsOf {
        scheme = "https";
        tlsConfig.insecureSkipVerify = true;
      };
      plain = endpointsOf { };
    in
    (
      https == [
        {
          port = "metrics";
          path = "/metrics";
          scheme = "https";
          tlsConfig.insecureSkipVerify = true;
        }
      ]
      &&
        plain == [
          {
            port = "metrics";
            path = "/metrics";
            scheme = "http";
          }
        ]
    )
    || throw "kix.monitor scheme/tlsConfig: https ${builtins.toJSON https}, default ${builtins.toJSON plain}";

  # The default policy passes every check, and profile default excludes the
  # cordon taint.
  descheduler-default-policy =
    let
      rendered = renderOf { };
      default = profileOf "default" rendered;
    in
    (
      checksOf { } == [ ]
      && map (p: p.name) rendered.profiles == [ "default" ]
      &&
        argsOf "RemovePodsViolatingNodeTaints" default == {
          excludedTaints = [ "node.kubernetes.io/unschedulable" ];
        }
      &&
        argsOf "DefaultEvictor" default == {
          nodeFit = true;
          podProtections.extraEnabled = [ "PodsWithPVC" ];
        }
    )
    || throw "default policy: checks ${builtins.toJSON (checksOf { })}, rendered ${builtins.toJSON rendered}";

  # Each setting the descheduler refuses at startup fails evaluation with
  # one message that names it.
  descheduler-startup-checks =
    startupFailures == { } || throw "startup checks: ${builtins.toJSON startupFailures}";

  # Settings of a plugin a profile does not enable are not rendered, so the
  # binary does not validate them: LowNodeUtilization thresholds above the
  # target with the plugin off, and PodLifeTime and
  # RemovePodsHavingTooManyRestarts args with no filter or threshold on a
  # profile that enables neither.
  descheduler-disabled-plugin-args-not-rendered =
    let
      def = {
        profiles.default = {
          plugins.balance.enabled = [ "RemoveDuplicates" ];
          pluginConfig.LowNodeUtilization.thresholds.cpu = 60;
        };
        profiles.mine.pluginConfig = {
          PodLifeTime.ownerKinds.exclude = [ "Job" ];
          RemovePodsHavingTooManyRestarts.includingInitContainers = true;
        };
      };
      rendered = renderOf def;
      default = profileOf "default" rendered;
      mine = profileOf "mine" rendered;
    in
    (
      checksOf def == [ ]
      && !(builtins.elem "LowNodeUtilization" (pluginNamesOf default))
      && pluginNamesOf mine == [ "DefaultEvictor" ]
    )
    || throw "disabled plugins: checks ${builtins.toJSON (checksOf def)}, rendered ${builtins.toJSON rendered}";

  # The cordon taint is excluded on every profile that enables
  # RemovePodsViolatingNodeTaints and sets no includedTaints; an instance's
  # excludedTaints replaces it.
  descheduler-cordon-taint-every-profile =
    let
      taintsOn = profile: {
        plugins.deschedule.enabled = [ "RemovePodsViolatingNodeTaints" ];
        pluginConfig.RemovePodsViolatingNodeTaints = profile;
      };
      rendered = renderOf {
        profiles = {
          mine = taintsOn { };
          included = taintsOn { includedTaints = [ "example.com/maint" ]; };
          off.plugins.balance.enabled = [ "RemoveDuplicates" ];
          default.pluginConfig.RemovePodsViolatingNodeTaints.excludedTaints = [ "example.com/maint" ];
        };
      };
      taintArgs = name: argsOf "RemovePodsViolatingNodeTaints" (profileOf name rendered);
    in
    (
      taintArgs "mine" == {
        excludedTaints = [ "node.kubernetes.io/unschedulable" ];
      }
      && taintArgs "included" == { includedTaints = [ "example.com/maint" ]; }
      && taintArgs "off" == null
      && taintArgs "default" == { excludedTaints = [ "example.com/maint" ]; }
    )
    || throw "cordon taint: ${builtins.toJSON rendered}";

  # One default leaf can change without dropping its siblings, extraEnabled
  # adds to PodsWithPVC without a duplicate, and mkForce replaces the
  # profile set while the per-profile safety defaults stay.
  descheduler-policy-merge =
    let
      default = profileOf "default" (renderOf {
        profiles.default.pluginConfig = {
          LowNodeUtilization.thresholds.cpu = 30;
          DefaultEvictor.podProtections.extraEnabled = [
            "PodsWithoutPDB"
            "PodsWithPVC"
          ];
        };
      });
      forced = renderOf {
        profiles = lib.mkForce {
          mine.plugins.balance.enabled = [ "RemoveDuplicates" ];
        };
      };
    in
    (
      (argsOf "LowNodeUtilization" default).thresholds == {
        cpu = 30;
        memory = 20;
        pods = 20;
      }
      &&
        lib.sort lib.lessThan (argsOf "DefaultEvictor" default).podProtections.extraEnabled == [
          "PodsWithPVC"
          "PodsWithoutPDB"
        ]
      && map (p: p.name) forced.profiles == [ "mine" ]
      && (argsOf "DefaultEvictor" (profileOf "mine" forced)).nodeFit == true
    )
    || throw "policy merge: default ${builtins.toJSON default}, forced ${builtins.toJSON forced}";

  # Durations follow time.ParseDuration, without a sign.
  descheduler-duration-grammar =
    let
      accepted = [
        "5m"
        "90s"
        "1h30m"
        ".5s"
        "5.s"
        "0"
        "300µs"
      ];
      rejected = [
        "5"
        "00"
        "-5s"
        "5 min"
        ""
        "s"
      ];
      typeOk = policyLib.duration.check;
    in
    (builtins.all typeOk accepted && !(builtins.any typeOk rejected))
    || throw "duration: accepted ${
      builtins.toJSON (builtins.filter (s: !typeOk s) accepted)
    } wrongly refused, ${builtins.toJSON (builtins.filter typeOk rejected)} wrongly accepted";

  # A zero interval fails with the interval message; a positive one passes.
  descheduler-interval-assertion =
    let
      messagesFor =
        interval:
        map (a: a.message) (
          package.assertions {
            config = {
              deschedulingInterval = interval;
              policy = evalPolicy { };
            };
          }
        );
      zero = messagesFor "0s";
    in
    (
      builtins.length zero == 1
      && lib.hasInfix "deschedulingInterval is \"0s\"; it must be greater than zero" (builtins.head zero)
      && messagesFor "30s" == [ ]
    )
    || throw "interval assertion: 0s gives ${builtins.toJSON zero}, 30s gives ${builtins.toJSON (messagesFor "30s")}";

  # The descheduler is leader-elected: one pod at `pod`, two at `zone`. A
  # flag the package owns in extraArgs fails the build; another flag passes.
  descheduler-replicas-and-owned-flags =
    (
      replicasAt "pod" == 1
      && replicasAt "zone" == 2
      && evalFails (descheduler {
        config.extraArgs = [ "--leader-elect=false" ];
      })
      && !evalFails (descheduler {
        config.extraArgs = [ "--v=4" ];
      })
    )
    || throw "descheduler: replicas pod ${toString (replicasAt "pod")}, zone ${toString (replicasAt "zone")}";

  # The alerts render under `descheduler-alerts` with a prometheus provider
  # and metrics.enabled, and every expression selects the metrics Service.
  descheduler-alerts =
    let
      rulesOf =
        {
          config ? { },
          prometheus ? true,
        }:
        alertRulesOf "PrometheusRule" "descheduler" (
          manifests (mkCluster [
            {
              instances.descheduler.descheduler = {
                package = import packagePath;
                inherit config;
              };
            }
            (lib.optionalAttrs prometheus { instances.monitoring.prometheus.package = prometheusStub; })
          ])
        );
      rules = rulesOf { };
    in
    (
      allSelect ''namespace="descheduler",service="descheduler-metrics"'' rules
      && builtins.attrNames rules == [ "DeschedulerDown" ]
      && rulesOf { prometheus = false; } == null
      && rulesOf { config.metrics.enabled = false; } == null
    )
    || throw "descheduler alerts: ${builtins.toJSON (builtins.attrNames rules)}";
}
