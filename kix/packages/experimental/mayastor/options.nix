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
    digest = "sha256:0161a3e6f902bc3766eb651abe11ed28b826e8bdcd8be063f73e8173462dc561";
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
    resources = resourcesOption "io-engine" { memory = "1Gi"; } { } // {
      description = "Memory requests and limits for io-engine. Kix sets `limits.memory` equal to `requests.memory` (even when `cluster.defaultLimits.memory` is `\"none\"` or `limits.memory` is `null`) so the pod stays in the `Guaranteed` QoS class for exclusive CPU cores. Set `limits.memory` to a quantity to override it. CPU comes from `ioEngine.cpuCount` and hugepages come from `ioEngine.hugepages2Mi`; setting either here fails the build.";
    };
    nodeSelector = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = null;
      defaultText = lib.literalExpression ''{ "openebs.io/engine" = "mayastor"; }'';
      description = "Labels of the nodes that run io-engine and may hold pools. Null selects `openebs.io/engine = mayastor`; `kubernetes.io/arch = amd64` is always added.";
    };
    tolerations = lib.mkOption {
      type = lib.types.listOf kix.types.toleration;
      default = [ ];
      description = "Taints io-engine tolerates.";
    };
    extraArgs = argsOption "io-engine";
    env = envOption "io-engine";
  };

  agentCore = {
    image =
      mayastorImage "agent-core" "sha256:00429e4874788eeb15e1c2e3233046a3cac1dc1745ca8a09bd05e442dc23012d"
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
        "sha256:cb2fa3bfc1f8c7812a6f33dc63240be4ce2c5aadf070cd1e1373e7a08d0dcb1a"
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
      mayastorImage "api-rest" "sha256:0c646268cd8c62777153dc52cf1e767712dc35c185747cc97e8758bc1358e87b"
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
        "sha256:7cd50e41324c58b39154ed401b5495d98c4debda6e234637b1b75b7ae8c4fd57"
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
        "sha256:38a82f29f77770d824887696e68ded236a275957d8dfad28048e984f8f55834d"
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
      mayastorImage "csi-node" "sha256:cbf8343037356c690e79f61c9e6f260e9f796670c2bb00db98b2c1c72b449053"
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
      type = lib.types.listOf kix.types.toleration;
      default = [ ];
      description = "Taints the CSI node plugin and `agent-ha-node` tolerate.";
    };
    extraArgs = argsOption "the CSI node plugin";
    env = envOption "the CSI node plugin";
  };

  agentHaNode = {
    image =
      mayastorImage "agent-ha-node"
        "sha256:964cbb43c5e5bf6ae715b73c555cb921a85b87b0b637134fdd13f3a7b5cc18ab"
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
        "sha256:a57c47d3e624650403fbaab94f5d2859cbe3c94c3106895647d2791eb92e8e71"
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
    type = lib.types.attrsOf kix.types.volumeSnapshotClass;
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
