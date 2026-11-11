# Options of the mayastor package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  release,
}:
let
  tag = "v${release}";

  mayastorImage =
    image: digest: description:
    kix.options.image {
      repository = "docker.io/openebs/mayastor-${image}";
      inherit tag digest description;
      tagText = "config.image.tag";
    };

  argsOption =
    program:
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flags appended to ${program}. Replaces package defaults for the same flag; flags the package derives are refused.";
    };

  envOption =
    program:
    kix.options.env
    // {
      description = "Extra environment variables of ${program}, such as `RUST_LOG`: a string, a `fieldRef` source, or `kix.untrackedRef`. Null removes a variable the package sets by default; variables the package derives are refused.";
    };

  resourcesOption =
    program: requests: limits:
    kix.options.resources {
      inherit requests limits;
      description = "Resources of ${program}.";
    };

  tolerationType = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint key. Null with operator `Exists` tolerates every taint.";
      };
      operator = lib.mkOption {
        type = lib.types.enum [
          "Exists"
          "Equal"
        ];
        default = "Equal";
        description = "`Exists` matches any value of the key; `Equal` matches `value`.";
      };
      value = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Taint value for operator `Equal`.";
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
        description = "For `NoExecute`, how long the pod stays bound after the taint appears.";
      };
    };
  };

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
        description = "Whether deleting a VolumeSnapshot deletes the underlying snapshot.";
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
        description = "Annotations on the VolumeSnapshotClass. `snapshot.storage.kubernetes.io/is-default-class = \"true\"` marks it as the default class for this driver.";
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
          The pool's device: an unpartitioned, unformatted disk used by nothing
          else (preferably a stable `/dev/disk/by-id` path) or a URI such as
          `aio:///path/to/file`. Fixed when the pool is created or imported.
        '';
      };
      encrypted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Encrypt the pool with the key from the `poolEncryptionKey`
          dependency. Encryption and the key are fixed when the pool is
          created; rewiring the dependency does not rotate the key.
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
          `encryptionConfig` are owned by the options above.
        '';
      };
    };
  };
in
{
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
        Cores io-engine polls on: it runs on cores 1 to `cpuCount` (`-l`),
        requests and limits that many CPUs, and `csi-node` opens as many NVMe
        I/O queues per volume.
      '';
    };
    hugepages2Mi = lib.mkOption {
      type = kix.types.quantity;
      default = "2Gi";
      description = "2 MiB hugepages io-engine requests and limits. Each io-engine node must allocate them before the kubelet starts.";
    };
    resources = resourcesOption "io-engine" { memory = "1Gi"; } { memory = "1Gi"; } // {
      description = "Memory of io-engine. Its CPU comes from `ioEngine.cpuCount` and its hugepages from `ioEngine.hugepages2Mi`; setting either here is refused.";
    };
    nodeSelector = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = null;
      defaultText = lib.literalExpression ''{ "openebs.io/engine" = "mayastor"; }'';
      description = "Labels of the nodes that run io-engine and may hold pools. Null selects `openebs.io/engine = mayastor`; `kubernetes.io/arch = amd64` is always added.";
    };
    tolerations = lib.mkOption {
      type = lib.types.listOf tolerationType;
      default = [ ];
      description = "Taints io-engine tolerates.";
    };
    extraArgs = argsOption "io-engine";
    env = envOption "io-engine";
  };

  agentCore = {
    image =
      mayastorImage "agent-core" "sha256:6c4d5a9b445bb7f9cf8596cac07fe7b01903426e730cb5a8c510a27719270897"
        "Image of agent-core.";
    resources =
      resourcesOption "agent-core"
        {
          cpu = "500m";
          memory = "32Mi";
        }
        {
          cpu = "1";
          memory = "128Mi";
        };
    extraArgs = argsOption "agent-core";
    env = envOption "agent-core";
  };

  agentHaCluster = {
    image =
      mayastorImage "agent-ha-cluster"
        "sha256:e00ff76f8fc522ce53cfc22461ec56fec83d0deb148025f19ba03d4cf6d8dcdc"
        "Image of agent-ha-cluster, which runs in the agent-core pod.";
    resources =
      resourcesOption "agent-ha-cluster"
        {
          cpu = "100m";
          memory = "16Mi";
        }
        {
          cpu = "100m";
          memory = "64Mi";
        };
    extraArgs = argsOption "agent-ha-cluster";
    env = envOption "agent-ha-cluster";
  };

  apiRest = {
    image =
      mayastorImage "api-rest" "sha256:2579357ed8127aea15dc8ccefdfbf3de09b154c0c5c0732d1639ef63c0cb654a"
        "Image of api-rest.";
    resources =
      resourcesOption "api-rest"
        {
          cpu = "50m";
          memory = "32Mi";
        }
        {
          cpu = "100m";
          memory = "64Mi";
        };
    extraArgs = argsOption "api-rest";
    env = envOption "api-rest";
  };

  operatorDiskpool = {
    image =
      mayastorImage "operator-diskpool"
        "sha256:19739f0ed7277bfafd6a80724171d23a3dbbc1c5c7afc90897cce0af118ed98f"
        "Image of operator-diskpool.";
    resources =
      resourcesOption "operator-diskpool"
        {
          cpu = "50m";
          memory = "16Mi";
        }
        {
          cpu = "100m";
          memory = "32Mi";
        };
    extraArgs = argsOption "operator-diskpool";
    env = envOption "operator-diskpool";
  };

  csiController = {
    image =
      mayastorImage "csi-controller"
        "sha256:97b21a6229f1bab446ff5a2565696858099292ead9bcfbe2e7194ff609dc3719"
        "Image of the CSI controller plugin.";
    resources =
      resourcesOption "the CSI controller plugin"
        {
          cpu = "16m";
          memory = "64Mi";
        }
        {
          cpu = "32m";
          memory = "128Mi";
        };
    extraArgs = argsOption "the CSI controller plugin";
    env = envOption "the CSI controller plugin";
  };

  csiNode = {
    image =
      mayastorImage "csi-node" "sha256:483219d1bdc645ae63113224b8b6a341add7f03ad0f6194e9ac91527cd039f2b"
        "Image of the CSI node plugin.";
    resources =
      resourcesOption "the CSI node plugin"
        {
          cpu = "100m";
          memory = "64Mi";
        }
        {
          cpu = "100m";
          memory = "128Mi";
        };
    kubeletDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kubelet";
      description = "The kubelet's root directory on the host.";
    };
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Labels of the nodes that run the CSI node plugin and `agent-ha-node`.
        The plugin exits at start on a node without the `nvme_tcp` kernel
        module; `kubernetes.io/arch = amd64` is always added.
      '';
    };
    tolerations = lib.mkOption {
      type = lib.types.listOf tolerationType;
      default = [ ];
      description = "Taints the CSI node plugin and `agent-ha-node` tolerate.";
    };
    extraArgs = argsOption "the CSI node plugin";
    env = envOption "the CSI node plugin";
  };

  agentHaNode = {
    image =
      mayastorImage "agent-ha-node"
        "sha256:547f60e1667fe018415c6dd21c1eae4015c6075272f0a188cdae687759e84c6b"
        "Image of agent-ha-node, placed with the CSI node plugin.";
    resources =
      resourcesOption "agent-ha-node"
        {
          cpu = "100m";
          memory = "64Mi";
        }
        {
          cpu = "100m";
          memory = "64Mi";
        };
    extraArgs = argsOption "agent-ha-node";
    env = envOption "agent-ha-node";
  };

  metricsExporter = {
    image =
      mayastorImage "metrics-exporter-io-engine"
        "sha256:ff563da470cdb8a46d8dac5a0f4fc65bfedd09d835252510084973ffcddc0d1b"
        "Image of the io-engine metrics exporter, which runs in every io-engine pod.";
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
    description = "Image of the csi-snapshotter sidecar, rendered when the `snapshotController` dependency resolves.";
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
    description = "Resources of each CSI sidecar (provisioner, attacher, resizer, snapshotter, and node-driver-registrar).";
  };

  init.image = kix.options.image {
    repository = "docker.io/openebs/alpine-sh";
    tag = "4.6.0";
    digest = "sha256:640c187dccdaa305ce96deba8b57387aeab15e3456deff2efc0470e38f355369";
    description = "Image of the init containers that wait for Services and set etcd volume ownership.";
  };

  etcd = {
    image = kix.options.image {
      repository = "docker.io/openebs/etcd";
      tag = "3.6.4-debian-12-r0";
      digest = "sha256:c86c06f1ce6a08b6df21eb7a9655b1818778b64c85b5cbb8413ebf7534789730";
      description = "Image of etcd.";
    };
    resources =
      resourcesOption "etcd"
        {
          cpu = "250m";
          memory = "256Mi";
        }
        {
          cpu = "375m";
          memory = "384Mi";
        };
    env = envOption "etcd";
    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "2Gi";
        description = ''
          Size of each etcd member's volume. etcd's backend quota is set to 80
          percent of this value.
        '';
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          StorageClass of etcd's volumes. Null takes the `storageClasses`
          dependency's `out.storageClassName`. Must not be one of this
          instance's own classes.
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
    description = "StorageClasses of Mayastor volumes, keyed by class name. `parameters.repl` is required.";
  };

  volumeSnapshotClasses = lib.mkOption {
    type = lib.types.attrsOf snapshotClassType;
    default = { };
    description = "VolumeSnapshotClasses for Mayastor volumes, keyed by class name. Requires the `snapshotController` dependency.";
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
      DiskPools, keyed by pool name. Removing a pool and deploying with
      `--prune` deletes its DiskPool, which destroys the pool on disk once no
      replica remains on it.
    '';
  };

  metrics = kix.options.monitor;
}
