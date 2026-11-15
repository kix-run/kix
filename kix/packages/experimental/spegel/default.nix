# spegel: Spegel, a peer-to-peer OCI registry mirror on every node, so a
# node pulls image layers that another node already holds from that node
# instead of the upstream registry.
#
# `out`: `version`, the Spegel version `image.tag` names.
#
# Installs a DaemonSet, a ServiceAccount with no API access, the headless
# Service <name>-bootstrap that the pods find each other through, and the
# NodePort Service <name>-registry. Each pod's init container writes a
# `hosts.toml` for every mirrored registry into containerd's registry
# config directory on its node, naming two mirrors: this node's pod
# through hostPort 30020 and any pod through NodePort 30021. containerd
# falls back to the upstream registry when neither answers. The registry
# container reads layers from containerd's content store through its
# socket and serves them to containerd and to its peers. With a
# `prometheus` dependency and `metrics.enabled`, it also renders Service
# <name>-metrics and a ServiceMonitor.
#
# The instance claims the `registryMirror` role, so a cluster runs one. The
# hostPort, the NodePort, and the files under the registry config directory
# are per node as well.
#
# Dependencies:
#   prometheus (optional)  metrics Service and ServiceMonitor.
#
# Minimal instance, on a cluster whose nodes keep unpacked layers:
#
#   instances.spegel.spegel.package = packages.experimental.spegel;
#
# Node prerequisites, which Kix cannot apply. The package reads them from
# the cluster definition and refuses a cluster that cannot serve:
#   - containerd, with a registry `config_path`. The socket, the config
#     directory, and the content store come from `cluster.containerd`,
#     which the flavours set (Talos and GKE move the config directory).
#   - `discard_unpacked_layers = false` in containerd's CRI config. kind,
#     Talos, EKS, and GKE turn it on, and their flavours set
#     `cluster.containerd.discardUnpackedLayers = true`, which the package
#     refuses. A cluster whose nodes turn it off sets the option to false;
#     null (unknown) evaluates with a warning.
#   - Two or more nodes. A pod is ready only once it has a peer, so on one
#     node the DaemonSet never becomes ready. `cluster.capabilities.multiNode
#     = false` (the kind flavour's default) is refused; null warns.
#   - hostPort support in the CNI (kindnet and the portmap plugin have it).
# k3s and RKE2 embed Spegel behind `embedded-registry: true`; a cluster
# that turns it on binds the role exclusive, and this package is then
# refused. Their flavours set the containerd paths under /var/lib/rancher.
#
# Network policy: the package's intents admit the node itself and the
# other nodes (Cilium's `host` and `remote-node`) to the registry port,
# where containerd connects through the hostPort and the NodePort. The pods
# reach each other through the bootstrap Service, which lists the registry
# and router ports, so their peer traffic is derived from it.
#
# Escape hatches: `extraArgs` for the registry command (the address,
# bootstrap, and containerd flags are refused) and the
# instance's `partsOverlays`. There is no `env` option: Spegel reads each
# flag from an environment variable too, which would bypass the refused
# flags. The DaemonSet tolerates every taint and runs on every Linux node.
#
# Limits: `meta.unsafe` declares `run-as-root`, which the containerd socket
# needs; the pods mount host paths, so `meta.podSecurity` is privileged.
# Removing the instance leaves the `hosts.toml` files on the nodes;
# containerd then gets connection refused from the mirrors and pulls from
# the upstream registry. The pods run at the built-in system-node-critical
# priority, as upstream's chart sets, so node pressure evicts them after
# application pods.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   SpegelDown (warning)  no Spegel pod answers a scrape. Pulls still work,
#                         because containerd falls back to the upstream
#                         registries, but every node now pulls from them,
#                         which can hit their rate limits.
# One node's pod down is left to prometheus-default-rules (TargetDown,
# KubeDaemonSetRolloutStuck). A mirror miss falls back the same way, so
# hit and miss counts (`spegel_mirror_requests_total`) are for dashboards.

{
  scope,
  lib,
  kix,
}:
let
  # meta.version and image.tag read this.
  release = "v0.7.4";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "spegel ${ns}/${name}";

  registryPort = 5000;
  routerPort = 5001;
  metricsPort = 9090;
  # Fixed by upstream's chart, and written into every node's containerd
  # configuration, so one instance per cluster owns them.
  hostPort = 30020;
  nodePort = 30021;
  # Where each node keeps the pod's libp2p identity across restarts.
  dataDir = "/var/lib/spegel";

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = lib.removePrefix "v" release;
    description = "Spegel, a peer-to-peer OCI registry mirror that serves image layers from the nodes that already hold them";
    owner = "platform";
    roles = [ "registryMirror" ];
    # The registry container reads the containerd socket and content store,
    # which root owns on the host.
    unsafe = [ "run-as-root" ];
    # hostPath mounts and a hostPort, which the baseline Pod Security level
    # forbids.
    podSecurity = "privileged";
    network.intents.containerd.ingress = [
      {
        from = "world";
        entities = [
          "host"
          "remote-node"
        ];
        ports = [ (tcp registryPort) ];
      }
    ];
  };

  options = {
    image = kix.options.image {
      repository = "ghcr.io/spegel-org/spegel";
      tag = release;
      digest = "sha256:26c60b05e08ac738e8442bc389c5780bff0e1d8153956e45d810a2f1008cf56f";
    };

    # Memory as upstream's chart sets it, a request equal to the limit;
    # GOMEMLIMIT follows the limit.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "128Mi";
      };
      limits = {
        cpu = "1";
        memory = "128Mi";
      };
    };

    mirroredRegistries = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "https?://[^/ ]+");
      default = [ ];
      example = [
        "https://docker.io"
        "https://ghcr.io"
      ];
      description = "Registries containerd tries Spegel for, as `https://<host>`. Both the init container, which writes the mirror configuration, and the registry, which refuses other registries, read it. Empty mirrors every registry.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--registry-filters=:latest$" ];
      description = "Flags appended to the registry command's own. The address flags (`--registry-addr`, `--router-addr`, `--metrics-addr`), the bootstrap flags (`--bootstrap-kind`, `--dns-bootstrap-domain`, `--http-bootstrap-addr`, `--http-bootstrap-peer`, `--static-bootstrap-peers`), the containerd flags, `--mirrored-registries`, and `--data-dir` are refused. The debug web page is off; `--debug-web-enabled=true` turns it on.";
    };

    metrics = kix.options.monitor;
  };

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
        containerd = clusterConfig.cluster.containerd;
        multiNode = clusterConfig.cluster.capabilities.multiNode or null;

        # Refusals for nodes that cannot serve; see the header.
        nodeCheck =
          if containerd.discardUnpackedLayers == true then
            scope.fail {
              package = "spegel";
              clusterOption = "cluster.containerd.discardUnpackedLayers";
              message = "cluster.containerd.discardUnpackedLayers is true, so containerd deletes each image's layers once it has unpacked them and Spegel has nothing to serve.";
              fix = "Set discard_unpacked_layers = false in containerd's config on every node, in the same table the node image sets it in (on kind, a containerdConfigPatches entry for [plugins.\"io.containerd.grpc.v1.cri\".containerd]), then set cluster.containerd.discardUnpackedLayers = false.";
            }
          else if multiNode == false then
            scope.fail {
              package = "spegel";
              clusterOption = "cluster.capabilities.multiNode";
              message = "cluster.capabilities.multiNode is false. A Spegel pod reports ready only once it has a peer, so on one node the DaemonSet never becomes ready.";
              fix = "Remove the instance, or set multiNode = true on a cluster with two or more nodes.";
            }
          else
            lib.warnIf (containerd.discardUnpackedLayers == null)
              "${who}: cluster.containerd.discardUnpackedLayers is not set, so Kix cannot tell whether containerd keeps the layers Spegel serves. Set it to match the nodes' containerd config; Spegel needs discard_unpacked_layers = false."
              (
                lib.warnIf (multiNode == null)
                  "${who}: cluster.capabilities.multiNode is not set. A Spegel pod reports ready only once it has a peer, so on one node the DaemonSet never becomes ready."
                  null
              );

        registryArgs = [
          "registry"
          "--registry-addr=:${toString registryPort}"
          "--router-addr=:${toString routerPort}"
          "--metrics-addr=:${toString metricsPort}"
          "--containerd-sock=${containerd.socket}"
          "--containerd-content-path=${containerd.contentPath}"
          "--bootstrap-kind=dns"
          "--dns-bootstrap-domain=${self.bootstrap.out.fqdn}"
          "--data-dir=${dataDir}"
          "--debug-web-enabled=false"
        ]
        ++ lib.optionals (config.mirroredRegistries != [ ]) (
          [ "--mirrored-registries" ] ++ config.mirroredRegistries
        )
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--registry-addr" =
              "the hostPort, the NodePort, the probes, and the network policy use ${toString registryPort}; remove it.";
            "--router-addr" = "the peers reach each other on ${toString routerPort}; remove it.";
            "--metrics-addr" = "the metrics Service uses ${toString metricsPort}; remove it.";
            "--containerd-sock" = "the package mounts cluster.containerd.socket; set that instead.";
            "--containerd-content-path" =
              "the package mounts cluster.containerd.contentPath; set that instead.";
            "--containerd-namespace" = "kubelet pulls into containerd's k8s.io namespace; remove it.";
            "--bootstrap-kind" = "the pods find each other through the bootstrap Service; remove it.";
            "--dns-bootstrap-domain" = "the package names the bootstrap Service; remove it.";
            "--http-bootstrap-addr" = "the pods find each other through the bootstrap Service; remove it.";
            "--http-bootstrap-peer" = "the pods find each other through the bootstrap Service; remove it.";
            "--static-bootstrap-peers" = "the pods find each other through the bootstrap Service; remove it.";
            "--mirrored-registries" =
              "the init container writes the mirror configuration from it as well; set mirroredRegistries instead.";
            "--data-dir" = "the package mounts ${dataDir} from the host; remove it.";
          };
        } config.extraArgs;

        nodeIp = {
          name = "NODE_IP";
          valueFrom.fieldRef.fieldPath = "status.hostIP";
        };

        hostVolume = volumeName: path: type: {
          name = volumeName;
          hostPath = { inherit path type; };
        };

        containerSecurity = {
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilities.drop = [ "ALL" ];
        };
        image = kix.image.ref config.image;
      in
      builtins.seq nodeCheck {
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
              serviceAccount = self.serviceAccount;
              automountServiceAccountToken = false;
              # Kubernetes' default; a pull in progress fails over to the
              # upstream registry.
              terminationGracePeriodSeconds = 30;
              # The image runs as root (meta.unsafe above).
              securityContext.seccompProfile.type = "RuntimeDefault";
              initContainers = [
                {
                  name = "configuration";
                  inherit image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "configuration"
                    "--containerd-registry-config-path=${containerd.registryConfigPath}"
                  ]
                  ++ lib.optionals (config.mirroredRegistries != [ ]) (
                    [ "--mirrored-registries" ] ++ config.mirroredRegistries
                  )
                  ++ [
                    "--mirror-targets"
                    "http://$(NODE_IP):${toString hostPort}"
                    "http://$(NODE_IP):${toString nodePort}"
                  ];
                  env = [ nodeIp ];
                  resources = config.resources;
                  securityContext = containerSecurity;
                  volumeMounts = [
                    {
                      name = "containerd-config";
                      mountPath = containerd.registryConfigPath;
                    }
                  ];
                }
              ];
              containers = [
                {
                  name = "registry";
                  inherit image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = registryArgs;
                  env = [
                    nodeIp
                  ]
                  ++ lib.optional ((config.resources.limits or { }) ? memory) {
                    name = "GOMEMLIMIT";
                    valueFrom.resourceFieldRef = {
                      resource = "limits.memory";
                      divisor = "1";
                    };
                  };
                  ports = [
                    ((kix.port "registry" registryPort) // { inherit hostPort; })
                    (kix.port "router-tcp" routerPort)
                    (
                      (kix.port "router-quic" routerPort)
                      // {
                        protocol = "UDP";
                      }
                    )
                    (kix.port "metrics" metricsPort)
                  ];
                  resources = config.resources;
                  securityContext = containerSecurity;
                  # A pod waits for its first peer, so startup is allowed
                  # three minutes, as upstream's chart allows.
                  startupProbe = {
                    httpGet = {
                      path = "/readyz";
                      port = "registry";
                    };
                    periodSeconds = 3;
                    failureThreshold = 60;
                  };
                  readinessProbe.httpGet = {
                    path = "/readyz";
                    port = "registry";
                  };
                  # /livez answers while the HTTP server runs, whatever the
                  # peers do.
                  livenessProbe.httpGet = {
                    path = "/livez";
                    port = "registry";
                  };
                  volumeMounts = [
                    {
                      name = "containerd-sock";
                      mountPath = containerd.socket;
                    }
                    {
                      name = "containerd-content";
                      mountPath = containerd.contentPath;
                      readOnly = true;
                    }
                    {
                      name = "data";
                      mountPath = dataDir;
                    }
                  ];
                }
              ];
              volumes = [
                (hostVolume "containerd-config" containerd.registryConfigPath "DirectoryOrCreate")
                (hostVolume "containerd-sock" containerd.socket "Socket")
                (hostVolume "containerd-content" containerd.contentPath "Directory")
                (hostVolume "data" dataDir "DirectoryOrCreate")
              ];
              # A built-in class, present in every cluster.
              priorityClassName = "system-node-critical";
              # Every node pulls images, so every node runs a mirror.
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
                {
                  operator = "Exists";
                  effect = "NoExecute";
                }
                {
                  operator = "Exists";
                  effect = "NoSchedule";
                }
              ];
              nodeSelector."kubernetes.io/os" = "linux";
            };
          };
        };

        # The pods resolve this name to find peers. rawSelector reads the
        # DaemonSet's labels without forcing its manifest, which names this
        # Service. Not-ready pods are listed, because a pod becomes ready
        # only once it has found a peer.
        bootstrap = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-bootstrap";
          labels."app.kubernetes.io/component" = "bootstrap";
          spec = {
            clusterIP = "None";
            publishNotReadyAddresses = true;
            selector = self.daemonset.rawSelector;
            ports = [
              {
                name = "registry";
                port = registryPort;
                targetPort = registryPort;
                protocol = "TCP";
              }
              {
                name = "router-tcp";
                port = routerPort;
                targetPort = routerPort;
                protocol = "TCP";
              }
              {
                name = "router-quic";
                port = routerPort;
                targetPort = routerPort;
                protocol = "UDP";
              }
            ];
          };
        };

        registryService = lib.pipe self.daemonset [
          (kix.service.fromWorkload {
            name = "${name}-registry";
            type = "NodePort";
            labels."app.kubernetes.io/component" = "registry";
            ports = [
              {
                name = "registry";
                port = registryPort;
                targetPort = "registry";
                inherit nodePort;
                protocol = "TCP";
              }
            ];
            # Keeps NodePort traffic in the caller's zone where it can.
            annotations."service.kubernetes.io/topology-mode" = "auto";
          })
          scope.mkResource
        ];

        metricsService =
          if config.metrics.enabled && prometheus != null then
            lib.pipe self.daemonset [
              (kix.service.fromWorkload {
                name = "${name}-metrics";
                labels."app.kubernetes.io/component" = "metrics";
                ports = [
                  {
                    name = "metrics";
                    port = metricsPort;
                    targetPort = "metrics";
                    protocol = "TCP";
                  }
                ];
              })
              scope.mkResource
            ]
          else
            null;

        root = {
          resource = self.daemonset;
          requires = [
            self.serviceAccount
            self.bootstrap
            self.registryService
          ];
          out.version = kix.image.version config.image;
        };
      }
    )
    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts.SpegelDown = {
          expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
          "for" = "10m";
          severity = "warning";
          summary = "Spegel is down on every node.";
          description = "No pod of Spegel ${ns}/${name} has answered a scrape for 10 minutes. containerd pulls every image from the upstream registries meanwhile, which can hit their rate limits. Check the DaemonSet in ${ns}.";
        };
      }
    )
  ];
}
