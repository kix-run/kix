# Options of the zfs-localpv package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  release,
  vscDefaultAnnotation,
}:
let
  absolutePath = lib.types.strMatching "/.*";

  sidecarResources = kix.options.resources {
    requests = {
      cpu = "10m";
      memory = "32Mi";
    };
    limits = {
      cpu = "200m";
      memory = "128Mi";
    };
  };
in
{
  image = kix.options.image {
    repository = "docker.io/openebs/zfs-driver";
    tag = release;
    digest = "sha256:0234692bb4a48b3e70d0bc25f3327ca2b6f1c93d57a066eea755a5c0d94bfb2d";
    description = "Image of the controller and node plugins. Its major.minor must match the vendored CRDs.";
  };

  csiProvisioner = {
    image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-provisioner";
      tag = "v5.2.0";
      digest = "sha256:d5e46da8aff7d73d6f00c761dae94472bcda6e78f4f17b3802dc89d44de0111b";
      description = "Image of csi-provisioner, the controller sidecar that creates volumes and publishes pool capacity.";
    };
    resources = sidecarResources;
  };

  csiResizer = {
    image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-resizer";
      tag = "v1.13.2";
      digest = "sha256:8ddd178ba5d08973f1607f9b84619b58320948de494b31c9d7cd5375b316d6d4";
      description = "Image of csi-resizer, the controller sidecar that expands volumes.";
    };
    resources = sidecarResources;
  };

  csiSnapshotter = {
    image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-snapshotter";
      tag = "v8.2.0";
      digest = "sha256:dd788d79cf4c1b8edee6d9b80b8a1ebfc51a38a365c5be656986b129be9ac784";
      description = "Image of csi-snapshotter, which runs when the `snapshotController` dependency resolves.";
    };
    resources = sidecarResources;
  };

  nodeDriverRegistrar = {
    image = kix.options.image {
      repository = "registry.k8s.io/sig-storage/csi-node-driver-registrar";
      tag = "v2.13.0";
      digest = "sha256:d7138bcc3aa5f267403d45ad4292c95397e421ea17a0035888850f424c7de25d";
      description = "Image of node-driver-registrar, the node sidecar that registers the driver with the kubelet.";
    };
    resources = sidecarResources;
  };

  storageClasses = lib.mkOption {
    type = lib.types.attrsOf (
      kix.types.storageClass {
        provisioner = false;
        parameters = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.str;
          options.poolname = lib.mkOption {
            type = lib.types.str;
            example = "tank/k8s";
            description = "ZFS pool or dataset under which volumes of this class are created. Must exist on every node a volume can land on.";
          };
        };
        defaults = {
          volumeBindingMode = "WaitForFirstConsumer";
          allowVolumeExpansion = true;
        };
      }
    );
    default = { };
    example = lib.literalExpression ''
      {
        zfs = {
          parameters = { poolname = "tank/k8s"; fstype = "zfs"; compression = "lz4"; };
          annotations."storageclass.kubernetes.io/is-default-class" = "true";
        };
      }
    '';
    description = ''
      StorageClasses this driver provisions, keyed by class name. `parameters`
      takes the driver's keys (`poolname`, `fstype`, `recordsize`,
      `compression`, `dedup`, `thinprovision`, `encryption`, and others);
      `poolname` is required. Volumes are node-local, so the default
      `volumeBindingMode` is `WaitForFirstConsumer`.
    '';
  };

  volumeSnapshotClasses = lib.mkOption {
    type = lib.types.attrsOf kix.types.volumeSnapshotClass;
    default = { };
    example = lib.literalExpression ''
      { zfs.annotations."${vscDefaultAnnotation}" = "true"; }
    '';
    description = "VolumeSnapshotClasses for this driver, keyed by class name. Requires a provider of the `snapshotController` role.";
  };

  controller = {
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
      description = "Resources of the controller plugin container.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flags appended to the controller plugin. `--endpoint`, `--plugin`, and `--name` are refused.";
    };
    env = kix.options.env // {
      description = "Extra environment variables of the controller plugin: a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. Defaults `OPENEBS_IO_ENABLE_ANALYTICS` and `OPENEBS_IO_ENABLE_BACKUP_GC` to `\"false\"` (null removes them) and owns `OPENEBS_NAMESPACE`, `OPENEBS_CSI_ENDPOINT`, and `OPENEBS_CONTROLLER_DRIVER`.";
    };
  };

  node = {
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
      description = "Resources of the node plugin container, which runs `zfs` for every volume operation.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--default-format-options=xfs=-i nrext64=0" ];
      description = "Flags appended to the node plugin. `--endpoint`, `--plugin`, `--nodename`, and `--name` are refused.";
    };
    env = kix.options.env // {
      description = "Extra environment variables of the node plugin: a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. Defaults `ALLOWED_TOPOLOGIES` to `kubernetes.io/hostname` plus every key the classes in `storageClasses` select on in `allowedTopologies`; the driver always adds `openebs.io/nodeid` and `openebs.io/nodename`, and volumes pin to `openebs.io/nodeid`. Override with a comma-separated list of node label keys when an external StorageClass selects on other keys, or `\"All\"` to register every node label. Owns `OPENEBS_NAMESPACE`, `OPENEBS_NODE_NAME`, `OPENEBS_CSI_ENDPOINT`, and `OPENEBS_NODE_DRIVER`.";
    };
    kubeletDir = lib.mkOption {
      type = absolutePath;
      default = "/var/lib/kubelet";
      description = "The kubelet's root directory on the host (`zfsNode.kubeletDir` upstream).";
    };
    encrKeysDir = lib.mkOption {
      type = lib.types.nullOr absolutePath;
      default = null;
      example = "/home/keys";
      description = "Host directory mounted at `/home/keys` in the node plugin for datasets encrypted with `keylocation=file:///home/keys/...` (`zfsNode.encrKeysDir` upstream). Null mounts nothing.";
    };
    zfsBin = lib.mkOption {
      type = lib.types.strMatching "(/[A-Za-z0-9._+-]+)+|[A-Za-z0-9_][A-Za-z0-9._+-]*";
      default = "zfs";
      example = "/run/current-system/sw/bin/zfs";
      description = "The `zfs` binary run under `chroot /host` when neither `/sbin/zfs` nor `/usr/sbin/zfs` exists on the host (`zfs.bin` upstream): an absolute path or a command name on the host's PATH.";
    };
    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Node labels the node plugin is limited to, for clusters where only some nodes have a ZFS pool.";
    };
    tolerations = lib.mkOption {
      type = lib.types.listOf kix.types.toleration;
      default = [ ];
      description = "Taints the node plugin tolerates, for tainted storage nodes.";
    };
  };
}
