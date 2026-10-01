# Tests for the snapshotController role and `kix.mkImport { crds }`: an
# environment import that hands out CRD handles and emits their markers.
# The environment is a flavour-shaped module defined here, so the tests do
# not depend on a real flavour's bindings.

{
  lib,
  k8s,
  eval,
  kixKeys,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
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
in
{
  # The environment binds the role exclusive, so a managed claimant is
  # refused. Without the binding the same instances build, which shows the
  # refusal comes from the binding.
  openebs-exclusive-refuses-managed =
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
  openebs-import-crds-markers =
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

  # An optional import with crds, answered by a consumer whose dependency is
  # optional, becomes active and emits its markers. Without the consumer it
  # stays inactive and emits none.
  openebs-optional-import-activates =
    let
      withConsumer = manifests (clusterWith [
        (snapshotEnvironment { optional = true; })
        { instances.appns.consumer.package = snapshotConsumer { optional = true; }; }
      ]);
      withoutConsumer = manifests (clusterWith [ (snapshotEnvironment { optional = true; }) ]);
    in
    (
      hasMarker classMarkerName withConsumer
      && hasMarker snapshotMarkerName withConsumer
      && byName "fast" (ofKind "VolumeSnapshotClass" withConsumer) != null
      && !(hasMarker classMarkerName withoutConsumer)
    )
    || throw "optional import activation: markers with consumer ${
      builtins.toJSON (map (m: m.metadata.name) (markersOf withConsumer))
    }, without ${builtins.toJSON (map (m: m.metadata.name) (markersOf withoutConsumer))}";

  # crds entries are checked: a missing version, a key mkImport does not
  # accept (installedBy) and a kind given twice each fail the build.
  openebs-import-crds-entry-checks =
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
}
