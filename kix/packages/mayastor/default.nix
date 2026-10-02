# mayastor: OpenEBS Mayastor, replicated block storage served over NVMe-oF
# from DiskPools on labelled nodes.
#
# Renders the control plane (agent-core with agent-ha-cluster, api-rest,
# operator-diskpool, and csi-controller with the CSI sidecars), its etcd
# StatefulSet, the node agents (io-engine on labelled nodes, csi-node and
# agent-ha-node on every node they are placed on), the CSIDriver
# `io.openebs.csi-mayastor`, one ServiceAccount and role set per component,
# and the StorageClasses, VolumeSnapshotClasses, and DiskPools the instance
# declares. Telemetry (call-home), eventing (NATS), the hostpath
# provisioner, and TLS between components are not rendered.
#
#   instances.mayastor = {
#     local-path.package = kix.mkImport { out.storageClassName = "local-path"; };
#     mayastor = {
#       package = packages.mayastor;
#       deps.storageClasses = ref.mayastor.local-path;   # etcd's volumes
#       config = {
#         diskPools.pool-node1 = { node = "node1"; disks = [ "/dev/disk/by-id/nvme-..." ]; };
#         storageClasses.mayastor-3.parameters.repl = "3";
#       };
#     };
#   };
#
# One instance per cluster (`meta.conflictsWith`): the CSIDriver name, the
# kubelet plugin directory, and the cluster-scoped RBAC are fixed.
#
# Host prerequisites Kix cannot check:
# - Every node that runs csi-node loads the `nvme_tcp` kernel module
#   (csi-node exits at start without it) and gives the pod a writable /sys
#   and /run/udev. `csiNode.nodeSelector` limits csi-node and agent-ha-node
#   to those nodes.
# - Every io-engine node (label `openebs.io/engine=mayastor` by default,
#   `ioEngine.nodeSelector`) additionally needs an x86-64 CPU with SSE4.2,
#   kernel 5.13 or newer with ext4 (and xfs if a class asks for it),
#   `ioEngine.cpuCount` dedicated cores, 1 GiB of memory, and
#   `ioEngine.hugepages2Mi` of 2 MiB hugepages allocated before the kubelet
#   starts; host ports 10124, 8420, and 4421 free; `nvme_core.multipath=Y`
#   for volume target failover; and pool disks that are unpartitioned,
#   unformatted, and used by nothing else.
#
# etcd holds Mayastor's volume catalogue. Its claims come from the
# `storageClasses` dependency or `etcd.storage.storageClassName`, and must not
# be one of this instance's own classes: etcd on a Mayastor volume cannot
# start after a full restart. The member count follows the availability
# level (etcd.nix).
#
# io-engine is updated `OnDelete`: restarting it drops every NVMe target on
# the node, so a changed pod template waits until its pods are deleted one
# node at a time, after volume rebuilds finish. `kix deploy` reports such a
# DaemonSet as ready with pods pending a restart.
#
# DI deps:
#   storageClasses (optional)     etcd's StorageClass, read as
#                                 out.storageClassName (see above).
#   snapshotController (optional) the snapshot API; renders the
#                                 csi-snapshotter sidecar and
#                                 `volumeSnapshotClasses`.
#   poolEncryptionKey (optional)  a secret with key `encryption_parameters`,
#                                 the pool key of every pool with
#                                 `encrypted = true`.
#   prometheus (optional)         the io-engine metrics Service,
#                                 ServiceMonitor, and DiskPool alerts.
#
# This package reads `clusterConfig.cluster.nodes` and
# `cluster.capabilities.nodeAutoscaling` to check pool nodes, and the
# instance's own `aliases` and `deps` in `clusterConfig.instances` to refuse
# etcd on its own classes before the `storageClasses` dependency resolves to
# this instance.
#
# out: root is csi-controller. `out.provisioner`, `out.storageClasses`,
# `out.storageClassName` (the shape `storage-classes` gives, so
# `deps.storageClasses = ref.<ns>.<instance>` works for other consumers),
# `out.volumeSnapshotClasses`, `out.diskPools`, and `out.crds.DiskPool`. The
# operator reads DiskPools in this instance's namespace only, so a DiskPool
# built from `out.crds.DiskPool` must live there.
#
# Escape hatches: `<component>.extraArgs` and `<component>.env`,
# `diskPools.<name>.extraSpec`, free-form StorageClass parameters, and the
# instance's `partsOverlays`.

{
  scope,
  lib,
  kix,
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c) release who;

  tag = "v${release}";

  # Every Mayastor image is built from one release; the components follow
  # `image.tag` through `config` below.
  mayastorImage =
    image: digest: description:
    kix.options.image {
      repository = "docker.io/openebs/mayastor-${image}";
      inherit tag digest description;
      tagText = "config.image.tag";
    };

  followers = [
    "agentCore"
    "agentHaCluster"
    "agentHaNode"
    "apiRest"
    "csiController"
    "csiNode"
    "operatorDiskpool"
    "metricsExporter"
  ];

  argsOption =
    program:
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flags appended to ${program}'s. A flag here replaces the package's default for the same flag; flags the package derives are refused.";
    };

  envOption =
    program:
    kix.options.env
    // {
      description = "Extra environment variables of ${program}, such as `RUST_LOG`. A value is a string, a `fieldRef` source, or `kix.untrackedRef`. Null removes a variable the package sets by default; variables the package derives are refused.";
    };

  resourcesOption =
    program: requests: limits:
    kix.options.resources {
      inherit requests limits;
      description = "Resources of ${program}. The defaults are the upstream chart's.";
    };

  tolerationType = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint key. Null with operator Exists tolerates every taint.";
      };
      operator = lib.mkOption {
        type = lib.types.enum [
          "Exists"
          "Equal"
        ];
        default = "Equal";
        description = "Exists matches any value of the key; Equal matches `value`.";
      };
      value = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint value, for operator Equal.";
      };
      effect = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "NoSchedule"
            "PreferNoSchedule"
            "NoExecute"
          ]
        );
        default = null;
        description = "Taint effect to tolerate. Null tolerates every effect.";
      };
      tolerationSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "For NoExecute: how long the pod stays bound after the taint appears.";
      };
    };
  };

  # Parameters of a Mayastor StorageClass. `repl` has no default: 1 keeps
  # one copy of the data and 3 needs pools on three nodes. The CSI driver
  # reads every other parameter (thin, fsType, ioTimeout, local, encrypted,
  # topology keys) as a string.
  mayastorParams = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.str;
    options = {
      repl = lib.mkOption {
        type = lib.types.strMatching "[1-9][0-9]*";
        example = "3";
        description = "Number of replicas of each volume, each on a pool on a different node.";
      };
      protocol = lib.mkOption {
        type = lib.types.enum [ "nvmf" ];
        default = "nvmf";
        description = "Transport between the volume target and the node that mounts the volume.";
      };
    };
  };

  snapshotClassType = lib.types.submodule {
    options = {
      deletionPolicy = lib.mkOption {
        type = lib.types.enum [
          "Delete"
          "Retain"
        ];
        default = "Delete";
        description = "Whether deleting a VolumeSnapshot deletes the snapshot it holds.";
      };
      parameters = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Driver parameters of the class. Omitted from the manifest when empty.";
      };
      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Labels on the VolumeSnapshotClass.";
      };
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Annotations on the VolumeSnapshotClass. `snapshot.storage.kubernetes.io/is-default-class = \"true\"` makes it the default class for this driver.";
      };
    };
  };

  poolType = lib.types.submodule {
    options = {
      node = lib.mkOption {
        type = lib.types.str;
        description = "Kubernetes name of the io-engine node that holds the pool.";
      };
      disks = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        example = [ "/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S64ANS0T000000" ];
        description = ''
          The pool's device: an unpartitioned, unformatted disk used by
          nothing else, preferably as a stable /dev/disk/by-id path, or a
          URI such as `aio:///path/to/file`. Mayastor reads it when it
          creates or imports the pool, so do not change it on a live pool.
        '';
      };
      encrypted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Encrypt the pool with the key from the `poolEncryptionKey`
          dependency, the one key of every encrypted pool of this instance.
          Mayastor fixes encryption and the key when it creates the pool,
          and reads the key again whenever it imports the pool, so rewiring
          the dependency does not rotate it. A pool that needs a key of its
          own is built from `out.crds.DiskPool` in a package of your own.
        '';
      };
      extraSpec = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = {
          topology.labelled.zone = "a";
        };
        description = ''
          Fields merged into the DiskPool's spec, such as `topology`,
          `clusterSize`, or `maxExpansion`. `node`, `disks`, and
          `encryptionConfig` come from the options above. Mayastor fixes
          the cluster size when it creates the pool.
        '';
      };
    };
  };
in
{
  meta = {
    version = release;
    description = "OpenEBS Mayastor: replicated NVMe-oF block storage from DiskPools on labelled nodes";
    owner = "platform";
    # etcd holds the volume catalogue and the DiskPools hold the data.
    lifecycle = "stateful";
    defaultAliases = [ "mayastor" ];
    # The CSIDriver name, the kubelet plugin directory, and the
    # cluster-scoped RBAC are fixed. An instance that sets its own `aliases`
    # keeps this check only if it lists `mayastor`.
    conflictsWith = [ "cluster:mayastor" ];
    # io-engine runs SPDK with raw device access and hugepages, csi-node runs
    # `nvme connect` and mounts with Bidirectional propagation, and
    # agent-ha-node replaces NVMe paths, so all three are privileged. They
    # and csi-controller use the host network as upstream runs them, the
    # Mayastor images run as root, and the etcd init container chowns the
    # data volume as root.
    unsafe = [
      "privileged"
      "host-network"
      "run-as-root"
    ];
    podSecurity = "privileged";
    k8s.minVersion = "1.23";
    # Pod policy does not see the host-network pods (io-engine, csi-node,
    # agent-ha-node, csi-controller) as the workloads they are, so the edges
    # derived from their addresses admit nothing; Cilium sees their traffic
    # as from the host or a remote node. Ingress: etcd 2379 (io-engine),
    # api-rest 8081 (csi-controller, csi-node, the metrics exporter),
    # agent-core 50051 (io-engine), and agent-ha-cluster 50052
    # (agent-ha-node). Egress, from agent-core to the node agents: io-engine
    # 10124, csi-node 10199, and agent-ha-node 50053. `all-pods` also lets
    # every pod reach etcd, which runs without authentication; upstream's
    # chart policy is no narrower. NVMe-oF (8420, 4421) runs between hosts.
    network.intents.hostNetworkPeers =
      let
        tcp = map (port: {
          inherit port;
          protocol = "TCP";
        });
      in
      {
        ingress = [
          {
            from = "all-pods";
            ports = tcp [
              2379
              8081
              50051
              50052
            ];
          }
        ];
        egress = [
          {
            to = "all-pods";
            ports = tcp [
              10124
              10199
              50053
            ];
          }
        ];
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/openebs/mayastor-io-engine";
      inherit tag;
      digest = "sha256:bbe5e87b69afe8e5711e1259ad91bdac7fea6f79486c8d0b318f33adcf60fece";
      description = "Image of io-engine. Every Mayastor component image follows its tag, and its major.minor must be ${lib.versions.majorMinor release}.";
    };

    ioEngine = {
      cpuCount = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = ''
          Cores io-engine polls on: it runs on cores 1 to cpuCount (`-l`),
          requests and limits that many CPUs, and csi-node opens as many
          NVMe I/O queues per volume. A node's `config.yaml` `eal_opts.core_list`
          in the io-engine host directory overrides the cores, while the CPU
          request still follows this value.
        '';
      };
      hugepages2Mi = lib.mkOption {
        type = kix.types.quantity;
        default = "2Gi";
        description = "2 MiB hugepages io-engine requests and limits. Each io-engine node must have them allocated before the kubelet starts.";
      };
      resources = resourcesOption "io-engine" { memory = "1Gi"; } { memory = "1Gi"; } // {
        description = "Memory of io-engine. Its CPU comes from `ioEngine.cpuCount` and its hugepages from `ioEngine.hugepages2Mi`; setting either here is refused.";
      };
      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "openebs.io/engine" = "mayastor";
        };
        description = "Labels of the nodes that run io-engine and so may hold pools. `kubernetes.io/arch = amd64` is always added.";
      };
      tolerations = lib.mkOption {
        type = lib.types.listOf tolerationType;
        default = [ ];
        description = "Taints io-engine tolerates, for storage nodes that keep other pods away.";
      };
      extraArgs = argsOption "io-engine";
      env = envOption "io-engine";
    };

    agentCore = {
      image = mayastorImage "agent-core" "sha256:6c4d5a9b445bb7f9cf8596cac07fe7b01903426e730cb5a8c510a27719270897" "Image of agent-core.";
      resources = resourcesOption "agent-core" {
        cpu = "500m";
        memory = "32Mi";
      } {
        cpu = "1";
        memory = "128Mi";
      };
      extraArgs = argsOption "agent-core";
      env = envOption "agent-core";
    };

    agentHaCluster = {
      image = mayastorImage "agent-ha-cluster" "sha256:e00ff76f8fc522ce53cfc22461ec56fec83d0deb148025f19ba03d4cf6d8dcdc" "Image of agent-ha-cluster, which runs in the agent-core pod.";
      resources = resourcesOption "agent-ha-cluster" {
        cpu = "100m";
        memory = "16Mi";
      } {
        cpu = "100m";
        memory = "64Mi";
      };
      extraArgs = argsOption "agent-ha-cluster";
      env = envOption "agent-ha-cluster";
    };

    apiRest = {
      image = mayastorImage "api-rest" "sha256:2579357ed8127aea15dc8ccefdfbf3de09b154c0c5c0732d1639ef63c0cb654a" "Image of api-rest.";
      resources = resourcesOption "api-rest" {
        cpu = "50m";
        memory = "32Mi";
      } {
        cpu = "100m";
        memory = "64Mi";
      };
      extraArgs = argsOption "api-rest";
      env = envOption "api-rest";
    };

    operatorDiskpool = {
      image = mayastorImage "operator-diskpool" "sha256:19739f0ed7277bfafd6a80724171d23a3dbbc1c5c7afc90897cce0af118ed98f" "Image of operator-diskpool.";
      resources = resourcesOption "operator-diskpool" {
        cpu = "50m";
        memory = "16Mi";
      } {
        cpu = "100m";
        memory = "32Mi";
      };
      extraArgs = argsOption "operator-diskpool";
      env = envOption "operator-diskpool";
    };

    csiController = {
      image = mayastorImage "csi-controller" "sha256:97b21a6229f1bab446ff5a2565696858099292ead9bcfbe2e7194ff609dc3719" "Image of the CSI controller plugin.";
      resources = resourcesOption "the CSI controller plugin" {
        cpu = "16m";
        memory = "64Mi";
      } {
        cpu = "32m";
        memory = "128Mi";
      };
      extraArgs = argsOption "the CSI controller plugin";
      env = envOption "the CSI controller plugin";
    };

    csiNode = {
      image = mayastorImage "csi-node" "sha256:483219d1bdc645ae63113224b8b6a341add7f03ad0f6194e9ac91527cd039f2b" "Image of the CSI node plugin.";
      resources = resourcesOption "the CSI node plugin" {
        cpu = "100m";
        memory = "64Mi";
      } {
        cpu = "100m";
        memory = "128Mi";
      };
      kubeletDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/kubelet";
        description = "The kubelet's root directory on the host. The CSI node plugin mounts volumes under it and registers its socket in its plugins directories.";
      };
      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Labels of the nodes that run the CSI node plugin and
          agent-ha-node, which are the nodes that may mount a Mayastor
          volume. The plugin exits at start on a node without the
          `nvme_tcp` kernel module, so set this to the nodes that load it
          when not every node does. `kubernetes.io/arch = amd64` is always
          added.
        '';
      };
      tolerations = lib.mkOption {
        type = lib.types.listOf tolerationType;
        default = [ ];
        description = "Taints the CSI node plugin and agent-ha-node tolerate.";
      };
      extraArgs = argsOption "the CSI node plugin";
      env = envOption "the CSI node plugin";
    };

    agentHaNode = {
      image = mayastorImage "agent-ha-node" "sha256:547f60e1667fe018415c6dd21c1eae4015c6075272f0a188cdae687759e84c6b" "Image of agent-ha-node, placed with the CSI node plugin.";
      resources = resourcesOption "agent-ha-node" {
        cpu = "100m";
        memory = "64Mi";
      } {
        cpu = "100m";
        memory = "64Mi";
      };
      extraArgs = argsOption "agent-ha-node";
      env = envOption "agent-ha-node";
    };

    metricsExporter = {
      image = mayastorImage "metrics-exporter-io-engine" "sha256:ff563da470cdb8a46d8dac5a0f4fc65bfedd09d835252510084973ffcddc0d1b" "Image of the io-engine metrics exporter, which runs in every io-engine pod.";
      # The upstream chart sets none.
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "100m";
          memory = "128Mi";
        };
        description = "Resources of the io-engine metrics exporter.";
      };
      extraArgs = argsOption "the io-engine metrics exporter";
      env = envOption "the io-engine metrics exporter";
    };

    csiProvisioner.image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-provisioner";
      tag = "v5.2.0";
      digest = "sha256:d5e46da8aff7d73d6f00c761dae94472bcda6e78f4f17b3802dc89d44de0111b";
      description = "Image of the csi-provisioner sidecar.";
    };
    csiAttacher.image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-attacher";
      tag = "v4.8.1";
      digest = "sha256:69888dba58159c8bc0d7c092b9fb97900c9ca8710d088b0b7ea7bd9052df86f6";
      description = "Image of the csi-attacher sidecar.";
    };
    csiResizer.image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-resizer";
      tag = "v1.13.2";
      digest = "sha256:8ddd178ba5d08973f1607f9b84619b58320948de494b31c9d7cd5375b316d6d4";
      description = "Image of the csi-resizer sidecar.";
    };
    csiSnapshotter.image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-snapshotter";
      tag = "v8.2.0";
      digest = "sha256:dd788d79cf4c1b8edee6d9b80b8a1ebfc51a38a365c5be656986b129be9ac784";
      description = "Image of the csi-snapshotter sidecar, rendered when the snapshotController dependency resolves.";
    };
    nodeDriverRegistrar.image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-node-driver-registrar";
      tag = "v2.13.0";
      digest = "sha256:d7138bcc3aa5f267403d45ad4292c95397e421ea17a0035888850f424c7de25d";
      description = "Image of the node-driver-registrar sidecar.";
    };
    csiSidecars.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
      description = "Resources of each CSI sidecar (provisioner, attacher, resizer, snapshotter, node-driver-registrar).";
    };

    init.image = kix.options.image {
      repository = "docker.io/openebs/alpine-sh";
      tag = "4.6.0";
      digest = "sha256:640c187dccdaa305ce96deba8b57387aeab15e3456deff2efc0470e38f355369";
      description = "Image of the init containers that wait for a Service and that set the owner of etcd's data volume.";
    };

    etcd = {
      image = kix.options.image {
        repository = "docker.io/openebs/etcd";
        tag = "3.6.4-debian-12-r0";
        digest = "sha256:c86c06f1ce6a08b6df21eb7a9655b1818778b64c85b5cbb8413ebf7534789730";
        description = "Image of etcd. The package configures it through the Bitnami etcd image's variables.";
      };
      resources = resourcesOption "etcd" {
        cpu = "250m";
        memory = "256Mi";
      } {
        cpu = "375m";
        memory = "384Mi";
      };
      env = envOption "etcd";
      storage = {
        size = lib.mkOption {
          type = kix.types.quantity;
          default = "2Gi";
          description = ''
            Size of each etcd member's volume. etcd's backend quota is set to
            80 percent of it. The member count follows the availability
            level (one at `none`, three above), and changing the level of a
            live instance is an etcd membership change: add or remove the
            member with etcdctl first, or restore a snapshot into a fresh
            cluster.
          '';
        };
        storageClassName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            StorageClass of etcd's volumes. Null takes the `storageClasses`
            dependency's `out.storageClassName`. Set it to name a class Kix
            does not provide. It must not be one of this instance's classes.
            An instance whose `aliases` include `storageClasses` wires
            `deps.storageClasses` instead, for example to
            `kix.mkImport { out.storageClassName = "local-path"; }`.
          '';
        };
      };
    };

    storageClasses = lib.mkOption {
      type = lib.types.attrsOf (
        kix.types.storageClass {
          provisioner = false;
          parameters = mayastorParams;
          defaults.allowVolumeExpansion = true;
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          mayastor-3 = {
            parameters = { repl = "3"; thin = "true"; };
            annotations."storageclass.kubernetes.io/is-default-class" = "true";
          };
        }
      '';
      description = "StorageClasses of Mayastor volumes, keyed by class name. `parameters.repl` is required. A class with `parameters.encrypted = \"true\"` places replicas on encrypted pools only.";
    };

    volumeSnapshotClasses = lib.mkOption {
      type = lib.types.attrsOf snapshotClassType;
      default = { };
      description = "VolumeSnapshotClasses for Mayastor volumes, keyed by class name. They need the snapshotController dependency.";
    };

    diskPools = lib.mkOption {
      type = lib.types.attrsOf poolType;
      default = { };
      example = lib.literalExpression ''
        {
          pool-node1 = { node = "node1"; disks = [ "/dev/disk/by-id/nvme-..." ]; };
        }
      '';
      description = ''
        DiskPools, keyed by pool name. Removing a pool here deletes its
        DiskPool, and the operator then destroys the pool on disk once no
        replica lives on it (the control plane refuses while replicas
        remain).
      '';
    };

    metrics = kix.options.monitor;
  };

  config =
    { config, ... }:
    lib.genAttrs followers (_: {
      image.tag = lib.mkDefault config.image.tag;
    });

  assertions =
    { config, ... }:
    let
      res = config.ioEngine.resources;
      setByPackage =
        side: builtins.filter (k: k == "cpu" || lib.hasPrefix "hugepages-" k) (
          builtins.attrNames (lib.filterAttrs (_: v: v != null) res.${side})
        );
      owned = lib.unique (setByPackage "requests" ++ setByPackage "limits");

      # Pools that name the same device string on one node.
      claims = lib.concatLists (
        lib.mapAttrsToList (
          pool: p:
          map (disk: {
            inherit pool disk;
            inherit (p) node;
          }) p.disks
        ) config.diskPools
      );
      byDevice = lib.groupBy (cl: "${cl.node} ${cl.disk}") claims;
      shared = lib.filterAttrs (_: cls: builtins.length (lib.unique (map (cl: cl.pool) cls)) > 1) byDevice;
      sharedText = lib.concatStringsSep "; " (
        lib.mapAttrsToList (
          _: cls:
          "${(builtins.head cls).disk} on node ${(builtins.head cls).node} (pools ${
            lib.concatStringsSep ", " (lib.unique (map (cl: cl.pool) cls))
          })"
        ) shared
      );

      reservedPools = builtins.filter (n: n == "root" || n == "meta") (builtins.attrNames config.diskPools);

      defaultSnapshotClasses = builtins.attrNames (
        lib.filterAttrs (
          _: v: (v.annotations."snapshot.storage.kubernetes.io/is-default-class" or null) == "true"
        ) config.volumeSnapshotClasses
      );
    in
    [
      {
        assertion = owned == [ ];
        message = "ioEngine.resources sets ${lib.concatStringsSep ", " owned}, which the package sets: CPU from ioEngine.cpuCount and 2 MiB hugepages from ioEngine.hugepages2Mi. Set those options instead.";
      }
      {
        assertion = shared == { };
        message = "diskPools name the same disk more than once: ${sharedText}. A disk belongs to one pool; Mayastor refuses the second as claimed. The comparison is by text, so two paths to one disk (a by-id link and its /dev name) are not detected.";
      }
      {
        assertion = reservedPools == [ ];
        message = "diskPools.${builtins.head reservedPools}: Kix drops parts named root or meta, so this DiskPool would not be rendered. Rename it.";
      }
      {
        assertion = builtins.length defaultSnapshotClasses <= 1;
        message = "volumeSnapshotClasses ${lib.concatStringsSep " and " defaultSnapshotClasses} are each annotated snapshot.storage.kubernetes.io/is-default-class=\"true\". A VolumeSnapshot that names no class then fails, because the snapshot controller refuses to choose between two defaults for one driver. Keep the annotation on one class.";
      }
    ];

  # Cross-checks of classes against the pools this instance declares. Pools
  # created elsewhere also count at runtime, so these are warnings.
  warnings =
    { config, ... }:
    let
      pools = builtins.attrValues config.diskPools;
      poolNodes = lib.unique (map (p: p.node) pools);
      encryptedPools = builtins.filter (p: p.encrypted) pools;
    in
    lib.optionals (pools != [ ]) (
      lib.concatLists (
        lib.mapAttrsToList (
          cls: def:
          lib.optional (lib.toInt def.parameters.repl > builtins.length poolNodes) "storageClasses.${cls} asks for ${def.parameters.repl} replicas, but diskPools has pools on ${toString (builtins.length poolNodes)} node(s); each replica needs a pool on a different node, so its volumes cannot be created. This counts only pools this instance declares."
          ++ lib.optional (
            (def.parameters.encrypted or "false") == "true" && encryptedPools == [ ]
          ) "storageClasses.${cls} sets encrypted = \"true\", but no pool in diskPools is encrypted, so its volumes cannot be placed. This counts only pools this instance declares."
        ) config.storageClasses
      )
    );

  build = [
    ./rbac.nix
    ./etcd.nix
    ./control-plane.nix
    ./node.nix

    (
      {
        self,
        config,
        clusterConfig,
        scope,
        lib,
        kix,
        snapshotController ? null,
        poolEncryptionKey ? null,
        ...
      }:
      let
        sc = kix.storage.mkClasses {
          inherit scope clusterConfig who;
          optionPath = "config.storageClasses";
          classes = config.storageClasses;
          parts = self.classes;
          provisioner = self.csiDriver.out.name;
          requires = [
            self.csiController
            self.csiNode
          ];
        };

        key = kix.checkSecretKeys {
          inherit who;
          arg = "poolEncryptionKey";
          dep = poolEncryptionKey;
          keys = [ "encryption_parameters" ];
        };

        # Pool nodes are checked against `cluster.nodes` when the cluster
        # lists its nodes and does not autoscale them. Node labels may be set
        # outside the cluster definition, so a missing label is a warning.
        nodes = clusterConfig.cluster.nodes;
        checkNodes = nodes != { } && clusterConfig.cluster.capabilities.nodeAutoscaling != true;
        ioEngineLabels = config.ioEngine.nodeSelector;
        checkPool =
          poolName: pool:
          if !checkNodes then
            pool
          else if !(nodes ? ${pool.node}) then
            throw "${who}: diskPools.${poolName}.node is \"${pool.node}\", which is not in cluster.nodes (${lib.concatStringsSep ", " (builtins.attrNames nodes)}). Name the node that holds the pool's disk."
          else
            let
              missing = lib.filterAttrs (k: v: (nodes.${pool.node}.labels.${k} or null) != v) ioEngineLabels;
            in
            lib.warnIf (missing != { })
              "${who}: diskPools.${poolName} is on node ${pool.node}, whose labels in cluster.nodes lack ${
                lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k}=${v}") missing)
              } from ioEngine.nodeSelector, so io-engine may not run there and the pool would not come up. Label the node, or ignore this if it is labelled outside the cluster definition."
              pool;
      in
      {
        # The upstream chart ships no CSIDriver object.
        csiDriver = scope.mkClusterResource {
          apiVersion = "storage.k8s.io/v1";
          kind = "CSIDriver";
          name = "io.openebs.csi-mayastor";
          spec = {
            attachRequired = true;
            podInfoOnMount = true;
            volumeLifecycleModes = [ "Persistent" ];
            # csi-provisioner runs without --enable-capacity, so nothing
            # publishes CSIStorageCapacity objects for the scheduler to wait on.
            storageCapacity = false;
          };
        };

        classes = sc.resources;

        snapshotClasses =
          if config.volumeSnapshotClasses == { } then
            { }
          else if snapshotController == null then
            throw "${who}: volumeSnapshotClasses defines ${lib.concatStringsSep ", " (builtins.attrNames config.volumeSnapshotClasses)}, but nothing provides the snapshotController role, so the VolumeSnapshotClass kind has no owner. Add a snapshot-controller instance, or on a cluster whose environment runs the controller use a flavour or an import that provides the role, or remove volumeSnapshotClasses."
          else
            lib.mapAttrs (
              className: cls:
              scope.mkCR snapshotController.out.crds.VolumeSnapshotClass {
                name = className;
                inherit (cls) labels annotations;
                extra = {
                  driver = self.csiDriver.out.name;
                  inherit (cls) deletionPolicy;
                }
                // lib.optionalAttrs (cls.parameters != { }) { inherit (cls) parameters; };
                requires = [ self.csiController ];
              }
            ) config.volumeSnapshotClasses;

        # The operator installs the DiskPool CRD and migrates older versions
        # at start. PoolReady is True while the pool is Online or Degraded,
        # the states upstream treats as usable; `status.pool_status` is the
        # raw control-plane state.
        diskPoolCrd = scope.mkCRDRef {
          group = "openebs.io";
          kind = "DiskPool";
          plural = "diskpools";
          version = "v1beta3";
          installedBy = self.operatorDiskpool;
          readiness.condition = {
            type = "PoolReady";
            status = "True";
          };
        };

        pools = lib.mapAttrs (
          poolName: pool':
          let
            pool = checkPool poolName pool';
          in
          scope.mkCR self.diskPoolCrd {
            name = poolName;
            spec =
              kix.mergeGuarded
                {
                  inherit who;
                  what = "diskPools.${poolName}.extraSpec";
                  locked = [
                    [ "node" ]
                    [ "disks" ]
                    [ "encryptionConfig" ]
                  ];
                }
                (
                  {
                    inherit (pool) node disks;
                  }
                  // lib.optionalAttrs pool.encrypted {
                    encryptionConfig.source.secret.name =
                      if key == null then
                        throw "${who}: diskPools.${poolName}.encrypted is true, but the poolEncryptionKey dependency is not wired. Wire a secret with key encryption_parameters through deps.poolEncryptionKey = ref.<ns>.<instance>, or set encrypted = false."
                      else
                        key.out.name;
                  }
                )
                pool.extraSpec;
            requires = [ self.ioEngine ];
          }
        ) config.diskPools;

        root = {
          resource = self.csiController;
          requires = [
            self.csiNode
            self.ioEngine
            self.agentHaNode
            self.agentCore
            self.apiRest
            self.operatorDiskpool
            self.etcd
          ]
          ++ builtins.attrValues self.classes
          ++ builtins.attrValues self.snapshotClasses
          ++ builtins.attrValues self.pools
          # The monitoring parts reference no other part, so the
          # PackageInstance reaches them only through this list.
          ++ builtins.filter (r: r != null) [
            self.serviceMonitor
            self.prometheusRules
          ];
          out = {
            provisioner = self.csiDriver.out.name;
            inherit (sc) storageClassName;
            storageClasses = self.classes;
            volumeSnapshotClasses = self.snapshotClasses;
            diskPools = self.pools;
            crds.DiskPool = self.diskPoolCrd;
          };
        };
      }
    )

    # The exporter container always runs in the io-engine pod, so wiring
    # monitoring later does not change io-engine's OnDelete pod template.
    # Its Service, ServiceMonitor, and alerts exist only with monitoring on.
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
        enabled = config.metrics.enabled && prometheus != null;
        sel = ''namespace="${c.ns}",service="${self.ioEngineMetrics.out.name}"'';
      in
      {
        ioEngineMetrics =
          if enabled then
            self.ioEngine
            |> kix.service.fromWorkload {
              name = "${c.name}-io-engine-metrics";
              labels = c.componentLabels "io-engine-metrics";
              ports = [
                {
                  name = "metrics";
                  port = 9502;
                  targetPort = "metrics";
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;
      }
      // kix.monitor {
        service = "ioEngineMetrics";
        port = "metrics";
        # Package defaults for capacity and health warnings on every pool
        # of this instance.
        alerts = {
          MayastorDiskPoolNotOnline = {
            # diskpool_status: 0 unknown, 1 online, 2 degraded, 3 faulted,
            # 4 suspected.
            expr = "diskpool_status{${sel}} == 0 or diskpool_status{${sel}} == 3";
            "for" = "5m";
            severity = "critical";
            summary = "A Mayastor DiskPool is faulted or its state is unknown";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} has been faulted or unknown for 5 minutes. Check kubectl -n ${c.ns} get diskpool {{ $labels.name }} and the io-engine pod on that node.";
          };
          MayastorDiskPoolUsageHigh = {
            expr = "diskpool_used_size_bytes{${sel}} / diskpool_total_size_bytes{${sel}} > 0.75";
            "for" = "15m";
            severity = "warning";
            summary = "A Mayastor DiskPool is more than 75% full";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} is {{ $value | humanizePercentage }} full.";
          };
          MayastorDiskPoolUsageCritical = {
            expr = "diskpool_used_size_bytes{${sel}} / diskpool_total_size_bytes{${sel}} > 0.90";
            "for" = "5m";
            severity = "critical";
            summary = "A Mayastor DiskPool is more than 90% full";
            description = "DiskPool {{ $labels.name }} on node {{ $labels.node }} of Mayastor in ${c.ns} is {{ $value | humanizePercentage }} full. Add a pool or free space before writes fail.";
          };
        };
      } args
    )
  ];
}
