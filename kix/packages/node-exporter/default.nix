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
# `out`: the Service's `name`, `fqdn`, and `port`.
#
# Alerts, scoped to this instance's Service: no exporter target has been
# scraped for 10 minutes (`NodeExporterDown`, warning). Disk, memory, CPU,
# and the other host conditions are the `nodeExporter` rule group of
# prometheus-default-rules, which reads this exporter's series; one exporter
# of several down is its `TargetDown`.
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
  who = "node-exporter ${ns}/${name}";
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
    metrics = kix.options.monitor;
  };

  build = [
    (
      { self, config, ... }:
      let
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
            "--web.listen-address" = "the probes and the Service use port ${toString port}; remove it.";
            "--path.sysfs" = "the package mounts the host's /sys at /host/sys; remove it.";
            "--path.rootfs" = "the package mounts the host's / at /host/root; remove it.";
            "--path.procfs" = "the package mounts the host's /proc at /host/proc; remove it.";
            "--collector.textfile.directory" =
              "the package mounts the textfile directory when textfileCollector.enabled is on; remove it.";
          };
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
                  args = [
                    "--web.listen-address=:${toString port}"
                    "--path.sysfs=/host/sys"
                    "--path.rootfs=/host/root"
                    "--path.procfs=/host/proc"
                  ]
                  ++ lib.mapAttrsToList (flag: value: "${flag}=${value}") filesystemExcludes
                  ++ ownedArgs
                  ++ lib.optional config.textfileCollector.enabled "--collector.textfile.directory=${textfileDirectory}";
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
        };
      }
    )
    (kix.monitor {
      service = "service";
      port = "http-metrics";
      alerts =
        let
          scoped = ''namespace="${ns}", service="${name}"'';
        in
        {
          NodeExporterDown = {
            expr = "sum by (namespace, service) (up{${scoped}}) == 0 or absent(up{${scoped}})";
            "for" = "10m";
            severity = "warning";
            summary = "No node exporter is being scraped.";
            description = "Prometheus has scraped no node exporter of {{ $labels.namespace }}/{{ $labels.service }} for 10 minutes, so no node alert can fire. Check the DaemonSet's pods and the ServiceMonitor.";
          };
        };
    })
  ];
}
