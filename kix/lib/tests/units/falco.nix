# Tests for kix/packages/falco: the DaemonSet's privileges and host mounts,
# falco.yaml, the rules option and its refusals, the locked settings paths,
# the container runtime sockets, the metrics toggle, and the refusal of
# clusters that forbid node agents. Falco runs in namespace `security`.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  prometheusStub,
  publicKix,
  ...
}:

let
  falcoPackage = import ../../../packages/falco;
  platformRefusal = import ../../../packages/falco/platform.nix { inherit lib; };

  clusterWith =
    {
      config ? { },
      prometheus ? false,
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.security.falco = {
            package = falcoPackage;
            inherit config;
          };
        }
        (lib.optionalAttrs prometheus {
          instances.monitoring.prometheus.package = prometheusStub;
        })
      ]
      ++ modules
    );

  configMapOf = name: cluster: byName name (ofKind "ConfigMap" (manifests cluster));
  falcoYaml = cluster: builtins.fromJSON (configMapOf "falco-config" cluster).data."falco.yaml";
  daemonSetOf = cluster: byName "falco" (ofKind "DaemonSet" (manifests cluster));
  podOf = cluster: (daemonSetOf cluster).spec.template.spec;
  containerOf = cluster: builtins.head (podOf cluster).containers;
  hostPathsOf =
    cluster: map (v: v.hostPath.path) (builtins.filter (v: v ? hostPath) (podOf cluster).volumes);

  # The package's own assertions, called directly to read their messages.
  assertionMessages =
    config:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (falcoPackage {
          scope = {
            instanceName = "falco";
            namespaceName = "security";
          };
          inherit lib;
          kix = { };
        }).assertions
          { inherit config; }
      )
    );

  rule = {
    rule = "Test rule";
    desc = "A rule for the tests.";
    condition = "evt.type = open and proc.name = never-matches";
    output = "Test rule (proc=%proc.name)";
    priority = "NOTICE";
  };
in
{
  # The defaults: capabilities added to root, not privileged, no host
  # namespaces, AppArmor unconfined, and only the documented host paths.
  # falco.yaml runs modern_ebpf, writes JSON to stdout, and loads only the
  # image's rules. This is the positive control for the refusals below.
  falco-defaults =
    let
      c = clusterWith { };
      pod = podOf c;
      sc = (containerOf c).securityContext;
      cfg = falcoYaml c;
    in
    (
      sc.capabilities.add == [
        "BPF"
        "PERFMON"
        "SYS_RESOURCE"
        "SYS_PTRACE"
      ]
      && !(sc ? privileged)
      && sc.runAsUser == 0
      && sc.appArmorProfile.type == "Unconfined"
      && !(pod ? hostNetwork)
      && !(pod ? hostPID)
      && pod.automountServiceAccountToken == false
      &&
        hostPathsOf c == [
          "/proc"
          "/etc"
          "/sys/kernel/tracing"
          "/run/containerd"
          "/run/crio"
          "/run/k3s/containerd"
        ]
      && cfg.engine.kind == "modern_ebpf"
      && cfg.json_output
      && cfg.stdout_output.enabled
      && cfg.rules_files == [ "/etc/falco/falco_rules.yaml" ]
      && cfg.config_files == [ ]
      && cfg.webserver.listen_port == 8765
      # Falco exits at startup without a metrics interval, and the
      # container plugin rejects an engines block missing any engine key.
      && cfg.metrics.interval == "1h"
      && cfg.log_stderr
      &&
        builtins.attrNames (builtins.head cfg.plugins).init_config.engines == [
          "bpm"
          "containerd"
          "cri"
          "docker"
          "libvirt_lxc"
          "lxc"
          "podman"
        ]
      && configMapOf "falco-rules" c == null
    )
    || throw "falco defaults: ${builtins.toJSON { inherit sc cfg; }}";

  # A rules file renders into its own ConfigMap, mounted where falco.yaml's
  # rules_files lists it after the image's rules.
  falco-rules =
    let
      c = clusterWith { config.rules."50-custom" = [ rule ]; };
      cm = configMapOf "falco-rules" c;
    in
    (
      builtins.fromJSON cm.data."50-custom.yaml" == [ rule ]
      &&
        (falcoYaml c).rules_files == [
          "/etc/falco/falco_rules.yaml"
          "/etc/falco/rules.d"
        ]
      && builtins.any (m: m.mountPath == "/etc/falco/rules.d") (containerOf c).volumeMounts
      && (daemonSetOf c).spec.template.metadata.annotations ? "checksum/rules"
    )
    || throw "falco rules: ${builtins.toJSON cm}";

  # A rules entry with none or two of the rules-file keys, and a file name
  # that is not a plain name, are refused with messages naming them.
  falco-rules-refused =
    let
      twoKinds = assertionMessages {
        rules.custom = [ (rule // { macro = "m"; }) ];
      };
      noKind = assertionMessages {
        rules.custom = [ { condition = "x"; } ];
      };
      badName = assertionMessages {
        rules."custom.yaml" = [ rule ];
      };
    in
    (
      evalFails (clusterWith {
        config.rules.custom = [ { condition = "x"; } ];
      })
      && evalFails (clusterWith {
        config.rules."../custom" = [ rule ];
      })
      && evalFails (clusterWith {
        config.rules.custom = [ ];
      })
      && builtins.length twoKinds == 1
      && lib.hasInfix "rules.\"custom\"[0]" (builtins.head twoKinds)
      && builtins.length noKind == 1
      && builtins.length badName == 1
      && lib.hasInfix "\"custom.yaml\"" (builtins.head badName)
      && assertionMessages { rules.custom = [ rule ]; } == [ ]
    )
    || throw "falco rules refusals: ${builtins.toJSON { inherit twoKinds noKind badName; }}";

  # Each locked settings path is refused, the kmod driver among them, and
  # so is the HTTP output; other keys merge over the package's.
  falco-locked-settings =
    let
      withSettings = settings: clusterWith { config = { inherit settings; }; };
      accepted = builtins.filter (s: !(evalFails (withSettings s))) [
        { engine.kind = "kmod"; }
        { engine.kind = "modern_ebpf"; }
        { config_files = [ "/etc/falco/config.d" ]; }
        { rules_files = [ "/etc/falco/falco_rules.yaml" ]; }
        { load_plugins = [ ]; }
        { plugins = [ ]; }
        { webserver.enabled = false; }
        { webserver.listen_port = 8080; }
        { webserver.listen_address = "127.0.0.1"; }
        { webserver.k8s_healthz_endpoint = "/health"; }
        { webserver.ssl_enabled = true; }
        { webserver.prometheus_metrics_enabled = false; }
        { metrics.enabled = false; }
        { webserver = null; }
        { http_output.enabled = true; }
        { program_output.enabled = true; }
        { file_output.enabled = true; }
      ];
      merged = falcoYaml (withSettings {
        priority = "notice";
        engine.modern_ebpf.buf_size_preset = 6;
        json_output = false;
        http_output.enabled = false;
      });
    in
    (
      accepted == [ ]
      && merged.priority == "notice"
      &&
        merged.engine == {
          kind = "modern_ebpf";
          modern_ebpf.buf_size_preset = 6;
        }
      && merged.json_output == false
    )
    || throw "falco settings accepted locked paths: ${builtins.toJSON accepted}";

  # A socket set to null is dropped; sockets in one directory share a
  # mount; a relative path is refused by the option type.
  falco-runtime-sockets =
    let
      c = clusterWith {
        config.containerRuntime.sockets = {
          crio = null;
          k3s = null;
          extra = "/run/containerd/other.sock";
        };
      };
      plugin = builtins.head (falcoYaml c).plugins;
    in
    (
      plugin.init_config.engines.cri.sockets == [
        "/run/containerd/containerd.sock"
        "/run/containerd/other.sock"
      ]
      &&
        hostPathsOf c == [
          "/proc"
          "/etc"
          "/sys/kernel/tracing"
          "/run/containerd"
        ]
      && evalFails (clusterWith {
        config.containerRuntime.sockets.extra = "run/x.sock";
      })
    )
    || throw "falco runtime sockets: ${builtins.toJSON plugin}";

  # With a prometheus dependency, the metrics Service and the
  # ServiceMonitor are built; the dependency does not change falco.yaml or
  # the pod template. metrics.enabled = false turns the endpoint off.
  falco-metrics =
    let
      scraped = clusterWith { prometheus = true; };
      plain = clusterWith { };
      off = clusterWith {
        prometheus = true;
        config.metrics.enabled = false;
      };
      services = cluster: map (s: s.metadata.name) (ofKind "Service" (manifests cluster));
    in
    (
      builtins.elem "falco-metrics" (services scraped)
      && !(builtins.elem "falco-metrics" (services plain))
      && !(builtins.elem "falco-metrics" (services off))
      && (falcoYaml scraped).webserver.prometheus_metrics_enabled
      && (falcoYaml scraped).metrics.enabled
      && falcoYaml scraped == falcoYaml plain
      && (daemonSetOf scraped).spec.template == (daemonSetOf plain).spec.template
      && !(falcoYaml off).webserver.prometheus_metrics_enabled
      && !(falcoYaml off).metrics.enabled
    )
    || throw "falco metrics: ${builtins.toJSON (services scraped)}";

  # A cluster that forbids DaemonSets or privileged pods is refused, the
  # GKE Autopilot flavour among them. The message names each capability.
  # The lib refuses the same clusters on its own, so the message is read
  # from the package's check directly.
  falco-platform-refused =
    let
      message =
        capabilities:
        platformRefusal {
          who = "falco security/falco";
          inherit capabilities;
          provider = "gke-autopilot";
        };
      both = message {
        daemonSets = false;
        privilegedContainers = false;
      };
    in
    (
      evalFails (clusterWith {
        modules = [ publicKix.flavors.gke-autopilot ];
      })
      && evalFails (clusterWith {
        modules = [ { cluster.capabilities.daemonSets = false; } ];
      })
      && evalFails (clusterWith {
        modules = [ { cluster.capabilities.privilegedContainers = false; } ];
      })
      && !(evalFails (clusterWith {
        modules = [
          {
            cluster.capabilities = {
              daemonSets = true;
              privilegedContainers = true;
            };
          }
        ];
      }))
      && lib.hasInfix "daemonSets = false and privilegedContainers = false (provider gke-autopilot)" both
      && lib.hasPrefix "falco security/falco: " both
      # The fix names no other platform, so it reads right on OpenShift.
      && !(lib.hasInfix "GKE" both)
      && lib.hasInfix "set the capability to true" both
      &&
        message {
          daemonSets = true;
          privilegedContainers = null;
        } == null
    )
    || throw "falco platform refusal: ${toString both}";
}
