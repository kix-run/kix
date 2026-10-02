# Tests for instance-level extraDeps: on a kix.mkImport instance a
# `ref.<namespace>.<instance>` entry becomes an edge to that instance's
# PackageInstance marker (eval/import.nix resolveExtraDep); a value that is
# neither a resource nor a ref, a ref to the import itself and a ref to an
# inactive optional instance fail evaluation; and a managed instance refuses
# the option (eval/instance.nix _extraDepsCheck).

{
  lib,
  k8s,
  eval,
  kixKeys,
  mkCluster,
  baseInstances,
  mkCmPackage,
  manifests,
  ofKind,
  evalFails,
  ...
}:

let
  legacyImport = eval.mkImport {
    kind = "Service";
    apiVersion = "v1";
    out = {
      name = "legacy-api";
      port = 8080;
    };
  };

  # A cluster with a managed `apps/contract` instance and a `legacy/legacy-api`
  # import whose extraDeps is `extraDeps ref`.
  withImportExtraDeps =
    extraDeps:
    mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          instances.apps.contract.package = mkCmPackage { name = "contract"; };
          instances.legacy.legacy-api = {
            package = legacyImport;
            extraDeps = extraDeps ref;
          };
        }
      )
    ];

  importMarker =
    cluster:
    lib.findFirst (m: m.metadata.name == "legacy-api" && (m.metadata.namespace or "") == "legacy")
      (throw "import marker legacy/legacy-api not rendered")
      (ofKind "PackageInstance" (manifests cluster));

  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
in
{
  # The marker of an import whose extraDeps holds `ref.apps.contract` depends
  # on the contract's PackageInstance marker, tagged "extra:".
  lib-import-extra-deps-ref-orders-after-instance-marker =
    let
      cluster = withImportExtraDeps (ref: [ ref.apps.contract ]);
      contractMarkerHash = k8s.extractStoreHash cluster.instances.apps.contract.root.outPath;
      annot = dependsOn (importMarker cluster);
    in
    lib.hasInfix "extra:${contractMarkerHash}" annot
    || throw "import marker does not depend on the contract's PackageInstance; annotation: ${annot}";

  # A ref to another import resolves to that import's marker.
  lib-import-extra-deps-ref-to-import =
    let
      cluster = mkCluster [
        baseInstances
        (
          { ref, ... }:
          {
            instances.legacy.upstream.package = eval.mkImport {
              out.name = "upstream";
            };
            instances.legacy.legacy-api = {
              package = legacyImport;
              extraDeps = [ ref.legacy.upstream ];
            };
          }
        )
      ];
      upstreamHash = k8s.extractStoreHash cluster.instances.legacy.upstream.root.outPath;
      annot = dependsOn (importMarker cluster);
    in
    lib.hasInfix "extra:${upstreamHash}" annot
    || throw "import marker does not depend on the other import's marker; annotation: ${annot}";

  # mkResource ignores an extraDeps value without an outPath, so a string
  # would add no edge. It fails evaluation instead.
  lib-import-extra-deps-string-fails =
    evalFails (withImportExtraDeps (_: [ "contract" ]))
    || throw "an extraDeps string entry on an import evaluated";

  # An attribute set that is neither a resource nor a ref fails.
  lib-import-extra-deps-attrset-fails =
    evalFails (withImportExtraDeps (_: [ { name = "contract"; } ]))
    || throw "an extraDeps attribute set entry on an import evaluated";

  lib-import-extra-deps-self-ref-fails =
    evalFails (withImportExtraDeps (ref: [ ref.legacy.legacy-api ]))
    || throw "an import ordered after its own marker evaluated";

  # An optional instance nothing activates renders no marker, so an edge to
  # it could never be satisfied at deploy time.
  lib-import-extra-deps-inactive-optional-target-fails =
    evalFails (mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          instances.apps.contract = {
            package = mkCmPackage { name = "contract"; };
            optional = true;
          };
          instances.legacy.legacy-api = {
            package = legacyImport;
            extraDeps = [ ref.apps.contract ];
          };
        }
      )
    ])
    || throw "an extraDeps ref to an inactive optional instance evaluated";

  # A managed instance's marker already follows its resources; the option
  # would be ignored there, so it fails.
  lib-import-extra-deps-on-managed-instance-fails =
    evalFails (mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          instances.apps.contract.package = mkCmPackage { name = "contract"; };
          instances.apps.other = {
            package = mkCmPackage { name = "other"; };
            extraDeps = [ ref.apps.contract ];
          };
        }
      )
    ])
    || throw "extraDeps on a managed instance evaluated";
}
