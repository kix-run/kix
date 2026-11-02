# prometheus-default-rules: the standard Kubernetes alerting and recording
# rules, and ServiceMonitors for the Kubernetes components that no package
# renders.
#
# Renders one PrometheusRule per rule group under ./rules, taken from the
# kube-prometheus-stack 84.5.0 chart's output, and ServiceMonitors for the
# API server, the kubelets, CoreDNS, etcd, kube-controller-manager,
# kube-scheduler, and kube-proxy. A component that runs as pods in
# kube-system gets a headless "bridge" Service there that selects them (or,
# with `monitors.<component>.endpoints`, lists fixed addresses), because a
# ServiceMonitor selects Services. The kubelet monitor reads the Service the
# operator maintains (`prometheusOperator.out.kubeletService`).
#
# The rules name their targets by `job` label, the name of the scraped
# Service, and some by namespace. The package fills them in from its
# dependencies: kube-state-metrics, node-exporter, the Prometheus server,
# Alertmanager, and the operator's own metrics Service. The `alertmanager`
# and `prometheus` rule groups are left out without a dependency that
# publishes `out.namespace` (the alertmanager and prometheus packages do);
# the kube-state-metrics and node-exporter groups fall back to the job names
# `kube-state-metrics` and `node-exporter`.
#
# Dependencies:
#   prometheusOperator (required)  the operator, whose builders make the
#                                  rules and monitors.
#   kubeStateMetrics, nodeExporter, prometheusServer, alertmanager
#                                  (optional) the scrape targets the rules
#                                  name.
#   dns (optional)                 the cluster DNS; read only for
#                                  `out.scrapedByPrometheus`.
#
# Minimal instance:
#
#   instances.monitoring-system.default-rules.package = packages.prometheus-default-rules;
#
# Bridge Services live in kube-system, which every instance in every
# namespace shares, so their names carry a hash of the instance's namespace.
#
# Escape hatches: `ruleOverrides` patches single alerts,
# `monitors.<component>.endpoint` merges fields into a monitor's endpoints
# (TLS client certificates for etcd, intervals, relabelings), and the
# instance's `partsOverlays`.
#
# Turning a component's monitor off also leaves out the rule groups that
# read only its series (`KubeSchedulerDown`, `KubeControllerManagerDown`,
# `KubeProxyDown`, and the etcd group), which would otherwise fire on the
# missing target. The monitoring module turns the control-plane monitors
# off on kind and under a managed control plane.
#
# The CoreDNS monitor is left out when the `dns` provider reports that its
# own ServiceMonitor scrapes it (`out.scrapedByPrometheus`, which the
# coredns package publishes), so its series are not scraped twice.
#
# Limits: on kubeadm clusters, kube-controller-manager, kube-scheduler,
# kube-proxy, and etcd bind their metrics to 127.0.0.1, so those targets
# stay down until the cluster binds them to the node address or their
# monitors are turned off.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  who = "prometheus-default-rules ${scope.namespaceName}/${name}";

  saToken = "/var/run/secrets/kubernetes.io/serviceaccount/token";
  saCa = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";

  # The kube-prometheus-stack chart's metric drops: high-cardinality series
  # that its dashboards and alerts do not read.
  apiserverDrops = [
    {
      action = "drop";
      regex = "(etcd_request|apiserver_request_slo|apiserver_request_sli|apiserver_request)_duration_seconds_bucket;(0\\.15|0\\.2|0\\.3|0\\.35|0\\.4|0\\.45|0\\.6|0\\.7|0\\.8|0\\.9|1\\.25|1\\.5|1\\.75|2|3|3\\.5|4|4\\.5|6|7|8|9|15|20|40|45|50)(\\.0)?";
      sourceLabels = [
        "__name__"
        "le"
      ];
    }
  ];
  kubeletDrops = [
    {
      action = "drop";
      regex = "(csi_operations|storage_operation_duration)_seconds_bucket;(0.25|2.5|15|25|120|600)(\\.0)?";
      sourceLabels = [
        "__name__"
        "le"
      ];
    }
  ];
  cAdvisorDrops =
    let
      drop = sourceLabels: regex: {
        action = "drop";
        inherit regex sourceLabels;
      };
      byName = drop [ "__name__" ];
    in
    [
      (byName "container_cpu_(cfs_throttled_seconds_total|load_average_10s|system_seconds_total|user_seconds_total)")
      (byName "container_fs_(io_current|io_time_seconds_total|io_time_weighted_seconds_total|reads_merged_total|sector_reads_total|sector_writes_total|writes_merged_total)")
      (byName "container_memory_(mapped_file|swap)")
      (byName "container_(file_descriptors|tasks_state|threads_max)")
      (drop [ "__name__" "scope" ] "container_memory_failures_total;hierarchy")
      (drop [ "__name__" "interface" ] "container_network_.*;(cali|cilium|cni|lxc|nodelocaldns|tunl).*")
      (byName "container_spec.*")
      (drop [ "id" "pod" ] ".+;")
    ];
  metricsPathLabel = [
    {
      action = "replace";
      sourceLabels = [ "__metrics_path__" ];
      targetLabel = "metrics_path";
    }
  ];

  # Components that run as pods in kube-system and get a bridge Service.
  # `job` is the bridge's `jobLabel` label, which the rules match.
  bridged = {
    coredns = {
      component = "coredns";
      job = "coredns";
      selector.k8s-app = "kube-dns";
      port = 9153;
      endpoint.bearerTokenFile = saToken;
      # CoreDNS runs as pods everywhere it runs at all.
      fixedAddresses = false;
    };
    etcd = {
      component = "kube-etcd";
      job = "kube-etcd";
      selector.component = "etcd";
      ruleFiles = [ "etcd" ];
      port = 2381;
      endpoint.bearerTokenFile = saToken;
    };
    kubeControllerManager = {
      component = "kube-controller-manager";
      job = "kube-controller-manager";
      selector.component = "kube-controller-manager";
      ruleFiles = [ "kubernetes-system-controller-manager" ];
      port = 10257;
      endpoint = {
        scheme = "https";
        bearerTokenFile = saToken;
        # Its serving certificate is self-signed.
        tlsConfig = {
          caFile = saCa;
          insecureSkipVerify = true;
        };
      };
    };
    kubeScheduler = {
      component = "kube-scheduler";
      job = "kube-scheduler";
      selector.component = "kube-scheduler";
      ruleFiles = [
        "kube-scheduler.rules"
        "kubernetes-system-scheduler"
      ];
      port = 10259;
      endpoint = {
        scheme = "https";
        bearerTokenFile = saToken;
        # Its serving certificate is self-signed.
        tlsConfig = {
          caFile = saCa;
          insecureSkipVerify = true;
        };
      };
    };
    kubeProxy = {
      component = "kube-proxy";
      job = "kube-proxy";
      selector.k8s-app = "kube-proxy";
      ruleFiles = [ "kubernetes-system-kube-proxy" ];
      port = 10249;
      endpoint.bearerTokenFile = saToken;
    };
  };

  endpointOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    example = {
      scheme = "https";
      tlsConfig = {
        caFile = "/etc/prometheus/secrets/etcd-client/ca.crt";
        certFile = "/etc/prometheus/secrets/etcd-client/tls.crt";
        keyFile = "/etc/prometheus/secrets/etcd-client/tls.key";
      };
    };
    description = "Fields deep-merged into each of this monitor's ServiceMonitor endpoints, such as `interval`, `scheme`, `tlsConfig`, or `metricRelabelings` (a list replaces the package's). `port` and `path` are refused. A file named here must be in the Prometheus pods, for example a Secret listed in the prometheus instance's `extraSpec.secrets`, mounted at /etc/prometheus/secrets/<name>.";
  };

  bridgedOptions =
    _key: c:
    {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description =
          "Scrape ${c.component}."
          +
            lib.optionalString (c ? ruleFiles)
              " Off also leaves out the rule groups that read only its series: ${lib.concatStringsSep ", " c.ruleFiles}."
          + lib.optionalString (
            c.component == "coredns"
          ) " Skipped while the `dns` provider scrapes itself (`out.scrapedByPrometheus`).";
      };
      selector = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        defaultText = lib.literalExpression (lib.generators.toPretty { } c.selector);
        description = "Labels of the ${c.component} pods in kube-system that the bridge Service selects. A value replaces the default as a whole; null uses the default.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = c.port;
        description = "Port ${c.component} serves metrics on.";
      };
      endpoint = endpointOption;
    }
    // lib.optionalAttrs (c.fixedAddresses or true) {
      endpoints = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        example = [ "10.0.0.10" ];
        description = "Fixed IP addresses of ${c.component}, for a control plane that does not run as pods in the cluster. The bridge Service then selects no pods and an Endpoints object lists these addresses.";
      };
    };

  ruleOverride = lib.types.submodule {
    options = {
      expr = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Replaces the alert's PromQL expression.";
      };
      "for" = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Replaces how long the expression must hold before the alert fires.";
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Labels merged over the alert's, such as `severity`.";
      };
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Annotations merged over the alert's.";
      };
    };
  };

  # Every bundled file, with the rule toggle that renders it. The four split
  # container-resource groups record the same series as
  # `k8s.rules.container-resource`, so they are off by default as in the
  # chart.
  ruleFiles = {
    general = [
      "general.rules"
      "kube-prometheus-general.rules"
      "kube-prometheus-node-recording.rules"
      "k8s.rules.container-cpu-usage-second"
      "k8s.rules.container-memory-cache"
      "k8s.rules.container-memory-rss"
      "k8s.rules.container-memory-swap"
      "k8s.rules.container-memory-working-s"
      "k8s.rules.container-resource"
      "k8s.rules.pod-owner"
      "config-reloaders"
      "kubelet.rules"
    ];
    etcd = [ "etcd" ];
    kubeApiserver = [
      "kube-apiserver-availability.rules"
      "kube-apiserver-burnrate.rules"
      "kube-apiserver-histogram.rules"
      "kube-apiserver-slos"
    ];
    kubeScheduler = [
      "kube-scheduler.rules"
      "kubernetes-system-scheduler"
    ];
    kubeProxy = [ "kubernetes-system-kube-proxy" ];
    kubernetesApps = [ "kubernetes-apps" ];
    kubernetesResources = [ "kubernetes-resources" ];
    kubernetesStorage = [ "kubernetes-storage" ];
    kubernetesSystem = [
      "kubernetes-system"
      "kubernetes-system-apiserver"
      "kubernetes-system-controller-manager"
      "kubernetes-system-kubelet"
    ];
    nodeExporter = [
      "node-exporter"
      "node-exporter.rules"
      "node-network"
      "node.rules"
    ];
    kubeStateMetrics = [ "kube-state-metrics" ];
    alertmanager = [ "alertmanager.rules" ];
    prometheus = [ "prometheus" ];
    prometheusOperator = [ "prometheus-operator" ];
    k8sContainerCpuLimits = [ "k8s.rules.container-cpu-limits" ];
    k8sContainerCpuRequests = [ "k8s.rules.container-cpu-requests" ];
    k8sContainerMemoryLimits = [ "k8s.rules.container-memory-limits" ];
    k8sContainerMemoryRequests = [ "k8s.rules.container-memory-requests" ];
  };
  offByDefault = [
    "k8sContainerCpuLimits"
    "k8sContainerCpuRequests"
    "k8sContainerMemoryLimits"
    "k8sContainerMemoryRequests"
  ];

  # The alert names in the bundled files, for checking `ruleOverrides`.
  readRules = file: builtins.fromJSON (builtins.readFile ./rules/${file}-prometheusrule.json);
  bundledAlerts = lib.unique (
    lib.concatMap (
      file:
      lib.concatMap (g: map (r: r.alert) (builtins.filter (r: r ? alert) g.rules)) (readRules file).groups
    ) (lib.concatLists (builtins.attrValues ruleFiles))
  );
in
{
  meta = {
    description = "Default Kubernetes monitoring rules and service monitors";
    owner = "platform";
  };

  assertions =
    { config, ... }:
    let
      unknown = builtins.filter (a: !(builtins.elem a bundledAlerts)) (
        builtins.attrNames config.ruleOverrides
      );
    in
    [
      {
        assertion = unknown == [ ];
        message = "ruleOverrides names ${lib.concatStringsSep ", " unknown}, which no bundled rule group defines, so the override would change nothing. Check the alert name; the groups are the files under kix/packages/prometheus-default-rules/rules.";
      }
    ];

  options = {
    rules = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render the bundled PrometheusRules. Each other key turns one rule group on or off.";
      };
    }
    // lib.mapAttrs (
      group: _:
      lib.mkOption {
        type = lib.types.bool;
        default = !(builtins.elem group offByDefault);
        description = "Render the ${group} rule group.";
      }
    ) ruleFiles;
    ruleOverrides = lib.mkOption {
      type = lib.types.attrsOf ruleOverride;
      default = { };
      example = {
        NodeDiskIOSaturation."for" = "6h";
        CPUThrottlingHigh = {
          "for" = "1h";
          labels.severity = "info";
        };
      };
      description = "Changes to single alerts of the bundled rules, by alert name. A name that no bundled group defines is refused.";
    };
    runbookUrl = lib.mkOption {
      type = lib.types.strMatching "https?://.*/";
      default = "https://runbooks.prometheus-operator.dev/runbooks/";
      description = "Prefix of every alert's `runbook_url` annotation, ending in a slash.";
    };
    monitors = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render the component ServiceMonitors. Each component also has its own `enabled`.";
      };
      apiserver = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Scrape the API server through the `kubernetes` Service in `default`.";
        };
        endpoint = endpointOption;
      };
      kubelet = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Scrape every kubelet through the Service the operator maintains.";
        };
        cAdvisor.enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Also scrape the kubelets' /metrics/cadvisor, the container resource usage.";
        };
        probes.enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Also scrape the kubelets' /metrics/probes, the probe results.";
        };
        endpoint = endpointOption;
      };
    }
    // lib.mapAttrs bridgedOptions bridged;
  };

  build = [
    (
      {
        self,
        config,
        prometheusOperator,
        kubeStateMetrics ? null,
        nodeExporter ? null,
        prometheusServer ? null,
        alertmanager ? null,
        dns ? null,
        ...
      }:
      let
        mkRule = prometheusOperator.out.mkPrometheusRule scope;
        mkMonitor = prometheusOperator.out.mkServiceMonitor scope;
        kubeSystem = scope.forNamespace "kube-system";

        # Rule text names Services by plain strings; the values below
        # carry no dependency, because a rule needs none of these Services
        # to exist first.
        plain = s: builtins.unsafeDiscardStringContext (toString s);
        jobOf = dep: fallback: if dep == null then fallback else plain dep.out.name;
        # A provider that does not publish its namespace (an import, or
        # VictoriaMetrics answering `prometheusServer`) runs none of the
        # programs these rules watch, so its group is left out.
        named = dep: dep != null && dep.out ? namespace;
        promTarget = named prometheusServer;
        amTarget = named alertmanager;
        jobInNamespace = dep: ''job=\"${plain dep.out.name}\",namespace=\"${plain dep.out.namespace}\"'';

        # The chart's release (`prometheus`) and namespace are baked into the
        # Prometheus, Alertmanager, and operator rules.
        chartJob =
          component: ''job=\"prometheus-kube-prometheus-${component}\",namespace=\"monitoring-system\"'';
        rebake =
          builtins.replaceStrings
            (
              [
                "https://runbooks.prometheus-operator.dev/runbooks/"
                ''job=\"kube-state-metrics\"''
                ''job=\"node-exporter\"''
                (chartJob "operator")
              ]
              ++ lib.optional promTarget (chartJob "prometheus")
              ++ lib.optional amTarget (chartJob "alertmanager")
            )
            (
              [
                config.runbookUrl
                ''job=\"${jobOf kubeStateMetrics "kube-state-metrics"}\"''
                ''job=\"${jobOf nodeExporter "node-exporter"}\"''
                (jobInNamespace prometheusOperator)
              ]
              ++ lib.optional promTarget (jobInNamespace prometheusServer)
              ++ lib.optional amTarget (jobInNamespace alertmanager)
            );

        override =
          rule:
          let
            o = config.ruleOverrides.${rule.alert};
          in
          if rule ? alert && config.ruleOverrides ? ${rule.alert} then
            rule
            // lib.optionalAttrs (o.expr != null) { inherit (o) expr; }
            // lib.optionalAttrs (o."for" != null) { inherit (o) "for"; }
            // {
              labels = (rule.labels or { }) // o.labels;
              annotations = (rule.annotations or { }) // o.annotations;
            }
          else
            rule;

        ruleFromFile =
          file:
          let
            spec = builtins.fromJSON (rebake (builtins.readFile ./rules/${file}-prometheusrule.json));
          in
          mkRule {
            name = "${name}-${file}";
            spec = spec // {
              groups = map (g: g // { rules = map override g.rules; }) spec.groups;
            };
          };

        # A group whose target is not a dependency would match no series.
        targetPresent =
          group:
          {
            alertmanager = amTarget;
            prometheus = promTarget;
          }
          .${group} or true;
        groupsOn = lib.filterAttrs (
          group: _: config.rules.enabled && config.rules.${group} && targetPresent group
        ) ruleFiles;
        # A file that reads only one component's series goes with that
        # component's monitor.
        filesOff = lib.concatLists (
          lib.mapAttrsToList (
            key: c: lib.optionals (!config.monitors.${key}.enabled) (c.ruleFiles or [ ])
          ) bridged
        );
        rules = lib.listToAttrs (
          map (file: lib.nameValuePair "rule-${file}" (ruleFromFile file)) (
            builtins.filter (file: !(builtins.elem file filesOff)) (
              lib.concatLists (builtins.attrValues groupsOn)
            )
          )
        );

        endpointFor =
          key: base:
          kix.mergeGuarded {
            inherit who;
            what = "monitors.${key}.endpoint";
            locked = [
              [ "port" ]
              [ "path" ]
            ];
          } base config.monitors.${key}.endpoint;

        # A managed coredns with its own ServiceMonitor already scrapes the
        # pods the CoreDNS bridge would select.
        dnsScrapesItself = dns != null && (dns.out.scrapedByPrometheus or false);
        monitorOn =
          key:
          config.monitors.enabled
          && config.monitors.${key}.enabled
          && !(key == "coredns" && dnsScrapesItself);

        # A headless Service in kube-system over the component's pods, or
        # over fixed addresses.
        bridgedParts =
          key: c:
          let
            cfg = config.monitors.${key};
            fixed = cfg.endpoints or [ ];
            # kube-system is shared by every instance in every namespace. The
            # namespace hash keeps same-named instances apart.
            bridgeName = "${name}-${c.component}-${
              builtins.substring 0 8 (builtins.hashString "sha256" scope.namespaceName)
            }";
            labels = {
              "app.kubernetes.io/name" = bridgeName;
              jobLabel = c.job;
            };
            portSpec = {
              name = "http-metrics";
              inherit (cfg) port;
              protocol = "TCP";
            };
          in
          lib.optionalAttrs (monitorOn key) (
            {
              "monitor-${key}" = mkMonitor {
                name = "${name}-${c.component}";
                spec = {
                  jobLabel = "jobLabel";
                  namespaceSelector.matchNames = [ "kube-system" ];
                  selector.matchLabels."app.kubernetes.io/name" = bridgeName;
                  endpoints = [ (endpointFor key ({ port = "http-metrics"; } // c.endpoint)) ];
                };
              };
              "bridge-${key}" = kubeSystem.mkResource {
                apiVersion = "v1";
                kind = "Service";
                name = bridgeName;
                inherit labels;
                spec = {
                  clusterIP = "None";
                  ports = [ (portSpec // { targetPort = cfg.port; }) ];
                }
                // lib.optionalAttrs (fixed == [ ]) {
                  selector = if cfg.selector == null then c.selector else cfg.selector;
                };
              };
            }
            // lib.optionalAttrs (fixed != [ ]) {
              "endpoints-${key}" = kubeSystem.mkResource {
                apiVersion = "v1";
                kind = "Endpoints";
                name = bridgeName;
                inherit labels;
                extra.subsets = [
                  {
                    addresses = map (ip: { inherit ip; }) fixed;
                    ports = [ portSpec ];
                  }
                ];
              };
            }
          );

        kubelet = prometheusOperator.out.kubeletService;
        kubeletEndpoint = {
          port = "https-metrics";
          scheme = "https";
          honorLabels = true;
          honorTimestamps = true;
          bearerTokenFile = saToken;
          tlsConfig = {
            caFile = saCa;
            insecureSkipVerify = true;
          };
          relabelings = metricsPathLabel;
        };
      in
      rules
      // lib.concatMapAttrs bridgedParts bridged
      // lib.optionalAttrs (monitorOn "apiserver") {
        # The `kubernetes` Service in `default`, which the API server keeps.
        monitor-apiserver = mkMonitor {
          name = "${name}-apiserver";
          annotations.${kix.keys.monitorsExternalService} = "true";
          spec = {
            jobLabel = "component";
            namespaceSelector.matchNames = [ "default" ];
            selector.matchLabels = {
              component = "apiserver";
              provider = "kubernetes";
            };
            endpoints = [
              (endpointFor "apiserver" {
                port = "https";
                scheme = "https";
                bearerTokenFile = saToken;
                tlsConfig = {
                  caFile = saCa;
                  serverName = "kubernetes";
                  insecureSkipVerify = false;
                };
                metricRelabelings = apiserverDrops;
              })
            ];
          };
        };
      }
      // lib.optionalAttrs (monitorOn "kubelet") {
        # The Service the operator keeps over every node's kubelet; Kix
        # renders no Service with these labels.
        monitor-kubelet = mkMonitor {
          name = "${name}-kubelet";
          annotations.${kix.keys.monitorsExternalService} = "true";
          spec = {
            attachMetadata.node = false;
            jobLabel = "k8s-app";
            namespaceSelector.matchNames = [ kubelet.namespace ];
            selector.matchLabels = kubelet.labels;
            endpoints = [
              (endpointFor "kubelet" (kubeletEndpoint // { metricRelabelings = kubeletDrops; }))
            ]
            ++ lib.optional config.monitors.kubelet.cAdvisor.enabled (
              endpointFor "kubelet" (
                kubeletEndpoint
                // {
                  path = "/metrics/cadvisor";
                  interval = "10s";
                  trackTimestampsStaleness = true;
                  metricRelabelings = cAdvisorDrops;
                }
              )
            )
            ++ lib.optional config.monitors.kubelet.probes.enabled (
              endpointFor "kubelet" (kubeletEndpoint // { path = "/metrics/probes"; })
            );
          };
        };
      }
    )
    (
      { self, ... }:
      let
        parts = builtins.filter (
          n:
          lib.hasPrefix "rule-" n
          || lib.hasPrefix "monitor-" n
          || lib.hasPrefix "bridge-" n
          || lib.hasPrefix "endpoints-" n
        ) (builtins.attrNames self);
        resources = map (n: self.${n}) parts;
      in
      {
        root = {
          resource = if resources == [ ] then null else builtins.head resources;
          requires = resources;
        };
      }
    )
  ];
}
