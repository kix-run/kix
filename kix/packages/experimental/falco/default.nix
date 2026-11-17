# falco: the Falco runtime security agent, watching system calls on every
# node through the modern eBPF driver and writing an alert for each rule
# match.
#
# Installs a DaemonSet on every Linux node (tolerating every NoSchedule
# taint), a ConfigMap holding the complete falco.yaml, a ServiceAccount with
# no API token, and, with `rules`, a ConfigMap of rule files. With a
# `prometheus` dependency and `metrics.enabled`, it also renders a metrics
# Service, a ServiceMonitor, and an alert through `kix.monitor`.
#
# Driver: only `modern_ebpf`, which is compiled into the Falco binary and
# needs no kernel module, headers, or driver loader. It needs Linux 5.8 or
# later with BTF (/sys/kernel/btf/vmlinux) on every node. The container runs
# as root with the runtime's default capabilities plus BPF, PERFMON,
# SYS_RESOURCE, and SYS_PTRACE, not as a privileged container, and with
# AppArmor unconfined. It mounts the host's /proc, /etc, and
# /sys/kernel/tracing read-only, and the directory of each container runtime
# socket in `containerRuntime.sockets`. It does not use the host's network or
# PID namespace.
#
# Rules and output: Falco loads the default rules shipped in the image
# (/etc/falco/falco_rules.yaml) and then the files of `rules`. It writes each
# alert to stdout as one JSON object per line (`json_output`), where a pod
# log shipper such as clickhouse-logs or loki-logs collects it with the
# other pod logs. Container and pod fields (`container.*`, `k8s.pod.*`,
# `k8s.ns.name`) come from the container plugin, which reads the runtime
# socket; the package does not load the k8smeta plugin and calls no API.
#
# Dependencies:
#   prometheus (optional)   the scraper whose ServiceMonitor and
#                           PrometheusRule builders it uses
#
# Minimal instance:
#
#   instances.security.falco.package = packages.experimental.falco;
#
# `out`: `version`, the Falco version `image.tag` names. No package consumes
# Falco.
#
# Prometheus alerts, scoped to this instance's metrics Service: Falco is not
# scraped for 5 minutes, or it drops alerts because its outputs queue is full.
#
# Escape hatches: `settings` (falco.yaml; the locked paths are listed in its
# description), `env`, and the instance's `partsOverlays`.
#
# Limits: evaluation refuses a cluster whose `cluster.capabilities` sets
# `daemonSets` or `privilegedContainers` to false: GKE Autopilot, and the
# OpenShift flavour's default. On OpenShift, a SecurityContextConstraints
# grant for the pod's capabilities and hostPath mounts is the cluster's to
# write; with it in place, set `cluster.capabilities.privilegedContainers =
# true`. On a node without one of the socket directories, the kubelet
# creates it empty. Falco's HTTP, program, and file outputs and
# falcosidekick are not supported.

{
  scope,
  lib,
  kix,
}:
let
  release = "0.45.2";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "falco ${ns}/${name}";

  # The webserver serves /healthz and, with metrics, /metrics.
  port = 8765;
  healthPath = "/healthz";

  # Falco and its container plugin prefix host paths with HOST_ROOT.
  hostRoot = "/host";
  configDir = "/etc/falco/kix";
  configFile = "falco.yaml";
  rulesDir = "/etc/falco/rules.d";
  # The rule files Falco ships in the image.
  defaultRulesFile = "/etc/falco/falco_rules.yaml";

  socketPath = lib.types.strMatching "/[^\n]*[^/\n]";
  ruleFileName = "[A-Za-z0-9][A-Za-z0-9_-]*";
  # The top-level keys of a Falco rules file entry.
  ruleItemKinds = [
    "rule"
    "macro"
    "list"
    "required_engine_version"
    "required_plugin_versions"
  ];

  # Falco outputs refused when enabled, with the reason.
  unsupportedOutputs = {
    http_output = "no network egress is derived for the HTTP receiver, so under default deny Falco cannot reach it.";
    program_output = "no network egress is derived for the destinations the program sends alerts to.";
    file_output = "the container's root filesystem is read-only.";
  };

  # settings paths the package sets, with the reason it owns each.
  lockedSettings = {
    "engine.kind" =
      "the package runs only the modern_ebpf driver, and its capabilities and host mounts are derived for it. The kmod driver needs a privileged container and kernel headers on every node, which this package does not grant. Remove engine.kind; engine.modern_ebpf settings are accepted";
    "config_files" =
      "falco.yaml from this package is the complete configuration, and the image's /etc/falco/config.d files would load the container plugin a second time. Put configuration in settings";
    "rules_files" =
      "the package loads the image's default rules and then the files of the rules option. Add rule files through rules";
    "load_plugins" =
      "the package loads the container plugin with the sockets of containerRuntime.sockets, which it mounts. Other plugins are not supported";
    "plugins" =
      "the package configures the container plugin from containerRuntime.sockets, which it mounts. Other plugins are not supported";
    "webserver.enabled" = "the probes read /healthz from the webserver";
    "webserver.listen_port" = "the probes and the metrics Service use port ${toString port}";
    "webserver.listen_address" = "the probes reach the webserver on the pod IP";
    "webserver.k8s_healthz_endpoint" = "the probes read ${healthPath}";
    "webserver.ssl_enabled" = "the probes and the ServiceMonitor use HTTP";
    "webserver.prometheus_metrics_enabled" = "metrics.enabled sets it";
    "metrics.enabled" = "metrics.enabled sets it";
  };
in
{
  meta = {
    version = release;
    description = "Falco runtime security agent: a DaemonSet watching system calls through the modern eBPF driver, with JSON alerts on stdout";
    owner = "platform";
    # securityContext.appArmorProfile is served from 1.30.
    k8s.minVersion = "1.30";
    # The eBPF driver is loaded by root with BPF, PERFMON, SYS_RESOURCE, and
    # SYS_PTRACE added to the runtime's default capabilities; the container
    # is not privileged.
    unsafe = [ "run-as-root" ];
    # hostPath mounts and capabilities beyond the baseline set.
    podSecurity = "privileged";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/falcosecurity/falco";
      tag = release;
      digest = "sha256:1562a643953f938e02f47319b5214d93a235f11f646d60e9b8a516fd5a64698e";
    };

    # The driver's ring buffers take memory per group of CPUs
    # (engine.modern_ebpf.buf_size_preset and cpus_for_each_buffer), so
    # large nodes may need a higher limit.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "512Mi";
      };
      limits = {
        cpu = "1";
        memory = "1024Mi";
      };
    };

    env = kix.options.env // {
      description = "Extra environment variables for Falco: a string, a `fieldRef` source, or a `kix.untrackedRef` secretKeyRef. HOST_ROOT and FALCO_HOSTNAME are set by the package.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nonEmptyListOf (lib.types.attrsOf lib.types.anything));
      default = { };
      example = {
        "50-shell-in-app" = [
          {
            macro = "app_namespace";
            condition = "k8s.ns.name = apps";
          }
          {
            rule = "Shell in app container";
            desc = "A shell started in a container of the apps namespace.";
            condition = "spawned_process and container and app_namespace and proc.name in (sh, bash)";
            output = "Shell in app container (user=%user.name command=%proc.cmdline container=%container.name)";
            priority = "WARNING";
          }
        ];
      };
      description = ''
        Extra Falco rule files, keyed by file name (letters, digits, `-`,
        and `_`; `.yaml` is appended). Each value is the file's list of
        entries, and each entry has exactly one of the keys
        ${lib.concatMapStringsSep ", " (k: "`${k}`") ruleItemKinds}.
        Falco loads them after the image's default rules, in file-name
        order, so a file may append to or override a default rule, list,
        or macro (`override`, or `enabled: false`).
      '';
    };

    containerRuntime.sockets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr socketPath);
      default = { };
      defaultText = lib.literalExpression ''
        {
          containerd = "/run/containerd/containerd.sock";
          crio = "/run/crio/crio.sock";
          k3s = "/run/k3s/containerd/containerd.sock";
        }
      '';
      example = {
        crio = null;
        rke2 = "/run/k3s/containerd/containerd.sock";
      };
      description = "CRI sockets the container plugin reads container and pod metadata from, keyed by any name; null removes a default. The package mounts each socket's directory from the host. A socket that does not exist on a node is skipped there.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        priority = "notice";
        engine.modern_ebpf.buf_size_preset = 6;
      };
      description = ''
        falco.yaml settings, deep-merged over the package's; a list
        replaces the package's list. The package sets
        `json_output: true`, `stdout_output.enabled: true`,
        `outputs_queue.capacity: 10000`,
        `time_format_iso_8601: true`, `log_stderr: true`, `log_syslog: false`,
        `syslog_output.enabled: false` (the image runs no syslog daemon),
        `metrics.interval: 1h`, and `metrics.output_rule: false`; these may
        be overridden. It
        locks ${lib.concatMapStringsSep ", " (p: "`${p}`") (builtins.attrNames lockedSettings)}.
        Setting a locked path fails evaluation. `http_output`,
        `program_output`, and `file_output` are refused: no network egress
        is derived for the first two, and the root filesystem is read-only.
      '';
    };

    metrics = kix.options.monitor;
  };

  config =
    { ... }:
    {
      containerRuntime.sockets = lib.mapAttrs (_: lib.mkDefault) {
        containerd = "/run/containerd/containerd.sock";
        crio = "/run/crio/crio.sock";
        k3s = "/run/k3s/containerd/containerd.sock";
      };
    };

  assertions =
    { config, ... }:
    let
      badNames = builtins.filter (n: builtins.match ruleFileName n == null) (
        builtins.attrNames config.rules
      );
      badEntries = lib.concatLists (
        lib.mapAttrsToList (
          file: entries:
          lib.concatLists (
            lib.imap0 (
              i: entry:
              lib.optional (
                builtins.length (builtins.filter (k: entry ? ${k}) ruleItemKinds) != 1
              ) "rules.\"${file}\"[${toString i}]"
            ) entries
          )
        ) config.rules
      );
    in
    [
      {
        assertion = badNames == [ ];
        message = "rules file names ${
          lib.concatMapStringsSep ", " (n: "\"${n}\"") badNames
        } are not allowed. Use letters, digits, `-`, and `_`, starting with a letter or digit; the package appends .yaml.";
      }
      {
        assertion = badEntries == [ ];
        message = "an entry of a Falco rules file has exactly one of the keys ${lib.concatStringsSep ", " ruleItemKinds}; ${lib.concatStringsSep ", " badEntries} does not. Give each entry one of them.";
      }
    ];

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        prometheus ? null,
        ...
      }:
      let
        # Only `metrics.enabled` changes falco.yaml and so the pod template;
        # a prometheus dependency adds the Service and the ServiceMonitor.
        metricsOn = config.metrics.enabled;
        scraped = metricsOn && prometheus != null;
        hasRules = config.rules != { };

        refusal = import ./platform.nix { inherit lib; } {
          inherit who;
          inherit (clusterConfig.cluster) capabilities provider;
        };

        sockets = builtins.filter (s: s != null) (builtins.attrValues config.containerRuntime.sockets);
        # One mount per socket directory, so the plugin sees a socket the
        # runtime recreates after a restart.
        socketMounts = lib.imap0 (
          i: dir:
          kix.mount.hostPath {
            name = "runtime-${toString i}";
            mountPath = "${hostRoot}${dir}";
            hostPath = dir;
            readOnly = true;
          }
        ) (lib.unique (map dirOf sockets));

        builtinSettings = {
          config_files = [ ];
          rules_files = [ defaultRulesFile ] ++ lib.optional hasRules rulesDir;
          engine.kind = "modern_ebpf";
          load_plugins = [ "container" ];
          plugins = [
            {
              name = "container";
              library_path = "libcontainer.so";
              # The CRI engine reports the pod and namespace of each
              # container. The plugin joins HOST_ROOT to each socket path.
              init_config.engines = {
                cri = {
                  enabled = true;
                  inherit sockets;
                };
                # The plugin's schema requires every engine key once
                # `engines` is set.
                docker.enabled = false;
                podman.enabled = false;
                containerd.enabled = false;
                lxc.enabled = false;
                libvirt_lxc.enabled = false;
                bpm.enabled = false;
              };
            }
          ];
          # Falco's default capacity, 0, leaves the queue of alerts waiting
          # for the outputs unbounded. When alerts arrive faster than the
          # outputs write them, the queue grows until the kernel kills Falco
          # at its memory limit. Bounded, Falco drops alerts and counts them
          # in falcosecurity_falco_outputs_queue_num_drops_total.
          outputs_queue.capacity = 10000;
          time_format_iso_8601 = true;
          json_output = true;
          stdout_output.enabled = true;
          syslog_output.enabled = false;
          log_stderr = true;
          log_syslog = false;
          webserver = {
            enabled = true;
            listen_port = port;
            listen_address = "0.0.0.0";
            k8s_healthz_endpoint = healthPath;
            ssl_enabled = false;
            prometheus_metrics_enabled = metricsOn;
          };
          # The Prometheus endpoint needs metrics.enabled. The output rule
          # would also write a metrics snapshot to stdout among the alerts.
          # Falco refuses to start with metrics enabled and no interval;
          # the interval paces only the output rule.
          metrics = {
            enabled = metricsOn;
            interval = "1h";
            output_rule = false;
          };
        };

        lockedPaths = lib.mapAttrsToList (path: reason: {
          inherit path reason;
          set = lib.hasAttrByPath (lib.splitString "." path) config.settings;
        }) lockedSettings;
        lockedSet = builtins.filter (l: l.set) lockedPaths;

        refusals =
          map (l: "settings sets ${l.path}, which the package owns: ${l.reason}.") lockedSet
          ++
            map
              (
                o:
                "settings sets ${o}.enabled, which the package does not support: ${unsupportedOutputs.${o}} Collect the JSON alerts from stdout with the cluster's log pipeline."
              )
              (
                builtins.filter (o: (config.settings.${o}.enabled or false) == true) (
                  builtins.attrNames unsupportedOutputs
                )
              );

        # A locked path whose ancestor settings replaces is refused by
        # mergeGuarded.
        falcoConfig =
          if refusals != [ ] then
            scope.fail {
              package = "falco";
              message = "${lib.concatStringsSep " " refusals}";
            }
          else
            kix.mergeGuarded {
              inherit who;
              what = "settings";
              locked = map (l: lib.splitString "." l.path) lockedPaths;
            } builtinSettings config.settings;

        probe =
          extra:
          {
            httpGet = {
              path = healthPath;
              port = "http";
            };
            timeoutSeconds = 5;
          }
          // extra;
      in
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "${name}-config";
          data.${configFile} = builtins.toJSON falcoConfig;
        };

        configMount = kix.mount.configMap self.configMap {
          mountPath = configDir;
          readOnly = true;
        };

        rulesConfigMap =
          if hasRules then
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-rules";
              data = lib.mapAttrs' (
                file: entries: lib.nameValuePair "${file}.yaml" (builtins.toJSON entries)
              ) config.rules;
            }
          else
            null;

        rulesMount =
          if hasRules then
            kix.mount.configMap self.rulesConfigMap {
              mountPath = rulesDir;
              readOnly = true;
            }
          else
            null;

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
          extra.automountServiceAccountToken = false;
        };

        daemonset =
          if refusal != null then
            scope.fail {
              package = "falco";
              message = refusal;
            }
          else
            {
              inherit name;
              spec = {
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.annotations = {
                    "checksum/config" = self.configMap.out.contentHash;
                  }
                  // lib.optionalAttrs hasRules {
                    "checksum/rules" = self.rulesConfigMap.out.contentHash;
                  };
                  spec = {
                    serviceAccount = self.serviceAccount;
                    automountServiceAccountToken = false;
                    # Kubernetes' default. Falco holds no state; alerts are
                    # written as they match.
                    terminationGracePeriodSeconds = 30;
                    containers = [
                      {
                        name = "falco";
                        image = kix.image.ref config.image;
                        imagePullPolicy = config.image.pullPolicy;
                        command = [ "/usr/bin/falco" ];
                        args = [
                          "-c"
                          "${configDir}/${configFile}"
                        ];
                        env = kix.mkEnvVars (
                          kix.mergeEnv {
                            inherit who;
                            owned = [
                              {
                                vars = {
                                  HOST_ROOT = hostRoot;
                                  # The `hostname` field of each alert.
                                  FALCO_HOSTNAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                                };
                                from = "the package, which mounts the host's paths under ${hostRoot} and names each alert's node";
                                fix = "Remove it from env.";
                              }
                            ];
                          } config.env
                        );
                        ports = [ (kix.port "http" port) ];
                        # Allows 100 s for loading the driver and the rules.
                        startupProbe = probe {
                          periodSeconds = 5;
                          failureThreshold = 20;
                        };
                        livenessProbe = probe { periodSeconds = 15; };
                        readinessProbe = probe { periodSeconds = 15; };
                        resources = config.resources;
                        securityContext = {
                          # Root, so the added capabilities are effective.
                          # The runtime's default capabilities stay: Falco
                          # reads /proc entries of processes owned by other
                          # users through DAC_OVERRIDE.
                          runAsUser = 0;
                          allowPrivilegeEscalation = false;
                          readOnlyRootFilesystem = true;
                          # BPF and PERFMON load the driver's tracing
                          # programs and maps, SYS_RESOURCE raises the
                          # locked memory limit for them, and SYS_PTRACE
                          # reads other processes' /proc entries.
                          capabilities.add = [
                            "BPF"
                            "PERFMON"
                            "SYS_RESOURCE"
                            "SYS_PTRACE"
                          ];
                          # containerd's default AppArmor profile allows
                          # ptrace reads only between containers under the
                          # same profile, which denies reading the /proc
                          # entries of host processes.
                          appArmorProfile.type = "Unconfined";
                        };
                      }
                    ];
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
            }
            |> kix.withMounts (
              [
                self.configMount
                self.rulesMount
                # The state of processes that started before Falco.
                (kix.mount.hostPath {
                  name = "proc";
                  mountPath = "${hostRoot}/proc";
                  hostPath = "/proc";
                  type = "Directory";
                  readOnly = true;
                })
                # /etc/passwd and /etc/group, for the user and group names
                # of host processes.
                (kix.mount.hostPath {
                  name = "etc";
                  mountPath = "${hostRoot}/etc";
                  hostPath = "/etc";
                  type = "Directory";
                  readOnly = true;
                })
                # libbpf reads tracepoint ids here when it attaches the
                # driver's syscall tracepoint programs.
                (kix.mount.hostPath {
                  name = "tracing";
                  mountPath = "/sys/kernel/tracing";
                  hostPath = "/sys/kernel/tracing";
                  type = "Directory";
                  readOnly = true;
                })
              ]
              ++ socketMounts
            )
            |> scope.mkDaemonSet;

        metricsService =
          if scraped then
            self.daemonset
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              ports = [
                {
                  name = "metrics";
                  inherit port;
                  targetPort = "http";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        root = {
          resource = self.daemonset;
          requires = builtins.filter (p: p != null) [
            self.metricsService
          ];
          out.version = kix.image.version config.image;
        };
      }
    )
    (kix.monitor {
      service = "metricsService";
      alerts =
        let
          scoped = ''namespace="${ns}", service="${name}-metrics"'';
        in
        {
          FalcoDown = {
            expr = "up{${scoped}} == 0";
            "for" = "5m";
            severity = "critical";
            summary = "A Falco agent is down.";
            description = "Prometheus has not scraped Falco at {{ $labels.instance }} for 5 minutes, so system calls on that node may go unwatched.";
          };
          FalcoDroppingAlerts = {
            expr = "sum by (namespace, service, instance) (increase(falcosecurity_falco_outputs_queue_num_drops_total{${scoped}}[10m])) > 0";
            severity = "warning";
            summary = "A Falco agent is dropping alerts.";
            description = "Falco at {{ $labels.instance }} dropped {{ $value }} alerts in 10 minutes because its outputs queue was full. Find the rule that is flooding and add an exception, or raise settings.outputs_queue.capacity together with the memory limit.";
          };
        };
    })
  ];
}
