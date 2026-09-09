# kube-prometheus-stack — full-cluster Prometheus monitoring stack.
#
# Wraps the upstream kube-prometheus-stack Helm chart via importChart.
# Includes Prometheus, Grafana, Alertmanager, node-exporter, and
# kube-state-metrics.
#
# Exposes the same out.mk* CRD builders as `prometheus-operator` so
# consumer packages (harbor, valkey, coredns, node-exporter, …) that
# request a `prometheus` build-arg get a working `mkPrometheusRule` /
# `mkServiceMonitor` / `mkPodMonitor` / `mkProbe` whether the cluster
# uses the helm-bridge stack or the native operator. See
# kix/packages/prometheus-operator/default.nix:289-298 for the
# canonical `out` shape.
#
# Defaults match prometheus-operator's defaultAliases so DI lookups
# resolve identically — naming the instance `prometheus` claims the
# same alias on both sides.
#
# Chart:   oci://ghcr.io/prometheus-community/charts
# Name:    kube-prometheus-stack
# Version: 71.2.0

{
  scope,
  lib,
  kix,
}:
let
  chart = scope.helm.fetchHelmChart {
    repo = "oci://ghcr.io/prometheus-community/charts";
    name = "kube-prometheus-stack";
    version = "71.2.0";
    hash = "sha256-TyftOI7LrTeqbU5IsVjRKb78xC1edDHwegq773QEuUM=";
  };

  defaultValues = {
    # --- Default rule overrides ---
    defaultRules = {
      overrides = {
        KubeDeploymentReplicasMismatch = {
          "for" = "1h";
        };
        KubeHpaMaxedOut = {
          "for" = "6h";
        };
        CPUThrottlingHigh = {
          "for" = "1h";
        };
        NodeDiskIOSaturation = {
          "for" = "6h";
        };
      };
    };

    # --- Prometheus ---
    prometheus = {
      enabled = true;
      prometheusSpec = {
        replicas = 1;
        resources = {
          requests = {
            cpu = "500m";
            memory = "2Gi";
          };
          limits = {
            cpu = "2";
            memory = "4Gi";
          };
        };
        # Scrape all ServiceMonitors across all namespaces.
        serviceMonitorSelectorNilUsesHelmValues = false;
        podMonitorSelectorNilUsesHelmValues = false;
        ruleSelectorNilUsesHelmValues = false;
        probeSelectorNilUsesHelmValues = false;
        scrapeConfigSelectorNilUsesHelmValues = false;
        # Security context.
        securityContext = {
          runAsNonRoot = true;
          runAsUser = 1000;
          runAsGroup = 2000;
          fsGroup = 2000;
        };
        scrapeInterval = "30s";
        evaluationInterval = "30s";
      };
    };

    # --- Grafana ---
    grafana = {
      enabled = true;
      replicas = 1;
      deploymentStrategy = {
        type = "Recreate";
      };
      persistence = {
        enabled = true;
        size = "10Gi";
      };
      resources = {
        requests = {
          cpu = "100m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "1Gi";
        };
      };
      sidecar = {
        dashboards = {
          enabled = true;
          searchNamespace = "ALL";
        };
        datasources = {
          enabled = true;
        };
      };
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1;
          providers = [
            {
              name = "default";
              orgId = 1;
              folder = "default";
              type = "file";
              disableDeletion = false;
              editable = true;
              options = {
                path = "/var/lib/grafana/dashboards/standard";
              };
            }
          ];
        };
      };
    };

    # --- Alertmanager ---
    alertmanager = {
      enabled = true;
      alertmanagerSpec = {
        replicas = 1;
        resources = {
          requests = {
            cpu = "0.01";
            memory = "256Mi";
          };
          limits = {
            cpu = "1";
            memory = "1Gi";
          };
        };
      };
      config = {
        global = {
          resolve_timeout = "5m";
        };
        route = {
          group_by = [
            "namespace"
            "alertname"
          ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
          receiver = "null";
          routes = [
            {
              receiver = "null";
              matchers = [ "alertname = Watchdog" ];
            }
          ];
        };
        receivers = [
          {
            name = "null";
          }
        ];
      };
    };

    # --- Node Exporter ---
    nodeExporter = {
      enabled = true;
    };
    prometheus-node-exporter = {
      resources = {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "1";
          memory = "128Mi";
        };
      };
      extraArgs = [
        "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
        "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)"
        "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector"
      ];
      extraHostVolumeMounts = [
        {
          name = "textfile-collector";
          hostPath = "/var/lib/node_exporter/textfile_collector";
          mountPath = "/var/lib/node_exporter/textfile_collector";
          readOnly = true;
        }
      ];
    };

    # --- Kube State Metrics ---
    kubeStateMetrics = {
      enabled = true;
    };
    kube-state-metrics = {
      resources = {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "1";
          memory = "256Mi";
        };
      };
    };

    # --- Global ---
    kubeEtcd.enabled = true;
    kubeProxy.enabled = true;
  };
in
{
  meta = {
    version = "71.2.0";
    isHelm = true;
    # The chart renders grafana's PVC itself (persistence.enabled above) —
    # the raw-PVC refusal needs an explicit escape here.
    unsafe = [ "raw-pvc" ];
    # Match prometheus-operator's defaultAliases so DI lookups work
    # like consumers expect — see kix/packages/prometheus-operator/
    # default.nix:30-33. Naming the instance `prometheus` claims the
    # same alias on both sides; consumer packages calling
    # `prometheus.out.mkPrometheusRule scope { ... }` work without
    # caring whether the operator is helm-bridged or native.
    defaultAliases = [
      "prometheus"
      "prometheusOperator"
    ];
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      # The chart renders Services over pods the operator creates at
      # runtime (alertmanager, prometheus, the thanos sidecar). No pod
      # template in the build matches them, so each declares the CR whose
      # pods it selects (kix.run/operand-of, read by the cross-resource
      # checks). The CR name comes from the operator's own pod labels in
      # the selector: `operator.prometheus.io/name: <cr>` on current
      # operators, `alertmanager: <cr>` / `prometheus: <cr>` on older ones.
      declareOperandServices = map (
        r:
        let
          sel = r.spec.selector or { };
          app = sel."app.kubernetes.io/name" or null;
          crName = if app == null then null else sel."operator.prometheus.io/name" or sel.${app} or null;
          kind =
            if app == "alertmanager" then
              "Alertmanager"
            else if app == "prometheus" then
              "Prometheus"
            else
              null;
          cr =
            if (r.kind or "") != "Service" || kind == null || crName == null then
              null
            else
              "monitoring.coreos.com/${kind}/${crName}";
        in
        if cr == null then r else lib.recursiveUpdate r { metadata.annotations.${kix.keys.operandOf} = cr; }
      );

      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = "prometheus";
        includeCrds = true;
        patchResources = declareOperandServices;
      };

      # CRD ref markers — point at the chart-installed CRDs so
      # consumer-built CRs (PrometheusRule, ServiceMonitor, …) get
      # auto-`requires` edges to the chart wave. Same group + version
      # + scope as the prometheus-operator CRDs.
      mkRef =
        kind: plural:
        scope.mkCRDRef {
          group = "monitoring.coreos.com";
          inherit kind plural;
          version = "v1";
          crdScope = "Namespaced";
        };

      ruleRef = mkRef "PrometheusRule" "prometheusrules";
      smonRef = mkRef "ServiceMonitor" "servicemonitors";
      pmonRef = mkRef "PodMonitor" "podmonitors";
      probeRef = mkRef "Probe" "probes";

      parts = resources.mkParts {
        root = resources.autoRoot;
      };
    in
    parts
    // {
      prometheusRulesRef = ruleRef;
      serviceMonitorsRef = smonRef;
      podMonitorsRef = pmonRef;
      probesRef = probeRef;

      root = parts.root // {
        # Carry the CRD-ref markers as `requires` so they install
        # before any CR consuming `out.mkPrometheusRule` etc.
        requires = (parts.root.requires or [ ]) ++ [
          ruleRef
          smonRef
          pmonRef
          probeRef
        ];

        out = (parts.root.out or { }) // {
          # Builder API mirrors kix/packages/prometheus-operator/
          # default.nix:289-298. Any package consuming `prometheus`
          # via DI works whether the operator was deployed natively
          # (prometheus-operator) or via this helm-bridge.
          mkPrometheusRule = ruleRef.out.mkCR;
          mkServiceMonitor = smonRef.out.mkCR;
          mkPodMonitor = pmonRef.out.mkCR;
          mkProbe = probeRef.out.mkCR;
          # mkPrometheus / mkAlertmanager are deliberately not exposed
          # — the chart owns those CRs.
        };
      };
    };
}
