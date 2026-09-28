# prometheus-default-rules: standard Kubernetes monitoring rules and service monitors.
#
# Ships the same PrometheusRules and ServiceMonitors that kube-prometheus-stack
# bundles by default: Kubernetes component alerts, recording rules, and
# ServiceMonitors for kubelet, apiserver, etcd, scheduler, etc.
#
# Each control-plane ServiceMonitor lives in its own file under `components/`,
# which also emits the kube-system bridge Service the SM selects on. Add a
# new component by dropping a file in `components/` and listing it below.
#
# Source: extracted from kube-prometheus-stack 84.5.0 Helm chart output.
#
# DI deps:
#   prometheus-operator (required): provides CRD builders

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  rulesDir = ../prometheus-operator/rules;

  componentFiles = [
    ./components/apiserver.nix
    ./components/kubelet.nix
    ./components/coredns.nix
    ./components/etcd.nix
    ./components/kube-controller-manager.nix
    ./components/kube-scheduler.nix
    ./components/kube-proxy.nix
  ];
  components = map (f: import f { inherit lib kix; }) componentFiles;

  # Merge each component's `options` attr into a single tree.
  componentOptions = lib.foldl' lib.recursiveUpdate { } (map (c: c.options) components);
in
{
  meta = {
    version = "84.5.0";
    description = "Default Kubernetes monitoring rules and service monitors";
    owner = "platform";
  };

  options = lib.recursiveUpdate {
    rules = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Deploy default PrometheusRules (alerts + recording rules).";
      };
      etcd = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeApiserver = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeScheduler = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeProxy = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubernetesApps = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubernetesResources = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubernetesStorage = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubernetesSystem = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      nodeExporter = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      alertmanager = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      prometheus = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      prometheusOperator = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      general = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      # Chart toggles for the four split container resource rule groups.
      # Absent from upstream values.yaml; default is off, matching helm
      # render behaviour. Records duplicate `k8s.rules.container_resource`.
      k8sContainerCpuLimits = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      k8sContainerCpuRequests = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      k8sContainerMemoryLimits = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      k8sContainerMemoryRequests = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
    ruleOverrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = {
        NodeDiskIOSaturation.for = "6h";
        CPUThrottlingHigh = {
          for = "1h";
          labels.severity = "info";
        };
      };
      description = ''
        Per-alert overrides applied post-load to bundled PrometheusRule JSON.
        Keyed by `alert` name; values deep-merged into the matching rule object
        (e.g. patch `for`, `labels.severity`, `annotations`). Use to relax
        defaults without forking the rule files.
      '';
    };
    monitors.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Master toggle for default ServiceMonitors. Disables every component.";
    };
    runbookUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://runbooks.prometheus-operator.dev/runbooks/";
      description = ''
        Prefix for runbook_url annotations. The chart bakes this prefix into
        every alert at render time; kix re-applies it via string-replace at
        load time so users can point alerts at their own runbooks.
        Trailing slash required.
      '';
    };
    kubeStateMetricsJobName = lib.mkOption {
      type = lib.types.str;
      default = "kube-state-metrics";
      description = ''
        Job name used by KSM-based recording rules. Override if your
        kube-state-metrics ServiceMonitor uses a different `jobLabel`.
      '';
    };
  } componentOptions;

  build = [
    # ── Rules build entry ─────────────────────────────────────────────
    (
      {
        self,
        config,
        scope,
        lib,
        prometheusOperator,
        ...
      }:
      let
        mkRule = prometheusOperator.out.mkPrometheusRule scope;

        patchRule =
          rule:
          if rule ? alert && config.ruleOverrides ? ${rule.alert} then
            lib.recursiveUpdate rule config.ruleOverrides.${rule.alert}
          else
            rule;

        applyRuleOverrides =
          spec:
          spec
          // {
            groups = map (g: g // { rules = map patchRule (g.rules or [ ]); }) (spec.groups or [ ]);
          };

        # Frozen rule JSONs were rendered at chart-time with two values baked
        # into many alert annotations / expressions:
        #   - runbook URL prefix (kube-prometheus-stack default)
        #   - kube-state-metrics job name (matches the chart's KSM service name)
        # Re-template them at load time so users can override the defaults.
        # The KSM job name appears in JSON-encoded PromQL as `\"kube-state-metrics\"`
        # (e.g. `{job=\"kube-state-metrics\"}`); using that escaped pattern
        # avoids mangling free-text alert descriptions that mention the project
        # name.
        rebakeText =
          builtins.replaceStrings
            [
              "https://runbooks.prometheus-operator.dev/runbooks/"
              ''\"kube-state-metrics\"''
            ]
            [
              config.runbookUrl
              ''\"${config.kubeStateMetricsJobName}\"''
            ];

        ruleFromFile =
          filename:
          let
            raw = builtins.fromJSON (rebakeText (builtins.readFile (rulesDir + "/${filename}")));
            spec = applyRuleOverrides raw;
          in
          mkRule {
            name = "${name}-${lib.removeSuffix "-prometheusrule.json" filename}";
            inherit spec;
          };

        ruleFiles = lib.optionals (config.rules.enabled) (
          [
            "general.rules-prometheusrule.json"
            "kube-prometheus-general.rules-prometheusrule.json"
            "kube-prometheus-node-recording.rules-prometheusrule.json"
            "k8s.rules.container-cpu-usage-second-prometheusrule.json"
            "k8s.rules.container-memory-cache-prometheusrule.json"
            "k8s.rules.container-memory-rss-prometheusrule.json"
            "k8s.rules.container-memory-swap-prometheusrule.json"
            "k8s.rules.container-memory-working-s-prometheusrule.json"
            "k8s.rules.container-resource-prometheusrule.json"
            "k8s.rules.pod-owner-prometheusrule.json"
            "config-reloaders-prometheusrule.json"
            "kubelet.rules-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.etcd [ "etcd-prometheusrule.json" ]
          ++ lib.optionals config.rules.kubeApiserver [
            "kube-apiserver-availability.rules-prometheusrule.json"
            "kube-apiserver-burnrate.rules-prometheusrule.json"
            "kube-apiserver-histogram.rules-prometheusrule.json"
            "kube-apiserver-slos-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.kubeScheduler [
            "kube-scheduler.rules-prometheusrule.json"
            "kubernetes-system-scheduler-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.kubeProxy [ "kubernetes-system-kube-proxy-prometheusrule.json" ]
          ++ lib.optionals config.rules.kubernetesApps [ "kubernetes-apps-prometheusrule.json" ]
          ++ lib.optionals config.rules.kubernetesResources [ "kubernetes-resources-prometheusrule.json" ]
          ++ lib.optionals config.rules.kubernetesStorage [ "kubernetes-storage-prometheusrule.json" ]
          ++ lib.optionals config.rules.kubernetesSystem [
            "kubernetes-system-prometheusrule.json"
            "kubernetes-system-apiserver-prometheusrule.json"
            "kubernetes-system-controller-manager-prometheusrule.json"
            "kubernetes-system-kubelet-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.nodeExporter [
            "node-exporter-prometheusrule.json"
            "node-exporter.rules-prometheusrule.json"
            "node-network-prometheusrule.json"
            "node.rules-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.alertmanager [ "alertmanager.rules-prometheusrule.json" ]
          ++ lib.optionals config.rules.prometheus [ "prometheus-prometheusrule.json" ]
          ++ lib.optionals config.rules.prometheusOperator [
            "prometheus-operator-prometheusrule.json"
            "kube-state-metrics-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.k8sContainerCpuLimits [
            "k8s.rules.container-cpu-limits-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.k8sContainerCpuRequests [
            "k8s.rules.container-cpu-requests-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.k8sContainerMemoryLimits [
            "k8s.rules.container-memory-limits-prometheusrule.json"
          ]
          ++ lib.optionals config.rules.k8sContainerMemoryRequests [
            "k8s.rules.container-memory-requests-prometheusrule.json"
          ]
        );
      in
      builtins.listToAttrs (
        map (f: {
          name = "rule-${lib.removeSuffix "-prometheusrule.json" f}";
          value = ruleFromFile f;
        }) ruleFiles
      )
    )
  ]
  # ── One build entry per component file ───────────────────────────────
  ++ map (c: c.build) components
  # ── Root aggregator ──────────────────────────────────────────────────
  ++ [
    (
      {
        self,
        lib,
        ...
      }:
      let
        # Gather everything emitted by the rules entry and component files.
        allKeys = builtins.filter (
          n:
          lib.hasPrefix "rule-" n
          || lib.hasPrefix "monitor-" n
          || lib.hasPrefix "bridge-" n
          || lib.hasPrefix "endpoints-" n
        ) (builtins.attrNames self);
        allResources = map (k: self.${k}) allKeys;
      in
      {
        root = {
          resource = if allResources != [ ] then builtins.head allResources else null;
          requires = allResources;
        };
      }
    )
  ];
}
