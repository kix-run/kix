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
# config directory on its node, naming one mirror: NodePort 30021 on the
# node's own address. The Service's `trafficDistribution: PreferSameNode`
# sends that traffic to the node's own pod, and to a pod on another node
# when the node has no ready pod. containerd falls back to the upstream
# registry when the mirror does not answer. The registry container reads
# layers from containerd's content store through its socket and serves
# them to containerd and to its peers. With a
# `prometheus` dependency and `metrics.enabled`, it also renders Service
# <name>-metrics and a ServiceMonitor.
#
# The instance claims the `registryMirror` role, so a cluster runs one. The
# NodePort and the files under the registry config directory are per node
# as well.
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
#   - Kubernetes 1.34 or later (meta.k8s), for `trafficDistribution:
#     PreferSameNode`. Spegel supports 1.35 to 1.37, and a cluster outside
#     that gets a warning.
#   - containerd 2.2 or later, with a registry `config_path`. The registry
#     container exits with an error on an older containerd. Kix has no
#     fact for the containerd version, so it cannot refuse one. The socket, the config
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
#   - A Service proxy that honours `trafficDistribution` (kube-proxy
#     does). Without it, containerd still reaches a pod through the
#     NodePort, but often one on another node.
# k3s and RKE2 embed Spegel behind `embedded-registry: true`; a cluster
# that turns it on binds the role exclusive, and this package is then
# refused. Their flavours set the containerd paths under /var/lib/rancher.
#
# Network policy: the package's intents admit the node itself and the
# other nodes (Cilium's `host` and `remote-node`) to the registry port,
# where containerd connects through the NodePort. The pods
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
#
# Upgrades: Spegel keeps no data the version reads. Each node holds the
# pod's libp2p key in /var/lib/spegel and the `hosts.toml` files the init
# container writes. Spegel 0.8 reads the key 0.7 wrote, and its init
# container rewrites each `hosts.toml` to name only the NodePort. During
# the rolling update, a node that still runs 0.7 names hostPort 30020
# first, and falls back to the NodePort, which stays at 30021 for that
# reason. Spegel 0.8 replaces the metrics `spegel_advertised_images`,
# `spegel_advertised_image_tags`, and `spegel_advertised_image_digests`
# with `spegel_advertised_keys`. Upstream says nothing about going back. To
# go back, deploy the previous Kix version: Spegel 0.7 reads the same key,
# and its init container writes the two-mirror `hosts.toml` again.

{
  scope,
  lib,
  kix,
}:
let
  # meta.version and image.tag read this.
  release = "v0.8.1";

  name = scope.instanceName;
  ns = scope.namespaceName;

  registryPort = 5000;
  routerPort = 5001;
  metricsPort = 9090;
  # Written into every node's containerd configuration, so one instance
  # per cluster owns it. Upstream's chart moved to 30020 in 0.8, the
  # hostPort that 0.7 pods hold while a rolling update runs, so the
  # package keeps 30021.
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
    version = release;
    description = "Spegel, a peer-to-peer OCI registry mirror that serves image layers from the nodes that already hold them";
    owner = "platform";
    roles = [ "registryMirror" ];
    # The registry Service sets `trafficDistribution: PreferSameNode`, a
    # value that Kubernetes serves from 1.34 (the Spegel pull request that
    # added it names 1.34 as the version that introduced it), so an older
    # cluster is refused. Upstream supports the latest three Kubernetes
    # minors at the time of a release and tests 1.35 to 1.37 at 0.8. It
    # states no failure on a newer version, so none is refused. Move
    # `supported` with `release`.
    k8s = {
      minVersion = "1.34";
      reason = "[K8826] Spegel ${release} sets trafficDistribution: PreferSameNode on its registry Service, which Kubernetes 1.33 and older reject. Upgrade the cluster to Kubernetes 1.34 or newer and update k8sVersion, or stay on an older version of Kix.";
      supported = {
        minVersion = "1.35";
        maxVersion = "1.37";
        source = "Spegel's support policy (the three latest Kubernetes minor versions) and integration tests";
      };
    };
    # The registry container reads the containerd socket and content store,
    # which root owns on the host.
    unsafe = [ "run-as-root" ];
    # hostPath mounts, which the baseline Pod Security level forbids.
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
      digest = "sha256:bdc1d14e4ab76e9a74520d331f485d09a596110118bd1a7706fa0411f17b3703";
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
      description = "Flags appended to the registry command's own. The address flags (`--registry-addr`, `--router-addr`, `--metrics-addr`), the bootstrap flags (`--bootstrap-kind`, `--dns-bootstrap-domain`, `--http-bootstrap-url`, `--http-bootstrap-cert-dir`, `--static-bootstrap-peers`), the containerd flags, `--mirrored-registries`, and `--data-dir` are refused. The debug web page is off; `--debug-web-enabled=true` turns it on.";
    };

    metrics = kix.options.monitor;
  };

  # The build refuses these two cluster settings when they rule Spegel out.
  # When one is unset, Kix cannot tell, so it warns.
  warnings =
    { clusterConfig, ... }:
    lib.optional (clusterConfig.cluster.containerd.discardUnpackedLayers == null) {
      clusterOption = "cluster.containerd.discardUnpackedLayers";
      message = "cluster.containerd.discardUnpackedLayers is not set, so Kix built Spegel without checking whether containerd keeps image layers after unpacking them. If containerd discards layers after unpacking, Spegel has nothing to serve to other nodes.";
      fix = "Verify that containerd sets discard_unpacked_layers = false on every node, then set cluster.containerd.discardUnpackedLayers = false in the cluster definition. If nodes discard layers after unpacking and you cannot change containerd, remove this Spegel instance and set cluster.containerd.discardUnpackedLayers = true.";
    }
    ++ lib.optional ((clusterConfig.cluster.capabilities.multiNode or null) == null) {
      clusterOption = "cluster.capabilities.multiNode";
      message = "cluster.capabilities.multiNode is not set, so Kix built Spegel without checking whether the cluster has multiple nodes. Each Spegel pod waits for a peer on another node before reporting ready, so on a single-node cluster the DaemonSet never becomes ready.";
      fix = "Set cluster.capabilities.multiNode = true in the cluster definition if the cluster has two or more nodes. On a single-node cluster, remove this Spegel instance and set cluster.capabilities.multiNode = false.";
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
              clusterOption = "cluster.containerd.discardUnpackedLayers";
              message = "cluster.containerd.discardUnpackedLayers is true, so containerd deletes each image's layers once it has unpacked them and Spegel has nothing to serve.";
              fix = "Set discard_unpacked_layers = false in containerd's config on every node, in the same table the node image sets it in (on kind, a containerdConfigPatches entry for [plugins.\"io.containerd.grpc.v1.cri\".containerd]), then set cluster.containerd.discardUnpackedLayers = false.";
            }
          else if multiNode == false then
            scope.fail {
              clusterOption = "cluster.capabilities.multiNode";
              message = "cluster.capabilities.multiNode is false. A Spegel pod reports ready only once it has a peer, so on one node the DaemonSet never becomes ready.";
              fix = "Remove the instance, or set multiNode = true on a cluster with two or more nodes.";
            }
          else
            null;

        # Spegel parses flags with go-arg (main.go upstream).
        registryArgs = kix.mergeArgs {
          inherit scope;
          parser = "go-arg";
          id = "K8006";
          args = [
            "registry"
            {
              owned = [ "--registry-addr=:${toString registryPort}" ];
              reason = "the NodePort, the probes, and the network policy use ${toString registryPort}.";
            }
            {
              owned = [ "--router-addr=:${toString routerPort}" ];
              reason = "the peers reach each other on ${toString routerPort}.";
            }
            {
              owned = [ "--metrics-addr=:${toString metricsPort}" ];
              reason = "the metrics Service uses ${toString metricsPort}.";
            }
            {
              owned = [ "--containerd-sock=${containerd.socket}" ];
              reason = "the package mounts cluster.containerd.socket.";
              fix = "Set cluster.containerd.socket instead.";
            }
            {
              owned = [ "--containerd-content-path=${containerd.contentPath}" ];
              reason = "the package mounts cluster.containerd.contentPath.";
              fix = "Set cluster.containerd.contentPath instead.";
            }
            # Spegel compares it with the path containerd 2.4 and later
            # reports, and refuses to start when they differ.
            {
              owned = [ "--containerd-registry-config-path=${containerd.registryConfigPath}" ];
              reason = "the init container writes cluster.containerd.registryConfigPath.";
              fix = "Set cluster.containerd.registryConfigPath instead.";
            }
            {
              owned = [ "--bootstrap-kind=dns" ];
              reason = "the pods find each other through the bootstrap Service.";
            }
            {
              owned = [ "--dns-bootstrap-domain=${self.bootstrap.out.fqdn}" ];
              reason = "the package names the bootstrap Service.";
            }
            {
              owned = [ "--data-dir=${dataDir}" ];
              reason = "the package mounts ${dataDir} from the host.";
            }
            "--debug-web-enabled=false"
            {
              owned = lib.optionals (config.mirroredRegistries != [ ]) (
                [ "--mirrored-registries" ] ++ config.mirroredRegistries
              );
              names = [ "--mirrored-registries" ];
              reason = "the init container writes the mirror configuration from it as well.";
              fix = "Set mirroredRegistries instead.";
            }
            {
              names = [ "--containerd-namespace" ];
              reason = "kubelet pulls into containerd's k8s.io namespace.";
            }
            {
              names = [
                "--http-bootstrap-url"
                "--http-bootstrap-cert-dir"
                "--static-bootstrap-peers"
              ];
              reason = "the pods find each other through the bootstrap Service.";
            }
          ];
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
                    (kix.port "registry" registryPort)
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

        registryService =
          self.daemonset
          |> kix.service.fromWorkload {
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
            # containerd on each node reaches its own pod, and another node's
            # pod when its own is not ready.
            spec.trafficDistribution = "PreferSameNode";
          }
          |> scope.mkResource;

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.daemonset
            |> kix.service.fromWorkload {
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
            }
            |> scope.mkResource
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
