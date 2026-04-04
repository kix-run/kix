# node-exporter — Prometheus exporter for hardware and OS metrics.
#
# DaemonSet that runs on every node, exposing /proc and /sys metrics.
# Ships its own ServiceMonitor and PrometheusRules via optional prometheus DI.

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
    version = "v1.9.0";
    description = "Prometheus Node Exporter — host-level metrics";
    provides = [ "node-metrics" ];
    defaultAliases = [ "nodeExporter" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/prometheus/node-exporter";
        tag = "v1.9.0";
        pullPolicy = "IfNotPresent";
      };
    };
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "1";
          memory = "128Mi";
        };
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--path.sysfs=/host/sys"
        "--path.rootfs=/host/root"
        "--path.procfs=/host/proc"
        "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
        "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)"
      ];
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
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              fsGroup = 65534;
            };
            containers = [
              {
                name = "node-exporter";
                image = "${config.image.repository}:${config.image.tag}";
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--web.listen-address=[$(HOST_IP)]:9100"
                ]
                ++ config.extraArgs
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
                livenessProbe = {
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
            };
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
              selector.matchLabels = self.daemonset.out.selector;
              endpoints = [
                {
                  port = "http-metrics";
                  interval = config.metrics.interval or "30s";
                }
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
                      description = "Node {{ $labels.instance }} memory usage is {{ printf \"%.0f\" $value | float64 }}%.";
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
