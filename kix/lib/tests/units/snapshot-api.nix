# Tests for the snapshotController role and `kix.mkImport { crds }` (an
# environment import that hands out CRD handles and emits their markers),
# and for the zfs-localpv and snapshot-controller packages: their refusals,
# their wiring on the rke2 and kind flavours, their optional parts, and
# snapshot-controller's alert rules.
# The role tests use a flavour-shaped module defined here, so they do not
# depend on a real flavour's bindings; the package tests use the real ones.

{
  lib,
  k8s,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  snapshotGroup = "snapshot.storage.k8s.io";
  importNs = "kube-system";
  importName = "platform-snapshot-controller";

  # An environment that runs its own snapshot controller: the role is bound
  # `binding` and answered by an import of two of the API's CRDs, one
  # cluster-scoped and one namespaced.
  snapshotEnvironment =
    {
      optional ? false,
      binding ? "exclusive",
      crds ? [
        {
          group = snapshotGroup;
          kind = "VolumeSnapshotClass";
          plural = "volumesnapshotclasses";
          version = "v1";
          crdScope = "Cluster";
        }
        {
          group = snapshotGroup;
          kind = "VolumeSnapshot";
          plural = "volumesnapshots";
          version = "v1";
          crdScope = "Namespaced";
        }
      ],
    }:
    {
      cluster.roles.snapshotController = {
        inherit binding;
        provider = "test-snapshot-controller";
      };
      instances.${importNs}.${importName} = {
        package = eval.mkImport {
          roles = [ "snapshotController" ];
          inherit crds;
        };
        inherit optional;
      };
    };

  # A managed package claiming the role, with the out the role requires.
  managedController = {
    meta = {
      version = "test";
      roles = [ "snapshotController" ];
    };
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "managed-snapshot-controller";
        };
        root = {
          resource = self.cm;
          out.crds = { };
        };
      };
  };

  # Builds one VolumeSnapshotClass and one VolumeSnapshot from the provider's
  # handles. With `optional`, the dependency defaults to null and the
  # consumer builds nothing without a provider.
  snapshotConsumer =
    { optional }:
    let
      parts =
        self: scope: snapshotController:
        {
          root = self.cm;
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "snapshot-consumer";
          };
        }
        // lib.optionalAttrs (snapshotController != null) {
          snapshotClass = scope.mkCR snapshotController.out.crds.VolumeSnapshotClass {
            name = "fast";
            extra = {
              driver = "test.csi.example.com";
              deletionPolicy = "Delete";
            };
          };
          snapshot = scope.mkCR snapshotController.out.crds.VolumeSnapshot {
            name = "before-upgrade";
            spec = {
              volumeSnapshotClassName = "fast";
              source.persistentVolumeClaimName = "data";
            };
          };
        };
    in
    {
      meta.version = "test";
      build =
        if optional then
          {
            self,
            scope,
            snapshotController ? null,
            ...
          }:
          parts self scope snapshotController
        else
          {
            self,
            scope,
            snapshotController,
            ...
          }:
          parts self scope snapshotController;
    };

  clusterWith =
    modules:
    mkCluster (
      [
        baseInstances
      ]
      ++ modules
    );

  markerName = plural: "crd-ref-${importName}-${plural}-snapshot-storage-k8s-io";
  classMarkerName = markerName "volumesnapshotclasses";
  snapshotMarkerName = markerName "volumesnapshots";

  markersOf = ms: ofKind "PackageInstance" ms;
  hasMarker =
    name: ms:
    builtins.any (m: m.metadata.name == name && (m.metadata.namespace or "") == importNs) (
      markersOf ms
    );
  annotationsOf = m: m.metadata.annotations or { };
  dependsOn = m: (annotationsOf m).${kixKeys.dependsOn} or "";

  zfsLocalPvPackage = import ../../../packages/stable/zfs-localpv;
  snapshotControllerPackage = import ../../../packages/stable/snapshot-controller;
  kindFlavor = import ../../flavors/kind.nix;
  rke2Flavor = import ../../flavors/rke2.nix;

  zfsBaseConfig = {
    storageClasses.zfs.parameters.poolname = "tank/k8s";
    volumeSnapshotClasses.zfs = { };
  };

  # A cluster with zfs-localpv in `storage`, `config` merged over `base`.
  # `snapshotController` adds a snapshot-controller instance with that
  # config; null adds none.
  zfsCluster =
    {
      flavor ? kindFlavor,
      base ? zfsBaseConfig,
      config ? { },
      snapshotController ? { },
      extraInstances ? { },
      module ? { },
    }:
    mkCluster [
      flavor
      {
        instances.storage = {
          zfs-localpv = {
            package = zfsLocalPvPackage;
            config = lib.recursiveUpdate base config;
          };
        }
        // lib.optionalAttrs (snapshotController != null) {
          snapshot-controller = {
            package = snapshotControllerPackage;
            config = snapshotController;
          };
        }
        // extraInstances;
      }
      module
    ];

  builds = cluster: !(evalFails cluster);

  # The messages of zfs-localpv's failed assertions for `config` (merged
  # over zfsBaseConfig), with or without a snapshotController provider.
  # A failed assertion fails the whole cluster before its diagnostics can
  # be read, so the messages are taken from the package directly.
  zfsAssertionMessages =
    {
      config,
      provider ? true,
    }:
    let
      package = zfsLocalPvPackage {
        inherit lib;
        kix = kixlib;
        scope = {
          instanceName = "zfs-localpv";
          namespaceName = "storage";
        };
        availability = "none";
      };
      evaluated =
        (lib.evalModules {
          modules = [
            { options = package.options; }
            { config = lib.recursiveUpdate zfsBaseConfig config; }
          ];
        }).config;
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        package.assertions {
          config = evaluated;
          deps.snapshotController = if provider then { } else null;
        }
      )
    );

  containerNamed = name: containers: lib.findFirst (c: c.name == name) null containers;
in
{
  # The environment binds the role exclusive, so a managed claimant is
  # refused. Without the binding the same instances build, which shows the
  # refusal comes from the binding.
  snapshot-api-exclusive-refuses-managed =
    let
      withManaged =
        binding:
        clusterWith [
          (snapshotEnvironment { inherit binding; })
          { instances.storage.snapshot-controller.package = managedController; }
        ];
    in
    (evalFails (withManaged "exclusive") && !(evalFails (withManaged null)))
    || throw "exclusive snapshotController binding: refused ${builtins.toJSON (evalFails (withManaged "exclusive"))}, unbound control refused ${builtins.toJSON (evalFails (withManaged null))}";

  # A non-optional import with one cluster-scoped and one namespaced CRD
  # emits both markers in its namespace. A consumer's CRs built from the
  # handles depend on the markers, and the cluster-scoped one has no
  # namespace.
  snapshot-api-import-crds-markers =
    let
      cluster = clusterWith [
        (snapshotEnvironment { })
        { instances.appns.consumer.package = snapshotConsumer { optional = false; }; }
      ];
      ms = manifests cluster;
      handles = cluster.instances.${importNs}.${importName}.out.crds;
      hashOf = handle: k8s.extractStoreHash handle.outPath;
      classMarker = byName classMarkerName (markersOf ms);
      snapshotClass = byName "fast" (ofKind "VolumeSnapshotClass" ms);
      snapshot = byName "before-upgrade" (ofKind "VolumeSnapshot" ms);
    in
    (
      hasMarker classMarkerName ms
      && hasMarker snapshotMarkerName ms
      && (annotationsOf classMarker).${kixKeys.crdKind} == "VolumeSnapshotClass"
      && (annotationsOf classMarker).${kixKeys.crdScope} == "Cluster"
      && (annotationsOf classMarker).${kixKeys.importName} == "volumesnapshotclasses.${snapshotGroup}"
      && snapshotClass.apiVersion == "${snapshotGroup}/v1"
      && !(snapshotClass.metadata ? namespace)
      && lib.hasInfix "requires:${hashOf handles.VolumeSnapshotClass}" (dependsOn snapshotClass)
      && snapshot.metadata.namespace == "appns"
      && lib.hasInfix "requires:${hashOf handles.VolumeSnapshot}" (dependsOn snapshot)
    )
    || throw "import crds markers: markers ${
      builtins.toJSON (map (m: "${m.metadata.namespace or ""}/${m.metadata.name}") (markersOf ms))
    }, VolumeSnapshotClass ${builtins.toJSON snapshotClass}";

  # A required dependency activates an optional import with crds, which
  # then emits its markers; without the consumer it stays inactive and emits
  # none. An optional dependency places no demand, and the inactive import
  # does not answer it, so the consumer gets null and builds no custom
  # resources.
  snapshot-api-optional-import-activates =
    let
      clusterOf =
        consumer:
        clusterWith (
          [ (snapshotEnvironment { optional = true; }) ]
          ++ lib.optional (consumer != null) { instances.appns.consumer.package = consumer; }
        );
      withConsumer = manifests (
        clusterOf (snapshotConsumer {
          optional = false;
        })
      );
      withoutConsumer = manifests (clusterOf null);
      optionalConsumer = manifests (
        clusterOf (snapshotConsumer {
          optional = true;
        })
      );
    in
    (
      hasMarker classMarkerName withConsumer
      && hasMarker snapshotMarkerName withConsumer
      && byName "fast" (ofKind "VolumeSnapshotClass" withConsumer) != null
      && !(hasMarker classMarkerName withoutConsumer)
      && !(hasMarker classMarkerName optionalConsumer)
      && byName "snapshot-consumer" (ofKind "ConfigMap" optionalConsumer) != null
      && ofKind "VolumeSnapshotClass" optionalConsumer == [ ]
    )
    || throw "optional import activation: markers with consumer ${
      builtins.toJSON (map (m: m.metadata.name) (markersOf withConsumer))
    }, without ${builtins.toJSON (map (m: m.metadata.name) (markersOf withoutConsumer))}";

  # crds entries are checked: a missing version, a key mkImport does not
  # accept (installedBy) and a kind given twice each fail the build.
  snapshot-api-import-crds-entry-checks =
    let
      oneEntry = {
        group = snapshotGroup;
        kind = "VolumeSnapshot";
        plural = "volumesnapshots";
        version = "v1";
      };
      # The import is not optional, so its markers are always emitted.
      withCrds = crds: clusterWith [ (snapshotEnvironment { inherit crds; }) ];
    in
    (
      evalFails (withCrds [ (removeAttrs oneEntry [ "version" ]) ])
      && evalFails (withCrds [ (oneEntry // { installedBy = [ ]; }) ])
      && evalFails (withCrds [
        oneEntry
        oneEntry
      ])
      && !(evalFails (withCrds [ oneEntry ]))
    )
    || throw "mkImport crds entry checks did not refuse every bad entry";

  # Each zfs-localpv assertion names the setting and the fix: VolumeSnapshotClasses
  # without a provider of the role, two default classes, class keys that kix
  # does not render as parts, and tolerations the apiserver would reject.
  snapshot-api-zfs-localpv-assertion-messages =
    let
      refusedWith =
        needles: args:
        let
          messages = zfsAssertionMessages args;
        in
        builtins.all (n: builtins.any (lib.hasInfix n) messages) needles;
      cases = {
        control =
          zfsAssertionMessages {
            config.node.tolerations = [
              {
                key = "example.com/storage";
                operator = "Exists";
                effect = "NoExecute";
                tolerationSeconds = 60;
              }
              { operator = "Exists"; }
            ];
          } == [ ];
        no-provider =
          refusedWith
            [
              "volumeSnapshotClasses defines zfs, but nothing provides the snapshotController role"
            ]
            {
              config = { };
              provider = false;
            };
        two-defaults =
          refusedWith
            [
              "config.volumeSnapshotClasses.a and config.volumeSnapshotClasses.b are both annotated snapshot.storage.kubernetes.io/is-default-class"
            ]
            {
              config.volumeSnapshotClasses = {
                a.annotations."snapshot.storage.kubernetes.io/is-default-class" = "true";
                b.annotations."snapshot.storage.kubernetes.io/is-default-class" = "true";
              };
            };
        reserved-keys =
          refusedWith
            [
              "config.volumeSnapshotClasses.root: kix drops parts named root or meta, so this VolumeSnapshotClass would not be rendered. Rename it."
              "config.volumeSnapshotClasses.meta: kix drops parts named root or meta"
            ]
            {
              config.volumeSnapshotClasses = {
                root = { };
                meta = { };
              };
            };
        toleration-without-key = refusedWith [ "config.node.tolerations.0 has no key and operator Equal" ] {
          config.node.tolerations = [ { effect = "NoSchedule"; } ];
        };
        toleration-exists-with-value =
          refusedWith [ "config.node.tolerations.0 sets value with operator Exists" ]
            {
              config.node.tolerations = [
                {
                  key = "k";
                  operator = "Exists";
                  value = "v";
                }
              ];
            };
        toleration-seconds-without-noexecute =
          refusedWith [ "config.node.tolerations.1 sets tolerationSeconds with effect NoSchedule" ]
            {
              config.node.tolerations = [
                { operator = "Exists"; }
                {
                  key = "k";
                  operator = "Exists";
                  effect = "NoSchedule";
                  tolerationSeconds = 10;
                }
              ];
            };
      };
      failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
    failed == [ ] || throw "zfs-localpv assertions without the expected message: ${toString failed}";

  # A VolumeSnapshotClass keyed root or meta fails the cluster; without the
  # check the build renders only the other classes.
  snapshot-api-zfs-localpv-reserved-class-keys-fail-the-build =
    (
      evalFails (zfsCluster {
        config.volumeSnapshotClasses = {
          root = { };
          meta = { };
          ok = { };
        };
      })
      && builds (zfsCluster {
        config.volumeSnapshotClasses.ok = { };
      })
    )
    || throw "zfs-localpv built with VolumeSnapshotClasses keyed root and meta";

  # Each case differs from a building cluster by one setting the build
  # refuses with a throw or a type error: an image of another minor release,
  # a flag or an env var the package owns, a zfsBin that is not a path or a
  # command name, a class without poolname, and a second instance of either
  # package. tryEval drops the message of a throw, so the cases check that
  # the cluster fails while the control builds; the messages were read in a
  # probe.
  snapshot-api-build-refusals =
    let
      cases = {
        control = !(builds (zfsCluster { }));
        zfs-image-of-another-release = builds (zfsCluster {
          config.image.tag = "2.7.1";
        });
        snapshot-controller-image-of-another-release = builds (zfsCluster {
          snapshotController.image.tag = "v8.5.0";
        });
        controller-owned-flag = builds (zfsCluster {
          config.controller.extraArgs = [ "--name=other.csi.example.com" ];
        });
        node-owned-flag = builds (zfsCluster {
          config.node.extraArgs = [ "--nodename=x" ];
        });
        controller-owned-env = builds (zfsCluster {
          config.controller.env.OPENEBS_NAMESPACE = "other";
        });
        node-owned-env = builds (zfsCluster {
          config.node.env.OPENEBS_NODE_NAME = "x";
        });
        snapshot-controller-owned-flag = builds (zfsCluster {
          snapshotController.extraArgs = [ "--leader-election-namespace=kube-system" ];
        });
        zfs-bin-with-shell-syntax = builds (zfsCluster {
          config.node.zfsBin = "zfs\" $(reboot)";
        });
        zfs-bin-relative-path = builds (zfsCluster {
          config.node.zfsBin = "bin/zfs";
        });
        class-without-poolname = builds (zfsCluster {
          config.storageClasses.other = { };
        });
        second-zfs-localpv = builds (zfsCluster {
          module.instances.other.zfs-localpv = {
            package = zfsLocalPvPackage;
            config = { };
          };
        });
        second-snapshot-controller = builds (zfsCluster {
          module.instances.other.snapshot-controller.package = snapshotControllerPackage;
        });
      };
      wrong = lib.attrNames (lib.filterAttrs (_: bad: bad) cases);
    in
    wrong == [ ]
    || throw "zfs-localpv and snapshot-controller refusals: these cases did not behave: ${toString wrong}";

  # On rke2 the environment provides the snapshot API: zfs-localpv's
  # VolumeSnapshotClass is built from the platform import's handle, has no
  # namespace, depends on the import's marker, and the controller runs
  # csi-snapshotter. The import emits one marker per CRD in kube-system.
  snapshot-api-rke2-provides-snapshot-api =
    let
      cluster = zfsCluster {
        flavor = rke2Flavor;
        snapshotController = null;
      };
      ms = manifests cluster;
      importName' = "platform-snapshot-controller";
      handles = cluster.instances.kube-system.${importName'}.out.crds;
      hashOf = handle: k8s.extractStoreHash handle.outPath;
      markers = builtins.filter (
        m:
        lib.hasPrefix "crd-ref-${importName'}-" m.metadata.name
        && (m.metadata.namespace or "") == "kube-system"
      ) (ofKind "PackageInstance" ms);
      vsc = byName "zfs" (ofKind "VolumeSnapshotClass" ms);
      controller = byName "zfs-localpv-controller" (ofKind "Deployment" ms);
      containers = map (c: c.name) controller.spec.template.spec.containers;
    in
    (
      builtins.sort builtins.lessThan (map (m: m.metadata.name) markers) == [
        "crd-ref-${importName'}-volumesnapshotclasses-snapshot-storage-k8s-io"
        "crd-ref-${importName'}-volumesnapshotcontents-snapshot-storage-k8s-io"
        "crd-ref-${importName'}-volumesnapshots-snapshot-storage-k8s-io"
      ]
      && vsc != null
      && !(vsc.metadata ? namespace)
      && vsc.driver == "zfs.csi.openebs.io"
      && lib.hasInfix "requires:${hashOf handles.VolumeSnapshotClass}" (dependsOn vsc)
      && builtins.elem "csi-snapshotter" containers
      && byName "snapshot-controller" (ofKind "Deployment" ms) == null
    )
    || throw "rke2 snapshot API: markers ${
      builtins.toJSON (map (m: m.metadata.name) markers)
    }, VolumeSnapshotClass ${builtins.toJSON vsc}, controller containers ${builtins.toJSON containers}";

  # rke2 binds the role exclusive, so a managed snapshot-controller is
  # refused; with the binding set to absent, as for a cluster that disables
  # RKE2's snapshot charts, the same instances build.
  snapshot-api-rke2-refuses-managed-snapshot-controller =
    (
      evalFails (zfsCluster {
        flavor = rke2Flavor;
      })
      && builds (zfsCluster {
        flavor = rke2Flavor;
        module.cluster.roles.snapshotController.binding = "absent";
      })
    )
    || throw "rke2 did not refuse a managed snapshot-controller, or the absent override did not build";

  # Without a snapshotController provider and with no VolumeSnapshotClasses,
  # the controller runs no csi-snapshotter and no VolumeSnapshotClass is
  # rendered.
  snapshot-api-zfs-localpv-without-snapshot-api =
    let
      ms = manifests (zfsCluster {
        snapshotController = null;
        base = removeAttrs zfsBaseConfig [ "volumeSnapshotClasses" ];
      });
      controller = byName "zfs-localpv-controller" (ofKind "Deployment" ms);
    in
    (
      controller != null
      && containerNamed "csi-snapshotter" controller.spec.template.spec.containers == null
      && ofKind "VolumeSnapshotClass" ms == [ ]
    )
    || throw "zfs-localpv without a snapshot provider: containers ${
      builtins.toJSON (map (c: c.name) controller.spec.template.spec.containers)
    }";

  # The node options reach the DaemonSet and the wrapper; the node pod is
  # not on the host network, and the registrar serves a probed /healthz.
  # Without encrKeysDir no key directory is mounted.
  snapshot-api-zfs-localpv-node-options =
    let
      nodeOf =
        config:
        let
          ms = manifests (zfsCluster {
            inherit config;
          });
        in
        {
          ds = byName "zfs-localpv-node" (ofKind "DaemonSet" ms);
          wrapper = (byName "zfs-localpv-zfs" (ofKind "ConfigMap" ms)).data.zfs;
        };
      set = nodeOf {
        node = {
          kubeletDir = "/var/lib/k0s/kubelet/";
          encrKeysDir = "/srv/zfs-keys";
          zfsBin = "/run/current-system/sw/bin/zfs";
          nodeSelector."example.com/zfs-pool" = "true";
          tolerations = [
            {
              key = "example.com/storage";
              operator = "Exists";
              effect = "NoSchedule";
            }
          ];
        };
      };
      unset = nodeOf { };
      podOf = n: n.ds.spec.template.spec;
      volume = n: name: lib.findFirst (v: v.name == name) null (podOf n).volumes;
      registrar = containerNamed "node-driver-registrar" (podOf set).containers;
    in
    (
      (podOf set).nodeSelector == {
        "example.com/zfs-pool" = "true";
      }
      &&
        (podOf set).tolerations == [
          {
            key = "example.com/storage";
            operator = "Exists";
            effect = "NoSchedule";
          }
        ]
      && !((podOf set) ? hostNetwork)
      && (volume set "pods-mount-dir").hostPath.path == "/var/lib/k0s/kubelet"
      && (volume set "plugin-dir").hostPath.path == "/var/lib/k0s/kubelet/plugins/zfs-localpv"
      && (volume set "encr-keys").hostPath.path == "/srv/zfs-keys"
      && lib.hasInfix "chroot /host /run/current-system/sw/bin/zfs \"$@\"" set.wrapper
      && builtins.elem "--http-endpoint=:9809" registrar.args
      && registrar.livenessProbe.httpGet.path == "/healthz"
      && volume unset "encr-keys" == null
      && !((podOf unset) ? nodeSelector)
      && !((podOf unset) ? tolerations)
      && lib.hasInfix "chroot /host zfs \"$@\"" unset.wrapper
    )
    || throw "zfs-localpv node options: pod ${builtins.toJSON (podOf set)}, wrapper ${set.wrapper}";

  # snapshot-controller builds its metrics Service and ServiceMonitor only
  # when metrics are enabled and a prometheus provider resolves.
  snapshot-api-snapshot-controller-metrics =
    let
      metricsParts =
        {
          enabled,
          prometheus,
        }:
        let
          ms = manifests (zfsCluster {
            snapshotController.metrics.enabled = enabled;
            extraInstances = lib.optionalAttrs prometheus {
              prometheus.package = prometheusStub;
            };
          });
        in
        {
          service = byName "snapshot-controller-metrics" (ofKind "Service" ms);
          monitor = byName "snapshot-controller" (ofKind "ServiceMonitor" ms);
        };
      on = metricsParts {
        enabled = true;
        prometheus = true;
      };
      off = metricsParts {
        enabled = false;
        prometheus = true;
      };
      noProvider = metricsParts {
        enabled = true;
        prometheus = false;
      };
    in
    (
      on.service != null
      && on.monitor != null
      && builtins.any (p: p.name == "http" && p.port == 8080) on.service.spec.ports
      && off.service == null
      && off.monitor == null
      && noProvider.service == null
    )
    || throw "snapshot-controller metrics: enabled ${builtins.toJSON on}, disabled ${builtins.toJSON off}, no provider ${builtins.toJSON noProvider}";

  # snapshot-controller's alerts render under `snapshot-controller-alerts`
  # with a prometheus provider and metrics.enabled, and every expression
  # selects the metrics Service.
  snapshot-api-snapshot-controller-alerts =
    let
      rulesOf =
        {
          snapshotController ? { },
          extraInstances ? {
            prometheus.package = prometheusStub;
          },
        }:
        alertRulesOf "PrometheusRule" "snapshot-controller" (
          manifests (zfsCluster {
            inherit snapshotController extraInstances;
          })
        );
      rules = rulesOf { };
    in
    (
      allSelect ''namespace="storage",service="snapshot-controller-metrics"'' rules
      && builtins.attrNames rules == [ "SnapshotControllerDown" ]
      && rulesOf { extraInstances = { }; } == null
      && rulesOf { snapshotController.metrics.enabled = false; } == null
    )
    || throw "snapshot-controller alerts: ${builtins.toJSON (builtins.attrNames rules)}";
}
