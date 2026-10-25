# zfs-localpv: the OpenEBS LocalPV-ZFS CSI driver, which provisions
# PersistentVolumes as ZFS datasets or zvols on a ZFS pool that already
# exists on each node. root = the controller Deployment.
#
# Installs the five zfs.openebs.io CRDs; CSIDriver zfs.csi.openebs.io;
# ServiceAccounts <name>-controller and <name>-node with their ClusterRoles
# and bindings (<name>-<namespace>-controller, <name>-<namespace>-node); a
# Role and RoleBinding <name>-controller for the sidecars' Leases and the
# CSIStorageCapacity objects; ConfigMap <name>-zfs with the wrapper that
# runs the host's zfs binary; Deployment <name>-controller (csi-provisioner,
# csi-resizer, csi-snapshotter, and the controller plugin); DaemonSet
# <name>-node (node-driver-registrar and the node plugin); and the
# StorageClasses and VolumeSnapshotClasses in `storageClasses` and
# `volumeSnapshotClasses`.
#
#   instances.storage.zfs-localpv = {
#     package = packages.zfs-localpv;
#     config.storageClasses.zfs.parameters.poolname = "tank/k8s";
#   };
#
# Precondition: every node the node plugin runs on has the pool. The plugin
# runs `zfs` on the host through `chroot /host`; set `node.zfsBin` where the
# binary is neither /sbin/zfs nor /usr/sbin/zfs (NixOS:
# /run/current-system/sw/bin/zfs), and `node.nodeSelector` when only some
# nodes have a pool.
#
# The driver keeps one ZFSVolume, ZFSSnapshot, and ZFSNode record per object
# in the instance's namespace (OPENEBS_NAMESPACE). Moving the instance to
# another namespace leaves the existing volumes' records behind, and the
# driver no longer manages those volumes.
#
# A cluster runs one instance: the zfs.openebs.io CRDs are cluster-scoped,
# and the package pins the driver name zfs.csi.openebs.io by refusing
# `--name`.
#
# Snapshots: the optional `snapshotController` dependency provides the
# VolumeSnapshot API (a `snapshot-controller` instance, or the environment
# through a platform import). When it resolves, the controller runs
# csi-snapshotter and `volumeSnapshotClasses` render; without it,
# `volumeSnapshotClasses` must be empty.
#
# This package does not claim the `storageClasses` role. A consumer names
# the instance, `deps.storageClasses = ref.<namespace>.<instance>`, and gets
# out.storageClassName. An instance with
# `aliases = [ "storageClasses" "zfsLocalPv" ]` serves every consumer that
# names no provider; `zfsLocalPv` keeps the one-instance check, which
# matches on that alias.
#
# out.storageClassName: the class annotated
# storageclass.kubernetes.io/is-default-class, else the only class; reading
# it throws otherwise.
#
# Escape hatches: `controller.extraArgs`, `controller.env`, `node.extraArgs`,
# `node.env`, and `partsOverlays`.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  # meta.version and image.tag read this; crds/sources.txt names the same tag.
  release = "2.11.1";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "zfs-localpv ${ns}/${name}";

  # The driver registers under this name; it is also the CSIDriver's name
  # and every class's provisioner.
  driverName = "zfs.csi.openebs.io";

  socketDir = "/var/lib/csi/sockets/pluginproxy";
  vscDefaultAnnotation = "snapshot.storage.kubernetes.io/is-default-class";

  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;

  # The CRDs come from `release`; a driver of another minor release may not
  # serve the same schema.
  minorOf = tag: builtins.match "v?([0-9]+)\\.([0-9]+)\\..*" tag;
  releaseMinor = minorOf release;
  checkedRef =
    image:
    if minorOf image.tag != releaseMinor then
      throw (
        "${who}: image.tag \"${image.tag}\" is not a ${lib.concatStringsSep "." releaseMinor} release, "
        + "and the CRDs under kix/packages/zfs-localpv/crds are vendored from ${release}. To move to "
        + "another release, change release in kix/packages/zfs-localpv/default.nix and run "
        + "uv run scripts/vendor-crds.py zfs-localpv."
      )
    else
      kix.image.ref image;

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

  defaultVscs =
    classes:
    builtins.filter (n: (classes.${n}.annotations.${vscDefaultAnnotation} or null) == "true") (
      builtins.attrNames classes
    );

  toleration = lib.types.submodule {
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
        description = "Exists matches any value; Equal matches `value`.";
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
        description = "For effect NoExecute, how long the pod stays bound after the taint appears. Null keeps it bound.";
      };
    };
  };
in
{
  meta = {
    version = release;
    description = "OpenEBS LocalPV-ZFS CSI driver: PersistentVolumes as ZFS datasets or zvols on each node's existing pool";
    owner = "platform";
    # The node plugin runs zfs on the host through `chroot /host` and mounts
    # volumes into the kubelet's pod directory with Bidirectional
    # propagation.
    unsafe = [
      "privileged"
      "run-as-root"
    ];
    podSecurity = "privileged";
    defaultAliases = [ "zfsLocalPv" ];
    # The CRDs are cluster-scoped and the package pins the driver name, so a
    # cluster runs one instance. An instance that sets its own `aliases`
    # keeps this check only if it lists zfsLocalPv.
    conflictsWith = [ "cluster:zfsLocalPv" ];
    # csi-provisioner's --enable-capacity writes storage.k8s.io/v1
    # CSIStorageCapacity objects, which Kubernetes serves from 1.24.
    k8s.minVersion = "1.24";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/openebs/zfs-driver";
      tag = release;
      digest = "sha256:16f1a74bb2495c78f9652be5d7cd6e869cb212c9decd42cac63e6566b07fa5f2";
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
        description = "Image of csi-snapshotter, which runs while the snapshotController dependency resolves.";
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
              description = "ZFS pool, or dataset inside a pool, that volumes of this class are created under. It must exist on every node a volume can land on.";
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
        StorageClasses this driver provisions, keyed by class name. Each
        class's provisioner is the driver. `parameters` takes the driver's
        keys (`poolname`, `fstype`, `recordsize`, `compression`, `dedup`,
        `thinprovision`, `encryption`, ...); `poolname` is required.
        Volumes are node-local, so the default `volumeBindingMode` is
        `WaitForFirstConsumer`.
      '';
    };

    volumeSnapshotClasses = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            deletionPolicy = lib.mkOption {
              type = lib.types.enum [
                "Delete"
                "Retain"
              ];
              default = "Delete";
              description = "What happens to the ZFS snapshot when its VolumeSnapshot is deleted.";
            };
            parameters = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Driver-specific snapshot parameters. Omitted from the manifest when empty.";
            };
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Labels on the VolumeSnapshotClass.";
            };
            annotations = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Annotations on the VolumeSnapshotClass. `\"${vscDefaultAnnotation}\" = \"true\"` makes it the class a VolumeSnapshot of this driver's volumes gets when it names none.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        { zfs.annotations."${vscDefaultAnnotation}" = "true"; }
      '';
      description = "VolumeSnapshotClasses for this driver, keyed by class name. Needs a provider of the snapshotController role.";
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
        description = "Flags appended to the controller plugin's. `--endpoint`, `--plugin`, and `--name` are refused.";
      };
      env = kix.options.env // {
        description = "Extra environment variables of the controller plugin. A value is a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. The package sets OPENEBS_IO_ENABLE_ANALYTICS and OPENEBS_IO_ENABLE_BACKUP_GC to \"false\" (null removes them) and owns OPENEBS_NAMESPACE, OPENEBS_CSI_ENDPOINT, and OPENEBS_CONTROLLER_DRIVER.";
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
        description = "Resources of the node plugin container, which runs zfs for every volume operation.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--default-format-options=xfs=-i nrext64=0" ];
        description = "Flags appended to the node plugin's. `--endpoint`, `--plugin`, `--nodename`, and `--name` are refused.";
      };
      env = kix.options.env // {
        description = "Extra environment variables of the node plugin. A value is a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. The package sets ALLOWED_TOPOLOGIES to kubernetes.io/hostname plus every key the classes in `storageClasses` select on in allowedTopologies; the driver always adds openebs.io/nodeid and openebs.io/nodename, and volumes pin to openebs.io/nodeid. Set it to a comma-separated list of node label keys when a StorageClass defined outside this instance selects on other keys, or to \"All\" to register every node label, which stops new volumes on a node once one of its labels is removed (openebs/zfs-localpv#528). The package owns OPENEBS_NAMESPACE, OPENEBS_NODE_NAME, OPENEBS_CSI_ENDPOINT, and OPENEBS_NODE_DRIVER.";
      };
      kubeletDir = lib.mkOption {
        type = absolutePath;
        default = "/var/lib/kubelet";
        description = "The kubelet's root directory on the host (upstream `zfsNode.kubeletDir`). k0s and microk8s use another path.";
      };
      encrKeysDir = lib.mkOption {
        type = lib.types.nullOr absolutePath;
        default = null;
        example = "/home/keys";
        description = "Host directory mounted at /home/keys in the node plugin, for datasets encrypted with `keylocation=file:///home/keys/...` (upstream `zfsNode.encrKeysDir`, whose chart default is /home/keys). Null mounts nothing.";
      };
      zfsBin = lib.mkOption {
        # The value goes into the wrapper script's command line.
        type = lib.types.strMatching "(/[A-Za-z0-9._+-]+)+|[A-Za-z0-9_][A-Za-z0-9._+-]*";
        default = "zfs";
        example = "/run/current-system/sw/bin/zfs";
        description = "The zfs binary run under `chroot /host` when neither /sbin/zfs nor /usr/sbin/zfs exists on the host (upstream `zfs.bin`): an absolute path, or a command name looked up on the host's PATH.";
      };
      nodeSelector = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Node labels the node plugin is limited to, for clusters where only some nodes have a ZFS pool.";
      };
      tolerations = lib.mkOption {
        type = lib.types.listOf toleration;
        default = [ ];
        description = "Taints the node plugin tolerates, for tainted storage nodes.";
      };
    };
  };

  assertions =
    { config, deps, ... }:
    let
      vscNames = builtins.attrNames config.volumeSnapshotClasses;
      defaults = defaultVscs config.volumeSnapshotClasses;

      # The apiserver rejects these combinations when the DaemonSet is
      # applied.
      tolerationProblems =
        i: t:
        let
          at = "config.node.tolerations.${toString i}";
        in
        lib.optional ((t.key == null || t.key == "") && t.operator != "Exists")
          "${at} has no key and operator ${t.operator}; a toleration without a key must use operator Exists. Set key, or set operator = \"Exists\"."
        ++
          lib.optional (t.operator == "Exists" && t.value != null)
            "${at} sets value with operator Exists, which matches any value. Remove value, or set operator = \"Equal\"."
        ++
          lib.optional (t.tolerationSeconds != null && t.effect != "NoExecute")
            "${at} sets tolerationSeconds with effect ${
              if t.effect == null then "null" else t.effect
            }; tolerationSeconds applies only to effect NoExecute. Set effect = \"NoExecute\", or remove tolerationSeconds.";
    in
    map
      (message: {
        assertion = false;
        inherit message;
      })
      (
        lib.optional (vscNames != [ ] && (deps.snapshotController or null) == null)
          "volumeSnapshotClasses defines ${lib.concatStringsSep ", " vscNames}, but nothing provides the snapshotController role, so the VolumeSnapshotClass kind has no owner. Add a snapshot-controller instance; on a cluster whose environment runs the controller, use its flavour (rke2 provides the role) or a kix.mkImport with roles = [ \"snapshotController\" ] and its crds; or remove volumeSnapshotClasses."
        ++
          lib.optional (builtins.length defaults > 1)
            "config.volumeSnapshotClasses.${builtins.elemAt defaults 0} and config.volumeSnapshotClasses.${builtins.elemAt defaults 1} are both annotated ${vscDefaultAnnotation}=\"true\". A VolumeSnapshot that names no class then fails, because the snapshot controller does not choose between two defaults for one driver. Keep the annotation on one class."
        # Each class becomes a part named by its key, and kix does not render
        # parts named root or meta.
        ++ map (
          n:
          "config.volumeSnapshotClasses.${n}: kix drops parts named root or meta, so this VolumeSnapshotClass would not be rendered. Rename it."
        ) (builtins.filter (n: n == "root" || n == "meta") vscNames)
        ++ lib.concatLists (lib.imap0 tolerationProblems config.node.tolerations)
      );

  build =
    {
      self,
      config,
      clusterConfig,
      snapshotController ? null,
      ...
    }:
    let
      inherit (scope.rbac)
        core
        group
        grant
        watch
        allow
        mkClusterRoleSet
        mkRoleSet
        ;
      storage = group "storage.k8s.io" [
        "storageclasses"
        "csinodes"
        "volumeattachments"
        "volumeattributesclasses"
        "csistoragecapacities"
      ];
      snapshots = group "snapshot.storage.k8s.io" [
        "volumesnapshotclasses"
        "volumesnapshotcontents"
        "volumesnapshots"
      ];
      zfs = group "zfs.openebs.io" [
        "zfsvolumes"
        "zfssnapshots"
        "zfsbackups"
        "zfsrestores"
        "zfsnodes"
      ];
      zfsAll = [
        zfs.zfsvolumes
        zfs.zfssnapshots
        zfs.zfsbackups
        zfs.zfsrestores
        zfs.zfsnodes
      ];
      coordination = group "coordination.k8s.io" [ "leases" ];
      apps = group "apps" [ "replicasets" ];

      hasSnapshotApi = snapshotController != null;
      kubeletDir = lib.removeSuffix "/" config.node.kubeletDir;
      pluginDir = "${kubeletDir}/plugins/zfs-localpv";

      sc = kix.storage.mkClasses {
        inherit scope clusterConfig who;
        optionPath = "config.storageClasses";
        classes = config.storageClasses;
        parts = self.classes;
        provisioner = self.csiDriver.out.name;
        requires = [
          self.controller
          self.node
        ];
      };

      crds = builtins.attrValues self.crds;
      snapshotCrds = lib.optionals hasSnapshotApi (builtins.attrValues snapshotController.out.crds);

      serviceAccountSubject = sa: [
        {
          kind = "ServiceAccount";
          name = sa.out.name;
          namespace = ns;
        }
      ];

      fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

      # Node label keys the node plugin registers as topology keys: the
      # hostname, plus every key the instance's own classes select on in
      # allowedTopologies. The upstream default "All" registers every node
      # label, and once one of them goes away csi-provisioner publishes no
      # CSIStorageCapacity for the node, so the scheduler rejects every new
      # claim there. KubeVirt renames its
      # scheduling.node.kubevirt.io/tsc-frequency-<hz> label when it
      # re-measures the clock (openebs/zfs-localpv#528). Upstream added
      # ALLOWED_TOPOLOGIES for this failure (issue openebs/zfs-localpv#394,
      # PR openebs/zfs-localpv#395) and kept "All" only so existing installs
      # did not change. The driver adds openebs.io/nodeid
      # and openebs.io/nodename itself, and volumes pin to openebs.io/nodeid.
      allowedTopologyKeys = lib.unique (
        [ "kubernetes.io/hostname" ]
        ++ lib.concatMap (
          cls: lib.concatMap (term: map (e: e.key) term.matchLabelExpressions) cls.allowedTopologies
        ) (builtins.attrValues config.storageClasses)
      );

      # One group per variable, so a refusal explains the variable it names
      # and points at the option that set it.
      ownedEnv =
        option:
        lib.mapAttrsToList (
          var: owned: {
            vars.${var} = owned.value;
            inherit (owned) from;
            fix = "Remove it from ${option}.";
          }
        );
      namespaceVar.OPENEBS_NAMESPACE = {
        value = fieldRef "metadata.namespace";
        from = "the pod's namespace, where the driver keeps its ZFS records";
      };

      # The sidecars elect a leader among the controller replicas, each with
      # its own Lease in the pod's namespace. The controller plugin runs
      # read-only informers, so every replica runs it. Each sidecar serves
      # /healthz/leader-election on its own port. The endpoint fails only
      # while that sidecar holds its Lease and cannot renew it.
      sidecar =
        {
          name,
          option,
          port,
          portName,
          extraArgs ? [ ],
          env ? [ ],
        }:
        let
          probe = {
            httpGet = {
              path = "/healthz/leader-election";
              port = portName;
            };
            periodSeconds = 20;
            timeoutSeconds = 10;
          };
        in
        {
          inherit name;
          image = kix.image.ref config.${option}.image;
          imagePullPolicy = config.${option}.image.pullPolicy;
          args = [
            "--csi-address=${socketDir}/csi.sock"
            "--v=2"
            "--leader-election"
            "--http-endpoint=:${toString port}"
          ]
          ++ extraArgs;
          ports = [ (kix.port portName port) ];
          livenessProbe = probe // {
            initialDelaySeconds = 10;
          };
          readinessProbe = probe;
          resources = config.${option}.resources;
          volumeMounts = [
            {
              name = "socket-dir";
              mountPath = socketDir;
            }
          ];
          securityContext = {
            allowPrivilegeEscalation = false;
            readOnlyRootFilesystem = true;
            capabilities.drop = [ "ALL" ];
          };
        }
        // lib.optionalAttrs (env != [ ]) { inherit env; };

      component = c: scope.selectorLabels // { "app.kubernetes.io/component" = c; };

      hostPath = path: type: { hostPath = { inherit path type; }; };
    in
    {
      crds = {
        zfsNodes = scope.mkCRD { spec = vendored "zfsnodes.zfs.openebs.io.json"; };
        zfsVolumes = scope.mkCRD { spec = vendored "zfsvolumes.zfs.openebs.io.json"; };
        zfsSnapshots = scope.mkCRD { spec = vendored "zfssnapshots.zfs.openebs.io.json"; };
        zfsBackups = scope.mkCRD { spec = vendored "zfsbackups.zfs.openebs.io.json"; };
        zfsRestores = scope.mkCRD { spec = vendored "zfsrestores.zfs.openebs.io.json"; };
      };

      csiDriver = scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "CSIDriver";
        name = driverName;
        spec = {
          # Volumes are local, so there is nothing to attach.
          attachRequired = false;
          podInfoOnMount = false;
          # The provisioner publishes each node's free pool space as
          # CSIStorageCapacity objects, and the scheduler reads them.
          storageCapacity = true;
        };
      };

      controllerServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-controller";
      };

      nodeServiceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-node";
      };

      zfsWrapper = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-zfs";
        data.zfs = ''
          #!/bin/sh
          if [ -x /host/sbin/zfs ]; then
            chroot /host /sbin/zfs "$@"
          elif [ -x /host/usr/sbin/zfs ]; then
            chroot /host /usr/sbin/zfs "$@"
          else
            chroot /host ${lib.escapeShellArg config.node.zfsBin} "$@"
          fi
        '';
      };

      controller = scope.mkDeployment {
        name = "${name}-controller";
        requires = crds ++ [ self.csiDriver ] ++ snapshotCrds;
        spec = {
          replicas = kix.availability.pick availability {
            none = 1;
            pod = 1;
            node = 2;
            zone = 2;
          };
          selector.matchLabels = component "controller";
          template.spec = {
            serviceAccount = self.controllerServiceAccount;
            priorityClassName = "system-cluster-critical";
            terminationGracePeriodSeconds = 30;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65532;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              (sidecar {
                name = "csi-provisioner";
                option = "csiProvisioner";
                port = 8080;
                portName = "provisioner";
                extraArgs = [
                  "--feature-gates=Topology=true"
                  "--strict-topology"
                  "--enable-capacity=true"
                  "--extra-create-metadata=true"
                  "--default-fstype=ext4"
                ];
                # Capacity tracking owns its CSIStorageCapacity objects
                # through this pod's ReplicaSet, found from these two.
                env = kix.mkEnvVars {
                  NAMESPACE = fieldRef "metadata.namespace";
                  POD_NAME = fieldRef "metadata.name";
                };
              })
              (sidecar {
                name = "csi-resizer";
                option = "csiResizer";
                port = 8081;
                portName = "resizer";
              })
            ]
            ++ lib.optional hasSnapshotApi (sidecar {
              name = "csi-snapshotter";
              option = "csiSnapshotter";
              port = 8082;
              portName = "snapshotter";
            })
            ++ [
              {
                name = "zfs-plugin";
                image = checkedRef config.image;
                imagePullPolicy = config.image.pullPolicy;
                args = [
                  "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                  "--plugin=$(OPENEBS_CONTROLLER_DRIVER)"
                ]
                ++ kix.guardArgs {
                  inherit who;
                  option = "controller.extraArgs";
                  owned = {
                    "--endpoint" = "the sidecars reach the plugin on the socket the package sets; remove it.";
                    "--plugin" = "it selects the controller code path; remove it.";
                    "--name" = "the driver name must equal the CSIDriver ${driverName}; remove it.";
                  };
                } config.controller.extraArgs;
                env = kix.mkEnvVars (
                  kix.mergeEnv {
                    inherit who;
                    # The backup garbage collector is not leader-elected: with
                    # more than one replica, each replica runs one.
                    defaults = {
                      OPENEBS_IO_ENABLE_ANALYTICS = "false";
                      OPENEBS_IO_ENABLE_BACKUP_GC = "false";
                    };
                    owned = ownedEnv "controller.env" (
                      namespaceVar
                      // {
                        OPENEBS_CSI_ENDPOINT = {
                          value = "unix://${socketDir}/csi.sock";
                          from = "the package; the plugin's --endpoint flag reads it, and the sidecars connect to the same socket";
                        };
                        OPENEBS_CONTROLLER_DRIVER = {
                          value = "controller";
                          from = "the package; the plugin's --plugin flag reads it to select the controller code path";
                        };
                      }
                    );
                  } config.controller.env
                );
                resources = config.controller.resources;
                volumeMounts = [
                  {
                    name = "socket-dir";
                    mountPath = socketDir;
                  }
                ];
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
              }
            ];
            volumes = [
              {
                name = "socket-dir";
                emptyDir = { };
              }
            ];
          };
        };
      };

      node = scope.mkDaemonSet {
        name = "${name}-node";
        requires = crds ++ [ self.csiDriver ];
        spec = {
          selector.matchLabels = component "node";
          template = {
            metadata.annotations."checksum/zfs-wrapper" = self.zfsWrapper.out.identityHash;
            spec = {
              serviceAccount = self.nodeServiceAccount;
              priorityClassName = "system-node-critical";
              terminationGracePeriodSeconds = 30;
              containers = [
                {
                  name = "node-driver-registrar";
                  image = kix.image.ref config.nodeDriverRegistrar.image;
                  imagePullPolicy = config.nodeDriverRegistrar.image.pullPolicy;
                  args = [
                    "--v=2"
                    "--csi-address=/plugin/csi.sock"
                    "--kubelet-registration-path=${pluginDir}/csi.sock"
                    "--http-endpoint=:9809"
                  ];
                  ports = [ (kix.port "healthz" 9809) ];
                  # /healthz fails while the registration socket is missing.
                  livenessProbe = {
                    httpGet = {
                      path = "/healthz";
                      port = "healthz";
                    };
                    initialDelaySeconds = 5;
                    timeoutSeconds = 5;
                  };
                  readinessProbe.httpGet = {
                    path = "/healthz";
                    port = "healthz";
                  };
                  resources = config.nodeDriverRegistrar.resources;
                  volumeMounts = [
                    {
                      name = "plugin-dir";
                      mountPath = "/plugin";
                    }
                    {
                      name = "registration-dir";
                      mountPath = "/registration";
                    }
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                }
                {
                  name = "zfs-plugin";
                  image = checkedRef config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "--nodename=$(OPENEBS_NODE_NAME)"
                    "--endpoint=$(OPENEBS_CSI_ENDPOINT)"
                    "--plugin=$(OPENEBS_NODE_DRIVER)"
                  ]
                  ++ kix.guardArgs {
                    inherit who;
                    option = "node.extraArgs";
                    owned = {
                      "--nodename" =
                        "the plugin's node ID must be the Kubernetes node name, which the package passes; remove it.";
                      "--endpoint" =
                        "the registrar and the kubelet reach the plugin on the socket the package sets; remove it.";
                      "--plugin" = "it selects the node code path; remove it.";
                      "--name" = "the driver name must equal the CSIDriver ${driverName}; remove it.";
                    };
                  } config.node.extraArgs;
                  env = kix.mkEnvVars (
                    kix.mergeEnv {
                      inherit who;
                      defaults.ALLOWED_TOPOLOGIES = lib.concatStringsSep "," allowedTopologyKeys;
                      owned = ownedEnv "node.env" (
                        namespaceVar
                        // {
                          OPENEBS_NODE_NAME = {
                            value = fieldRef "spec.nodeName";
                            from = "the pod's node name; --nodename passes it to the plugin as its node ID";
                          };
                          OPENEBS_CSI_ENDPOINT = {
                            value = "unix:///plugin/csi.sock";
                            from = "the package; the plugin's --endpoint flag reads it, and the registrar and the kubelet connect to the same socket";
                          };
                          OPENEBS_NODE_DRIVER = {
                            value = "agent";
                            from = "the package; the plugin's --plugin flag reads it to select the node code path";
                          };
                        }
                      );
                    } config.node.env
                  );
                  resources = config.node.resources;
                  securityContext = {
                    privileged = true;
                    allowPrivilegeEscalation = true;
                  };
                  volumeMounts = [
                    {
                      name = "plugin-dir";
                      mountPath = "/plugin";
                    }
                    {
                      name = "device-dir";
                      mountPath = "/dev";
                    }
                  ]
                  ++ lib.optional (config.node.encrKeysDir != null) {
                    name = "encr-keys";
                    mountPath = "/home/keys";
                  }
                  ++ [
                    {
                      name = "zfs-wrapper";
                      mountPath = "/sbin/zfs";
                      subPath = "zfs";
                    }
                    {
                      name = "host-root";
                      mountPath = "/host";
                      mountPropagation = "HostToContainer";
                      readOnly = true;
                    }
                    # The kubelet passes host paths under its root directory,
                    # so the mount path equals the host path. Bidirectional
                    # propagation makes the plugin's mounts visible to the
                    # kubelet and the pods.
                    {
                      name = "pods-mount-dir";
                      mountPath = kubeletDir;
                      mountPropagation = "Bidirectional";
                    }
                  ];
                }
              ];
              volumes = [
                ({ name = "device-dir"; } // hostPath "/dev" "Directory")
                ({ name = "host-root"; } // hostPath "/" "Directory")
                ({ name = "registration-dir"; } // hostPath "${kubeletDir}/plugins_registry" "DirectoryOrCreate")
                ({ name = "plugin-dir"; } // hostPath pluginDir "DirectoryOrCreate")
                ({ name = "pods-mount-dir"; } // hostPath kubeletDir "Directory")
                {
                  name = "zfs-wrapper";
                  configMap = {
                    name = self.zfsWrapper.out.name;
                    defaultMode = 365; # 0555
                  };
                }
              ]
              ++ lib.optional (config.node.encrKeysDir != null) (
                { name = "encr-keys"; } // hostPath config.node.encrKeysDir "DirectoryOrCreate"
              );
            }
            // lib.optionalAttrs (config.node.nodeSelector != { }) { inherit (config.node) nodeSelector; }
            // lib.optionalAttrs (config.node.tolerations != [ ]) {
              tolerations = map (lib.filterAttrs (_: v: v != null)) config.node.tolerations;
            };
          };
        };
      };

      classes = sc.resources;

      snapshotClasses = lib.optionalAttrs hasSnapshotApi (
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
            requires = [ self.controller ];
          }
        ) config.volumeSnapshotClasses
      );

      root = {
        resource = self.controller;
        requires = [
          self.node
        ]
        ++ builtins.attrValues self.classes
        ++ builtins.attrValues self.snapshotClasses;
        out = { inherit (sc) storageClassName; };
      };
    }
    // mkClusterRoleSet scope {
      subjects = serviceAccountSubject self.controllerServiceAccount;
      labels = scope.selectorLabels;
      # The union of the sidecars' upstream RBAC (external-provisioner
      # v5.2.0, external-resizer v1.13.2, external-snapshotter v8.2.0
      # deploy/kubernetes) and what the controller plugin reads and writes.
      roles."${name}-${ns}-controller" = grant (
        [
          (
            core.persistentvolumes
            |> allow [
              "get"
              "list"
              "watch"
              "create"
              "patch"
              "delete"
            ]
          )
          (
            core.persistentvolumeclaims
            |> allow [
              "get"
              "list"
              "watch"
              "update"
            ]
          )
          (core "persistentvolumeclaims/status" |> allow [ "patch" ])
          (core.pods |> watch)
          (core.nodes |> watch)
          (
            core.events
            |> allow [
              "list"
              "watch"
              "create"
              "update"
              "patch"
            ]
          )
          (
            [
              storage.storageclasses
              storage.csinodes
              storage.volumeattachments
              storage.volumeattributesclasses
            ]
            |> watch
          )
          (
            zfsAll
            |> allow [
              "get"
              "list"
              "watch"
              "create"
              "update"
              "patch"
              "delete"
            ]
          )
        ]
        ++ lib.optionals hasSnapshotApi [
          # Provisioning a volume from a snapshot reads both.
          (
            [
              snapshots.volumesnapshots
              snapshots.volumesnapshotcontents
            ]
            |> allow [
              "get"
              "list"
            ]
          )
          (snapshots.volumesnapshotclasses |> watch)
          (
            snapshots.volumesnapshotcontents
            |> allow [
              "get"
              "list"
              "watch"
              "update"
              "patch"
            ]
          )
          (
            snapshots "volumesnapshotcontents/status"
            |> allow [
              "update"
              "patch"
            ]
          )
        ]
      );
    }
    // mkClusterRoleSet scope {
      subjects = serviceAccountSubject self.nodeServiceAccount;
      labels = scope.selectorLabels;
      # The node plugin reads its node's labels for topology and keeps the
      # node's ZFSNode record and the volumes' records current.
      roles."${name}-${ns}-node" = grant [
        (core.nodes |> watch)
        (
          core.events
          |> allow [
            "create"
            "update"
            "patch"
          ]
        )
        (
          zfsAll
          |> allow [
            "get"
            "list"
            "watch"
            "create"
            "update"
            "patch"
          ]
        )
      ];
    }
    // mkRoleSet scope {
      subjects = serviceAccountSubject self.controllerServiceAccount;
      labels = scope.selectorLabels;
      roles."${name}-controller" = grant [
        (
          coordination.leases
          |> allow [
            "get"
            "watch"
            "list"
            "delete"
            "update"
            "create"
          ]
        )
        (
          storage.csistoragecapacities
          |> allow [
            "get"
            "list"
            "watch"
            "create"
            "update"
            "patch"
            "delete"
          ]
        )
        # Capacity tracking walks from its own pod to the owning ReplicaSet.
        (core.pods |> allow [ "get" ])
        (apps.replicasets |> allow [ "get" ])
      ];
    };
}
