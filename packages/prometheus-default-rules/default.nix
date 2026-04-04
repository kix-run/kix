# prometheus-default-rules — standard Kubernetes monitoring rules and service monitors.
#
# Ships the same PrometheusRules and ServiceMonitors that kube-prometheus-stack
# bundles by default: Kubernetes component alerts, recording rules, and
# ServiceMonitors for kubelet, apiserver, etcd, scheduler, etc.
#
# Source: extracted from kube-prometheus-stack 71.2.0 Helm chart output.
#
# DI deps:
#   prometheus-operator (required) — provides CRD builders

{
  scope,
  lib,
}:
let
  name = scope.instanceName;
  rulesDir = ../prometheus-operator/rules;
  monitorsDir = ../prometheus-operator/monitors;
in
{
  meta = {
    version = "71.2.0";
    description = "Default Kubernetes monitoring rules and service monitors";
    provides = [ "default-monitoring-rules" ];
  };

  options = {
    rules = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Deploy default PrometheusRules (alerts + recording rules).";
      };
      # Per-group toggles
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
    };
    monitors = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Deploy default ServiceMonitors for K8s system components.";
      };
      kubelet = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      apiserver = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      coredns = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      etcd = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeScheduler = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeControllerManager = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      kubeProxy = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
  };

  build =
    {
      self,
      config,
      prometheusOperator,
      ...
    }:
    let
      mkRule = prometheusOperator.out.mkPrometheusRule scope;
      mkSmon = prometheusOperator.out.mkServiceMonitor scope;

      # Load a JSON rule file and create a PrometheusRule CR
      ruleFromFile =
        filename:
        let
          spec = builtins.fromJSON (builtins.readFile (rulesDir + "/${filename}"));
        in
        mkRule {
          name = "${name}-${lib.removeSuffix "-prometheusrule.json" filename}";
          inherit spec;
        };

      # Load a JSON monitor file and create a ServiceMonitor CR
      monitorFromFile =
        filename:
        let
          spec = builtins.fromJSON (builtins.readFile (monitorsDir + "/${filename}"));
        in
        mkSmon {
          name = "${name}-${lib.removeSuffix "-servicemonitor.json" filename}";
          inherit spec;
        };

      # ── PrometheusRules ──────────────────────────────────────────────

      ruleFiles = lib.optionals (config.rules.enabled) (
        # Always-on rules (recording rules for core metrics)
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
        # Toggleable rule groups
        ++ lib.optionals config.rules.etcd [
          "etcd-prometheusrule.json"
        ]
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
        ++ lib.optionals config.rules.kubeProxy [
          "kubernetes-system-kube-proxy-prometheusrule.json"
        ]
        ++ lib.optionals config.rules.kubernetesApps [
          "kubernetes-apps-prometheusrule.json"
        ]
        ++ lib.optionals config.rules.kubernetesResources [
          "kubernetes-resources-prometheusrule.json"
        ]
        ++ lib.optionals config.rules.kubernetesStorage [
          "kubernetes-storage-prometheusrule.json"
        ]
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
        ++ lib.optionals config.rules.alertmanager [
          "alertmanager.rules-prometheusrule.json"
        ]
        ++ lib.optionals config.rules.prometheus [
          "prometheus-prometheusrule.json"
        ]
        ++ lib.optionals config.rules.prometheusOperator [
          "prometheus-operator-prometheusrule.json"
          "kube-state-metrics-prometheusrule.json"
        ]
      );

      rules = builtins.listToAttrs (
        map (f: {
          name = "rule-${lib.removeSuffix "-prometheusrule.json" f}";
          value = ruleFromFile f;
        }) ruleFiles
      );

      # ── ServiceMonitors ──────────────────────────────────────────────

      monitorFiles = lib.optionals (config.monitors.enabled) (
        lib.optionals config.monitors.kubelet [ "kubelet-servicemonitor.json" ]
        ++ lib.optionals config.monitors.apiserver [ "apiserver-servicemonitor.json" ]
        ++ lib.optionals config.monitors.coredns [ "coredns-servicemonitor.json" ]
        ++ lib.optionals config.monitors.etcd [ "kube-etcd-servicemonitor.json" ]
        ++ lib.optionals config.monitors.kubeScheduler [ "kube-scheduler-servicemonitor.json" ]
        ++ lib.optionals config.monitors.kubeControllerManager [
          "kube-controller-manager-servicemonitor.json"
        ]
        ++ lib.optionals config.monitors.kubeProxy [ "kube-proxy-servicemonitor.json" ]
      );

      monitors = builtins.listToAttrs (
        map (f: {
          name = "monitor-${lib.removeSuffix "-servicemonitor.json" f}";
          value = monitorFromFile f;
        }) monitorFiles
      );

      allResources = rules // monitors;
    in
    {
      root = {
        resource = if allResources != { } then (builtins.head (builtins.attrValues allResources)) else null;
        requires = builtins.attrValues allResources;
      };
    }
    // allResources;
}
