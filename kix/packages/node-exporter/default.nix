# node-exporter: the Prometheus node exporter, reporting hardware and
# operating-system metrics for every node.
#
# Installs a DaemonSet on the host network and host PID namespace, with the
# host's /, /proc, and /sys mounted read-only, a ServiceAccount, and a
# Service on port 9100. With a `prometheus` dependency and
# `metrics.enabled`, it also renders a ServiceMonitor and node alert rules
# through the dependency's builders.
#
# Dependencies:
#   prometheus (optional)   the scraper whose ServiceMonitor and
#                           PrometheusRule builders it uses
#
# Minimal instance:
#
#   instances.monitoring.node-exporter.package = packages.node-exporter;
#
# `out`: the DaemonSet's `name`.
#
# Escape hatches: `extraArgs` for node_exporter flags, and the instance's
# `partsOverlays`.
#
# Limits: `meta.unsafe` declares `host-network`. The textfile collector
# reads /var/lib/node_exporter/textfile_collector on each host when
# `textfileCollector` is on.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
in
{
  meta = {
    version = "v1.12.1";
    description = "Prometheus Node Exporter: host-level metrics";
    owner = "platform";
    defaultAliases = [ "nodeExporter" ];
    k8s.minVersion = "1.25";
    # A node-level exporter: host network and host PID namespace are what it
    # is for.
    unsafe = [
      "host-network"
    ];
  };

  options = {
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Merged over the default kubernetes.io/os=linux selector.";
    };
    image = kix.options.image {
      repository = "quay.io/prometheus/node-exporter";
      tag = "v1.12.1";
    };
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "1";
        memory = "128Mi";
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "node_exporter flags appended after the package's. A `--collector.filesystem.fs-types-exclude` or `--collector.filesystem.mount-points-exclude` here replaces the package's value of that flag. The listen address, the `--path.*` flags, and the textfile directory are refused; the probes, the Service, and the host mounts depend on them.";
    };
    textfileCollector = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    metrics = kix.options.monitor;
  };

  build =
    {
      self,
      config,
      prometheus ? null,
      ...
    }:
    let
      who = "node-exporter ${scope.namespaceName}/${scope.instanceName}";
      setsFlag = flag: lib.any (arg: arg == flag || lib.hasPrefix "${flag}=" arg) config.extraArgs;

      # Filesystems and mount points that are not host storage. Dropped
      # when extraArgs sets the same flag, so that it replaces the value.
      filesystemExcludes = lib.filterAttrs (flag: _: !setsFlag flag) {
        "--collector.filesystem.fs-types-exclude" =
          "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$";
        "--collector.filesystem.mount-points-exclude" =
          "^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)";
      };

      ownedArgs = kix.guardArgs {
        inherit who;
        owned = {
          "--web.listen-address" = "the probes and the Service use port 9100; remove it.";
          "--path.sysfs" = "the package mounts the host's /sys at /host/sys; remove it.";
          "--path.rootfs" = "the package mounts the host's / at /host/root; remove it.";
          "--path.procfs" = "the package mounts the host's /proc at /host/proc; remove it.";
          "--collector.textfile.directory" =
            "the package mounts the textfile directory when textfileCollector is on; remove it.";
        };
      } config.extraArgs;

      hasMetrics = config.metrics.enabled && prometheus != null;
      mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;
      mkPrometheusRule = if prometheus != null then prometheus.out.mkPrometheusRule scope else null;
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
        extra.automountServiceAccountToken = false;
      };

      daemonset = scope.mkDaemonSet {
        inherit name;
        spec = {
          selector.matchLabels = scope.selectorLabels;
          updateStrategy = {
            type = "RollingUpdate";
            rollingUpdate.maxUnavailable = 1;
          };
          template.spec = {
            serviceAccountName = self.serviceAccount.out.name;
            automountServiceAccountToken = false;
            hostNetwork = true;
            hostPID = true;
            # Kubernetes' default, set explicitly; the
            # prometheus-node-exporter chart (4.59.0) sets none.
            terminationGracePeriodSeconds = 30;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              fsGroup = 65534;
            };
            containers = [
              {
                name = "node-exporter";
                image = kix.image.ref config.image;
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--web.listen-address=[$(HOST_IP)]:9100"
                  "--path.sysfs=/host/sys"
                  "--path.rootfs=/host/root"
                  "--path.procfs=/host/proc"
                ]
                ++ lib.mapAttrsToList (flag: value: "${flag}=${value}") filesystemExcludes
                ++ ownedArgs
                ++ lib.optionals config.textfileCollector [
                  "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector"
                ];
                ports = [
                  (kix.port "metrics" 9100)
                ];
                env = [
                  {
                    name = "HOST_IP";
                    value = "0.0.0.0";
                  }
                ];
                resources = config.resources;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                  capabilities.add = [ "SYS_TIME" ];
                };
                # The prometheus-node-exporter chart (4.59.0) gives both
                # probes the same GET /.
                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = 9100;
                  };
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/";
                    port = 9100;
                  };
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                volumeMounts = [
                  {
                    name = "sys";
                    mountPath = "/host/sys";
                    readOnly = true;
                    mountPropagation = "HostToContainer";
                  }
                  {
                    name = "root";
                    mountPath = "/host/root";
                    readOnly = true;
                    mountPropagation = "HostToContainer";
                  }
                  {
                    name = "proc";
                    mountPath = "/host/proc";
                    readOnly = true;
                    mountPropagation = "HostToContainer";
                  }
                ]
                ++ lib.optional config.textfileCollector {
                  name = "textfile-collector";
                  mountPath = "/var/lib/node_exporter/textfile_collector";
                  readOnly = true;
                };
              }
            ];
            volumes = [
              {
                name = "sys";
                hostPath.path = "/sys";
              }
              {
                name = "root";
                hostPath.path = "/";
              }
              {
                name = "proc";
                hostPath.path = "/proc";
              }
            ]
            ++ lib.optional config.textfileCollector {
              name = "textfile-collector";
              hostPath.path = "/var/lib/node_exporter/textfile_collector";
            };
            tolerations = [
              {
                operator = "Exists";
                effect = "NoSchedule";
              }
            ];
            nodeSelector = {
              "kubernetes.io/os" = "linux";
            }
            // config.nodeSelector;
          };
        };
      };

      service =
        {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          spec = {
            type = "ClusterIP";
            selector = self.daemonset.out.selector;
            ports = [
              {
                name = "http-metrics";
                port = 9100;
                targetPort = 9100;
                protocol = "TCP";
              }
            ];
          };
        }
        |> scope.mkResource;

      # ── Monitoring artifacts (optional via DI) ──────────────────────────

      serviceMonitor =
        if hasMetrics then
          mkServiceMonitor {
            name = "${name}-monitor";
            spec = {
              # A ServiceMonitor selects Services, not pods.
              selector.matchLabels = self.service.out.selector;
              endpoints = [
                (
                  {
                    port = "http-metrics";
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) {
                    inherit (config.metrics) interval;
                  }
                )
              ];
            };
          }
        else
          null;

      alertRules =
        if hasMetrics then
          mkPrometheusRule {
            name = "${name}-alerts";
            spec.groups = [
              {
                name = "node-exporter";
                rules = [
                  {
                    alert = "NodeFilesystemSpaceFillingUp";
                    expr = ''predict_linear(node_filesystem_avail_bytes{fstype!="",mountpoint!=""}[6h], 24*60*60) < 0 and node_filesystem_avail_bytes{fstype!="",mountpoint!=""} / node_filesystem_size_bytes{fstype!="",mountpoint!=""} < 0.4'';
                    "for" = "1h";
                    labels.severity = "warning";
                    annotations = {
                      summary = "Filesystem is predicted to run out of space within 24h.";
                      description = "Filesystem on {{ $labels.device }} at {{ $labels.instance }} is predicted to run out of space within the next 24 hours at current write rate.";
                    };
                  }
                  {
                    alert = "NodeFilesystemAlmostOutOfSpace";
                    expr = ''node_filesystem_avail_bytes{fstype!="",mountpoint!=""} / node_filesystem_size_bytes{fstype!=""} * 100 < 5'';
                    "for" = "30m";
                    labels.severity = "critical";
                    annotations = {
                      summary = "Filesystem has less than 5% space left.";
                      description = "Filesystem on {{ $labels.device }} at {{ $labels.instance }} has only {{ printf \"%.2f\" $value }}% available space left.";
                    };
                  }
                  {
                    alert = "NodeHighMemoryUsage";
                    expr = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9";
                    "for" = "15m";
                    labels.severity = "warning";
                    annotations = {
                      summary = "Node memory usage above 90%.";
                      # `| float64` is not a template function in Prometheus or
                      # vmalert. Prometheus fails such a template only when the
                      # alert fires; the VM operator's converter validates it
                      # eagerly and rejects the whole rule group.
                      description = "Node {{ $labels.instance }} memory usage is {{ printf \"%.0f\" $value }}%.";
                    };
                  }
                  {
                    alert = "NodeHighCPUUsage";
                    expr = ''100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90'';
                    "for" = "15m";
                    labels.severity = "warning";
                    annotations = {
                      summary = "Node CPU usage above 90%.";
                      description = "Node {{ $labels.instance }} CPU usage is above 90% for more than 15 minutes.";
                    };
                  }
                ];
              }
            ];
          }
        else
          null;

      root = {
        resource = self.daemonset;
        requires = [
          self.serviceAccount
          self.service
        ]
        ++ lib.optional (self.serviceMonitor != null) self.serviceMonitor
        ++ lib.optional (self.alertRules != null) self.alertRules;
      };
    };
}
