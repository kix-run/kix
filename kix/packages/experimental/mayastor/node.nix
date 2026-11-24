# The node agents: io-engine (the SPDK data plane, with the metrics
# exporter in its pod) on the io-engine nodes, and csi-node and
# agent-ha-node on the nodes that mount Mayastor volumes. All three use the
# node's network and reach agent-core, etcd, and api-rest through cluster
# DNS.
{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) name hostDir;
  ep = c.endpoints self;
  fieldRef = c.fieldRef;

  kubeletDir = config.csiNode.kubeletDir;
  # The kubelet plugin directory keeps upstream's name, which differs from
  # the CSI driver name.
  pluginDir = "${kubeletDir}/plugins/io.openebs.mayastor/";

  hostPath = volume: path: type: {
    name = volume;
    hostPath = { inherit path type; };
  };

  nodeNameAndIp = {
    MY_NODE_NAME = fieldRef "spec.nodeName";
    MY_POD_IP = fieldRef "status.podIP";
  };

  hostNetworkPod = {
    hostNetwork = true;
    dnsPolicy = "ClusterFirstWithHostNet";
    priorityClassName = "system-node-critical";
    terminationGracePeriodSeconds = 30;
  };

  # csi-node and agent-ha-node talk over csi-node's socket, so they share
  # their placement.
  csiNodePlacement = {
    nodeSelector = config.csiNode.nodeSelector // c.amd64;
    tolerations = kix.tolerations.render config.csiNode.tolerations;
  };

  cpuCount = config.ioEngine.cpuCount;
  ioEngineCompute = {
    cpu = toString cpuCount;
    hugepages-2Mi = config.ioEngine.hugepages2Mi;
  };
in
{
  # Restarting io-engine drops every NVMe target on its node, so a changed
  # template waits until each pod is deleted, one node at a time, after
  # volume rebuilds finish.
  ioEngine = scope.mkDaemonSet {
    name = "${name}-io-engine";
    spec = {
      selector.matchLabels = c.componentLabels "io-engine";
      updateStrategy.type = "OnDelete";
      minReadySeconds = 10;
      template.spec = hostNetworkPod // {
        serviceAccount = self.ioEngineServiceAccount;
        nodeSelector = c.ioEngineLabels config // c.amd64;
        tolerations = kix.tolerations.render config.ioEngine.tolerations;
        initContainers = [
          (c.waitFor config "agent-core" self.agentCoreService.out.fqdn 50051)
          (c.waitFor config "etcd" self.etcdService.out.fqdn 2379)
        ];
        containers = [
          {
            name = "io-engine";
            image = kix.image.ref config.image;
            imagePullPolicy = config.image.pullPolicy;
            command = [ "io-engine" ];
            args = c.args {
              option = "ioEngine.extraArgs";
              args = [
                {
                  owned = [ "--grpc-ip=$(MY_POD_IP)" ];
                  reason = "io-engine listens on the pod's IP.";
                }
                {
                  owned = [ "--grpc-port=10124" ];
                  reason = "agent-core and the metrics exporter reach io-engine on port 10124.";
                }
                {
                  owned = [ "-N$(MY_NODE_NAME)" ];
                  reason = "io-engine registers under its Kubernetes node name, which DiskPools name.";
                }
                {
                  owned = [ "-R${ep.coreGrpc}" ];
                  reason = "the package points it at this instance's agent-core.";
                }
                {
                  owned = [ "-y${hostDir}/io-engine/config.yaml" ];
                  reason = "the config file lives in the io-engine host directory.";
                  fix = "Edit that file instead.";
                }
                {
                  owned = [ "-l${lib.concatMapStringsSep "," toString (lib.range 1 cpuCount)}" ];
                  reason = "the cores follow ioEngine.cpuCount, which also sets the CPU request.";
                  fix = "Set ioEngine.cpuCount, or core_list in the node's config.yaml.";
                }
                {
                  owned = [ "-p=${ep.etcdStore}" ];
                  reason = "the package points it at this instance's etcd.";
                }
                {
                  owned = [ "--ptpl-dir=${hostDir}/io-engine/ptpl/" ];
                  reason = "the reservation state lives in the io-engine host directory.";
                }
                {
                  names = [
                    "--grpc-endpoint"
                    "-g"
                  ];
                  reason = "the package sets --grpc-ip and --grpc-port.";
                }
                {
                  names = [ "-m" ];
                  reason = "the package sets the cores with -l from ioEngine.cpuCount, which also sets the CPU request.";
                  fix = "Set ioEngine.cpuCount, or core_list in the node's config.yaml.";
                }
                {
                  defaults = [
                    "--api-versions=v1"
                    "--tgt-crdt=30"
                    "--ps-retries=300"
                    "--pool-io-error-threshold=64"
                    "--pool-io-stall-deadline=110s110s"
                  ];
                }
              ];
            } config.ioEngine.extraArgs;
            env = c.env {
              option = "ioEngine.env";
              defaults = {
                RUST_LOG = "info";
                NVMF_TCP_NUM_SHARED_BUF = "2047";
                NVMF_TCP_BUF_CACHE_SIZE = "64";
                NVMF_TCP_MAX_QPAIRS_PER_CTRL = "32";
                NVMF_TCP_MAX_QUEUE_DEPTH = "32";
                NVMF_TCP_IN_CAPSULE_DATA_SIZE = "4096";
                NVMF_TCP_MAX_IO_SIZE = "131072";
                NVMF_TCP_IO_UNIT_SIZE = "131072";
                NVME_TIMEOUT = "110s";
                NVME_TIMEOUT_ADMIN = "30s";
                NVME_KATO = "10s";
                NVME_MAX_NAMESPACES = "4096";
                NEXUS_NVMF_ANA_ENABLE = "1";
                NEXUS_NVMF_RESV_ENABLE = "1";
                POOL_HANDLE_RESCAN_PERIOD = "5m";
              };
              # The pool key is read from a Secret in MY_POD_NAMESPACE.
              owned = nodeNameAndIp // {
                MY_POD_NAMESPACE = fieldRef "metadata.namespace";
              };
            } config.ioEngine.env;
            ports = [ (kix.port "io-engine" 10124) ];
            resources = lib.recursiveUpdate config.ioEngine.resources {
              requests = ioEngineCompute;
              limits = ioEngineCompute;
            };
            securityContext.privileged = true;
            volumeMounts = [
              {
                name = "device";
                mountPath = "/dev";
              }
              {
                name = "udev";
                mountPath = "/run/udev";
              }
              {
                name = "dshm";
                mountPath = "/dev/shm";
              }
              {
                name = "configlocation";
                mountPath = "${hostDir}/io-engine/";
              }
              {
                name = "hugepages-2mi";
                mountPath = "/dev/hugepages-2mi";
              }
            ];
          }
          {
            name = "metrics-exporter-io-engine";
            image = kix.image.ref config.metricsExporter.image;
            imagePullPolicy = config.metricsExporter.image.pullPolicy;
            args = c.args {
              option = "metricsExporter.extraArgs";
              args = [
                {
                  owned = [ "--metrics-endpoint=[::]:9502" ];
                  reason = "the metrics Service and ServiceMonitor use port 9502.";
                }
                {
                  owned = [ "--grpc-port=10124" ];
                  reason = "io-engine in the same pod listens on 10124.";
                }
                {
                  owned = [ "--rest-endpoint=${ep.rest}" ];
                  reason = "the package points it at this instance's api-rest.";
                }
                {
                  names = [ "-m" ];
                  reason = "the package sets --metrics-endpoint, which the metrics Service uses.";
                }
              ];
            } config.metricsExporter.extraArgs;
            env = c.env {
              option = "metricsExporter.env";
              owned = nodeNameAndIp;
            } config.metricsExporter.env;
            ports = [ (kix.port "metrics" 9502) ];
            resources = config.metricsExporter.resources;
          }
        ];
        volumes = [
          (hostPath "device" "/dev" "Directory")
          (hostPath "udev" "/run/udev" "Directory")
          {
            name = "dshm";
            emptyDir = {
              medium = "Memory";
              sizeLimit = "1Gi";
            };
          }
          {
            name = "hugepages-2mi";
            emptyDir.medium = "HugePages-2Mi";
          }
          (hostPath "configlocation" "${hostDir}/io-engine/" "DirectoryOrCreate")
        ];
      };
    };
    requires = lib.optional (self.ioEngineKeyRoleBinding != null) self.ioEngineKeyRoleBinding;
  };

  csiNode = scope.mkDaemonSet {
    name = "${name}-csi-node";
    spec = {
      selector.matchLabels = c.componentLabels "csi-node";
      updateStrategy = {
        type = "RollingUpdate";
        rollingUpdate.maxUnavailable = 1;
      };
      minReadySeconds = 10;
      template.spec =
        hostNetworkPod
        // csiNodePlacement
        // {
          serviceAccount = self.csiNodeServiceAccount;
          containers = [
            {
              name = "csi-node";
              image = kix.image.ref config.csiNode.image;
              imagePullPolicy = config.csiNode.image.pullPolicy;
              args = c.args {
                option = "csiNode.extraArgs";
                args = [
                  {
                    owned = [ "--csi-socket=/csi/csi.sock" ];
                    reason = "the registrar and agent-ha-node dial this socket.";
                  }
                  {
                    owned = [ "--node-name=$(MY_NODE_NAME)" ];
                    reason = "the plugin registers under its Kubernetes node name.";
                  }
                  {
                    owned = [ "--rest-endpoint=${ep.rest}" ];
                    reason = "the package points it at this instance's api-rest.";
                  }
                  "--enable-rest"
                  "--enable-registration"
                  {
                    owned = [ "--grpc-ip=$(MY_POD_IP)" ];
                    reason = "the plugin listens on the pod's IP.";
                  }
                  {
                    owned = [ "--grpc-port=10199" ];
                    reason = "agent-core reaches the plugin on port 10199.";
                  }
                  {
                    owned = [ "--kubelet-path=${kubeletDir}" ];
                    from = "the csiNode.kubeletDir option";
                    fix = "Set csiNode.kubeletDir instead.";
                  }
                  {
                    owned = [ "--nvme-nr-io-queues=${toString cpuCount}" ];
                    from = "the ioEngine.cpuCount option";
                    fix = "Set ioEngine.cpuCount instead.";
                  }
                  {
                    names = [ "-c" ];
                    reason = "the package sets --csi-socket, which the registrar and agent-ha-node dial.";
                  }
                  {
                    names = [ "-n" ];
                    reason = "the package sets --node-name to the Kubernetes node name.";
                  }
                  {
                    names = [
                      "--grpc-endpoint"
                      "-g"
                    ];
                    reason = "the package sets --grpc-ip and --grpc-port.";
                  }
                  {
                    defaults = [
                      "--nvme-io-timeout=110s10s"
                      "--nvme-core-io-timeout=110s10s"
                      "--nvme-ctrl-loss-tmo=1980"
                      "--nvme-connect-fallback=true"
                    ];
                  }
                ];
              } config.csiNode.extraArgs;
              env = c.env {
                option = "csiNode.env";
                defaults = {
                  RUST_LOG = "info";
                  RUST_BACKTRACE = "1";
                };
                owned = nodeNameAndIp;
              } config.csiNode.env;
              ports = [ (kix.port "csi-node" 10199) ];
              resources = config.csiNode.resources;
              # It runs nvme connect, writes nvme_core parameters, and mounts
              # filesystems.
              securityContext.privileged = true;
              volumeMounts = [
                {
                  name = "device";
                  mountPath = "/dev";
                }
                {
                  name = "sys";
                  mountPath = "/sys";
                }
                {
                  name = "run-udev";
                  mountPath = "/run/udev";
                }
                {
                  name = "plugin-dir";
                  mountPath = "/csi";
                }
                {
                  name = "kubelet-dir";
                  mountPath = kubeletDir;
                  mountPropagation = "Bidirectional";
                }
              ];
            }
            {
              name = "csi-driver-registrar";
              image = kix.image.ref config.nodeDriverRegistrar.image;
              imagePullPolicy = config.nodeDriverRegistrar.image.pullPolicy;
              args = [
                "--csi-address=/csi/csi.sock"
                "--kubelet-registration-path=${pluginDir}csi.sock"
              ];
              resources = config.csiSidecars.resources;
              securityContext.readOnlyRootFilesystem = true;
              volumeMounts = [
                {
                  name = "plugin-dir";
                  mountPath = "/csi";
                }
                {
                  name = "registration-dir";
                  mountPath = "/registration";
                }
              ];
            }
          ];
          volumes = [
            (hostPath "device" "/dev" "Directory")
            (hostPath "sys" "/sys" "Directory")
            (hostPath "run-udev" "/run/udev" "Directory")
            (hostPath "registration-dir" "${kubeletDir}/plugins_registry/" "Directory")
            (hostPath "plugin-dir" pluginDir "DirectoryOrCreate")
            (hostPath "kubelet-dir" kubeletDir "Directory")
          ];
        };
    };
    requires = [ self.csiNodeClusterRoleBinding ];
  };

  agentHaNode = scope.mkDaemonSet {
    name = "${name}-agent-ha-node";
    spec = {
      selector.matchLabels = c.componentLabels "agent-ha-node";
      updateStrategy = {
        type = "RollingUpdate";
        rollingUpdate.maxUnavailable = 1;
      };
      minReadySeconds = 10;
      template.spec =
        hostNetworkPod
        // csiNodePlacement
        // {
          serviceAccount = self.agentHaNodeServiceAccount;
          automountServiceAccountToken = false;
          initContainers = [ (c.waitFor config "agent-ha-cluster" self.agentCoreService.out.fqdn 50052) ];
          containers = [
            {
              name = "agent-ha-node";
              image = kix.image.ref config.agentHaNode.image;
              imagePullPolicy = config.agentHaNode.image.pullPolicy;
              args = c.args {
                option = "agentHaNode.extraArgs";
                args = [
                  {
                    owned = [ "--node-name=$(MY_NODE_NAME)" ];
                    reason = "it must equal the CSI node plugin's node name.";
                  }
                  {
                    owned = [ "--csi-socket=/csi/csi.sock" ];
                    reason = "the CSI node plugin listens on this socket.";
                  }
                  {
                    owned = [ "--grpc-ip=$(MY_POD_IP)" ];
                    reason = "agent-ha-node listens on the pod's IP.";
                  }
                  {
                    owned = [ "--grpc-port=50053" ];
                    reason = "agent-core reaches agent-ha-node on port 50053.";
                  }
                  {
                    owned = [ "--cluster-agent=${ep.clusterAgent}" ];
                    reason = "the package points it at this instance's agent-ha-cluster.";
                  }
                  {
                    names = [ "-n" ];
                    reason = "the package sets --node-name to the Kubernetes node name.";
                  }
                  {
                    names = [
                      "--grpc-endpoint"
                      "-g"
                    ];
                    reason = "the package sets --grpc-ip and --grpc-port.";
                  }
                  {
                    names = [ "-c" ];
                    reason = "the package sets --cluster-agent to this instance's agent-ha-cluster.";
                  }
                ];
              } config.agentHaNode.extraArgs;
              env = c.env {
                option = "agentHaNode.env";
                defaults = {
                  RUST_LOG = "info";
                  RUST_BACKTRACE = "1";
                };
                owned = nodeNameAndIp;
              } config.agentHaNode.env;
              ports = [ (kix.port "ha-node" 50053) ];
              resources = config.agentHaNode.resources;
              # It replaces failed NVMe paths on the node.
              securityContext.privileged = true;
              volumeMounts = [
                {
                  name = "device";
                  mountPath = "/dev";
                }
                {
                  name = "sys";
                  mountPath = "/sys";
                }
                {
                  name = "run-udev";
                  mountPath = "/run/udev";
                }
                {
                  name = "plugin-dir";
                  mountPath = "/csi";
                }
              ];
            }
          ];
          volumes = [
            (hostPath "device" "/dev" "Directory")
            (hostPath "sys" "/sys" "Directory")
            (hostPath "run-udev" "/run/udev" "Directory")
            (hostPath "plugin-dir" pluginDir "DirectoryOrCreate")
          ];
        };
    };
  };
}
