# node-exporter: the Prometheus node exporter, reporting hardware and
# operating-system metrics for every node.
#
# Installs a DaemonSet on the host network and host PID namespace, with the
# host's /, /proc, and /sys mounted read-only, a ServiceAccount, and a
# Service on port 9100. With a `prometheus` dependency and
# `metrics.enabled`, it also renders a ServiceMonitor and alert rules
# through `kix.monitor`.
#
# Dependencies:
#   prometheus (optional)   the scraper whose ServiceMonitor and
#                           PrometheusRule builders it uses
#
# Minimal instance:
#
#   instances.monitoring.node-exporter.package = packages.node-exporter;
#
# `out`: the Service's `name`, `fqdn`, and `port`, and `version`, the
# node_exporter version `image.tag` names.
#
# Alerts, scoped to this instance's Service: no exporter target has been
# scraped for 10 minutes (`NodeExporterDown`, warning). With
# `metrics.hostAlerts` (the default), a filesystem predicted to fill within
# 24 hours (`NodeFilesystemSpaceFillingUp`, warning) or under 5% free
# (`NodeFilesystemAlmostOutOfSpace`, critical). prometheus-default-rules
# ships those two under the same names in its `nodeExporter` group, with
# memory, CPU, and the other host conditions, so a cluster that runs it
# turns `hostAlerts` off. One exporter of several down is `TargetDown`.
#
# Escape hatches: `extraArgs` for node_exporter flags, and the instance's
# `partsOverlays` (the DaemonSet tolerates every NoSchedule taint and runs
# on every Linux node).
#
# Limits: `meta.unsafe` declares `host-network`. The textfile collector
# reads /var/lib/node_exporter/textfile_collector on each host when
# `textfileCollector.enabled` is on.

{
  scope,
  lib,
  kix,
}:
let
  release = "v1.12.1";
  name = scope.instanceName;
  ns = scope.namespaceName;
  port = 9100;
  textfileDirectory = "/var/lib/node_exporter/textfile_collector";
in
{
  meta = {
    version = release;
    description = "Prometheus Node Exporter: host-level metrics";
    owner = "platform";
    defaultAliases = [ "nodeExporter" ];
    k8s.minVersion = "1.25";
    # A node-level exporter: host network and host PID namespace are what it
    # is for.
    unsafe = [
      "host-network"
    ];
    # Host network, host PID namespace, and hostPath mounts, which the
    # baseline Pod Security level forbids.
    podSecurity = "privileged";
  };

  options = {
    image = kix.options.image {
      repository = "quay.io/prometheus/node-exporter";
      tag = release;
      digest = "sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0";
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
    textfileCollector.enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Read `*.prom` files from ${textfileDirectory} on each host, which other host jobs write.";
    };
    metrics = kix.options.monitor // {
      hostAlerts = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Render NodeFilesystemSpaceFillingUp and NodeFilesystemAlmostOutOfSpace. prometheus-default-rules ships alerts of the same names in its `nodeExporter` group, so turn this off on a cluster that runs those rules. The monitoring module sets it to the opposite of `monitoring.defaultRules.enabled`.";
      };
    };
  };

  build = [
    (
      { self, config, ... }:
      let
        # node_exporter parses flags with kingpin (node_exporter.go
        # upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            {
              flags = [ "--web.listen-address=:${toString port}" ];
              reason = "the probes and the Service use port ${toString port}.";
            }
            {
              flags = [ "--path.sysfs=/host/sys" ];
              reason = "the package mounts the host's /sys at /host/sys.";
            }
            {
              flags = [ "--path.rootfs=/host/root" ];
              reason = "the package mounts the host's / at /host/root.";
            }
            {
              flags = [ "--path.procfs=/host/proc" ];
              reason = "the package mounts the host's /proc at /host/proc.";
            }
            # Filesystems and mount points that are not host storage.
            # extraArgs replaces either value by setting the same flag.
            {
              defaults = [
                "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
                "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/.+)($|/)"
              ];
            }
          ];
          # Keep this flag behind extraArgs. Moving it changes the pod
          # template of an instance that sets extraArgs, which restarts the
          # exporter on every node when a cluster upgrades Kix.
          after = [
            {
              flags = lib.optional config.textfileCollector.enabled "--collector.textfile.directory=${textfileDirectory}";
              names = [ "--collector.textfile.directory" ];
              from = "the textfileCollector.enabled option (mounted at ${textfileDirectory} when enabled)";
              fix = "Remove it from extraArgs and set textfileCollector.enabled instead.";
            }
          ];
        } config.extraArgs;

        hostMount = mountName: hostPath: {
          volume = {
            name = mountName;
            hostPath.path = hostPath;
          };
          mount = {
            name = mountName;
            mountPath = "/host/${mountName}";
            readOnly = true;
            mountPropagation = "HostToContainer";
          };
        };
        hostMounts = [
          (hostMount "sys" "/sys")
          (hostMount "root" "/")
          (hostMount "proc" "/proc")
        ];

        probe = {
          httpGet = {
            path = "/";
            port = "metrics";
          };
          periodSeconds = 10;
        };
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
              # Kubernetes' default; the exporter holds no state to drain.
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
                  inherit args;
                  ports = [ (kix.port "metrics" port) ];
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  livenessProbe = probe;
                  readinessProbe = probe;
                  volumeMounts =
                    map (m: m.mount) hostMounts
                    ++ lib.optional config.textfileCollector.enabled {
                      name = "textfile-collector";
                      mountPath = textfileDirectory;
                      readOnly = true;
                    };
                }
              ];
              volumes =
                map (m: m.volume) hostMounts
                ++ lib.optional config.textfileCollector.enabled {
                  name = "textfile-collector";
                  hostPath.path = textfileDirectory;
                };
              # Every node, the control plane included.
              tolerations = [
                {
                  operator = "Exists";
                  effect = "NoSchedule";
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            };
          };
        };

        service =
          self.daemonset
          |> kix.service.fromWorkload {
            inherit name;
            ports = [
              {
                name = "http-metrics";
                inherit port;
                targetPort = "metrics";
                protocol = "TCP";
              }
            ];
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          requires = [
            self.serviceAccount
            self.daemonset
          ];
          out.version = kix.image.version config.image;
        };
      }
    )
    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        scoped = ''namespace="${ns}", service="${name}"'';
        fs = ''${scoped}, fstype!="", mountpoint!=""'';
        hostAlerts = lib.optionalAttrs config.metrics.hostAlerts {
          NodeFilesystemSpaceFillingUp = {
            expr = "predict_linear(node_filesystem_avail_bytes{${fs}}[6h], 24*60*60) < 0 and node_filesystem_avail_bytes{${fs}} / node_filesystem_size_bytes{${fs}} < 0.4";
            "for" = "1h";
            severity = "warning";
            summary = "A filesystem is predicted to run out of space within 24 hours.";
            description = "The filesystem on {{ $labels.device }} at {{ $labels.mountpoint }} on {{ $labels.instance }} will fill within 24 hours at its current write rate. Find what is writing to it, and free space or grow the disk.";
          };
          NodeFilesystemAlmostOutOfSpace = {
            expr = "node_filesystem_avail_bytes{${fs}} / node_filesystem_size_bytes{${fs}} * 100 < 5";
            "for" = "30m";
            severity = "critical";
            summary = "A filesystem has less than 5% space left.";
            description = ''The filesystem on {{ $labels.device }} at {{ $labels.mountpoint }} on {{ $labels.instance }} has {{ printf "%.2f" $value }}% space left. Free space or grow the disk before writes fail.'';
          };
        };
      in
      kix.monitor {
        service = "service";
        port = "http-metrics";
        alerts = hostAlerts // {
          NodeExporterDown = {
            expr = "sum by (namespace, service) (up{${scoped}}) == 0 or absent(up{${scoped}})";
            "for" = "10m";
            severity = "warning";
            summary = "No node exporter is being scraped.";
            description = "Prometheus has scraped no node exporter of {{ $labels.namespace }}/{{ $labels.service }} for 10 minutes, so no node alert can fire. Check the DaemonSet's pods and the ServiceMonitor.";
          };
        };
      } args
    )
  ];
}
