# zfs-localpv: the OpenEBS LocalPV-ZFS CSI driver, which provisions
# PersistentVolumes as ZFS datasets or zvols on a ZFS pool that already
# exists on each node. root = the controller Deployment.
#
# Installs the five zfs.openebs.io CRDs, CSIDriver `zfs.csi.openebs.io`,
# controller and node ServiceAccounts and RBAC, ConfigMap `<name>-zfs` with
# the host `zfs` wrapper, Deployment `<name>-controller`, DaemonSet
# `<name>-node`, and the configured StorageClasses and VolumeSnapshotClasses.
#
#   instances.storage.zfs-localpv = {
#     package = packages.zfs-localpv;
#     config.storageClasses.zfs.parameters.poolname = "tank/k8s";
#   };
#
# Precondition: every node the node plugin runs on has the pool. The plugin
# runs `zfs` on the host through `chroot /host`; set `node.zfsBin` where the
# binary is neither `/sbin/zfs` nor `/usr/sbin/zfs`, and `node.nodeSelector`
# when only some nodes have a pool.
#
# The driver stores ZFSVolume, ZFSSnapshot, and ZFSNode records in the
# instance's namespace (`OPENEBS_NAMESPACE`).
#
# Snapshots: when the optional `snapshotController` dependency resolves, the
# controller runs `csi-snapshotter` and renders `volumeSnapshotClasses`.
#
# `out.storageClassName`: the class annotated
# `storageclass.kubernetes.io/is-default-class`, or the sole class; reading it
# throws otherwise.
#
# Alerts: none. The ZFS driver registers no Prometheus metrics. The CSI
# sidecars serve operation-latency metrics on their health ports, which the
# package does not scrape. A claim that cannot be provisioned stays
# Pending with an Event on it, and pool health is left to the node's own
# monitoring, such as node-exporter's ZFS collector.

{
  scope,
  lib,
  kix,
  availability,
}:
let
  release = "2.11.1";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "zfs-localpv ${ns}/${name}";

  driverName = "zfs.csi.openebs.io";
  socketDir = "/var/lib/csi/sockets/pluginproxy";
  vscDefaultAnnotation = "snapshot.storage.kubernetes.io/is-default-class";

  vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;

  minorOf = tag: builtins.match "v?([0-9]+)\\.([0-9]+)\\..*" tag;
  releaseMinor = minorOf release;
  checkedRef =
    image:
    let
      tag = builtins.unsafeDiscardStringContext image.tag;
    in
    if minorOf tag != releaseMinor then
      throw (
        "${who}: image.tag \"${tag}\" is not a ${lib.concatStringsSep "." releaseMinor} release, "
        + "and the CRDs under kix/packages/stable/zfs-localpv/crds are vendored from ${release}. To move to "
        + "another release, change release in kix/packages/stable/zfs-localpv/default.nix and run "
        + "uv run scripts/vendor-crds.py zfs-localpv."
      )
    else
      kix.image.ref image;

  defaultVscs =
    classes:
    builtins.filter (n: (classes.${n}.annotations.${vscDefaultAnnotation} or null) == "true") (
      builtins.attrNames classes
    );
in
{
  meta = {
    version = release;
    description = "OpenEBS LocalPV-ZFS CSI driver: PersistentVolumes as ZFS datasets or zvols on each node's existing pool";
    owner = "platform";
    unsafe = [
      "privileged"
      "run-as-root"
    ];
    podSecurity = "privileged";
    defaultAliases = [ "zfsLocalPv" ];
    conflictsWith = [ "cluster:zfsLocalPv" ];
    k8s.minVersion = "1.24";
  };

  options = import ./options.nix {
    inherit
      lib
      kix
      release
      vscDefaultAnnotation
      ;
  };

  assertions =
    { config, deps, ... }:
    let
      vscNames = builtins.attrNames config.volumeSnapshotClasses;
      defaults = defaultVscs config.volumeSnapshotClasses;

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

      fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

      # Register only `kubernetes.io/hostname` and keys referenced by
      # `storageClasses.*.allowedTopologies` so transient node labels do not
      # invalidate CSIStorageCapacity topology matching.
      allowedTopologyKeys = lib.unique (
        [ "kubernetes.io/hostname" ]
        ++ lib.concatMap (
          cls: lib.concatMap (term: map (e: e.key) term.matchLabelExpressions) cls.allowedTopologies
        ) (builtins.attrValues config.storageClasses)
      );

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
      # Nodes, volumes, and snapshots are records the node agent keeps; a
      # backup or restore runs in the agent too, but that is not checked here.
      crds = {
        zfsNodes = scope.mkCRD {
          spec = vendored "zfsnodes.zfs.openebs.io.json";
          usesAtLeast = _: { };
        };
        zfsVolumes = scope.mkCRD {
          spec = vendored "zfsvolumes.zfs.openebs.io.json";
          usesAtLeast = _: { };
        };
        zfsSnapshots = scope.mkCRD {
          spec = vendored "zfssnapshots.zfs.openebs.io.json";
          usesAtLeast = _: { };
        };
        zfsBackups = scope.mkCRD { spec = vendored "zfsbackups.zfs.openebs.io.json"; };
        zfsRestores = scope.mkCRD { spec = vendored "zfsrestores.zfs.openebs.io.json"; };
      };

      csiDriver = scope.mkClusterResource {
        apiVersion = "storage.k8s.io/v1";
        kind = "CSIDriver";
        name = driverName;
        spec = {
          attachRequired = false;
          podInfoOnMount = false;
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
                    defaultMode = 365;
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
    // import ./rbac.nix {
      inherit
        scope
        lib
        self
        name
        ns
        hasSnapshotApi
        ;
    };
}
