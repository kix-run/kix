# Tests for instance-level extraDeps. On a kix.mkImport instance a
# `ref.<namespace>.<instance>` entry becomes an edge to that instance's
# PackageInstance marker and activates the target when it is optional
# (eval/import.nix resolveExtraDep, eval/auto.nix demandsOf). An entry that
# is neither a resource nor a ref, a ref to the import itself, a cycle of
# refs between imports, and extraDeps on a managed instance fail
# evaluation, whether or not the instance is active
# (eval/import.nix checkInstanceExtraDeps).

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
  hasName,
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

  evaluates = cluster: builtins.deepSeq (manifests cluster) true;

  # A cluster with an `apps/contract` instance configured by `contract` and
  # a `legacy/legacy-api` import whose extraDeps is `extraDeps ref`.
  withImportExtraDeps' =
    contract: extraDeps:
    mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          instances.apps.contract = {
            package = mkCmPackage { name = "contract"; };
          }
          // contract;
          instances.legacy.legacy-api = {
            package = legacyImport;
            extraDeps = extraDeps ref;
          };
        }
      )
    ];

  withImportExtraDeps = withImportExtraDeps' { };

  markerOf =
    ns: name: cluster:
    lib.findFirst (m: m.metadata.name == name && (m.metadata.namespace or "") == ns) null (
      ofKind "PackageInstance" (manifests cluster)
    );

  importMarker =
    cluster:
    let
      m = markerOf "legacy" "legacy-api" cluster;
    in
    if m == null then throw "import marker legacy/legacy-api not rendered" else m;

  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";

  # Whether the legacy/legacy-api marker carries an extraDeps edge to `res`.
  ordersAfter =
    cluster: res:
    lib.hasInfix "extra:${k8s.extractStoreHash res.outPath}" (dependsOn (importMarker cluster));

  # A managed package whose optional build argument `legacy-api` resolves to
  # an import of that name. Such a resolution activates an optional import
  # (activatedImports in eval/cluster.nix) without placing a demand.
  optionalArgConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        legacy-api ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "optional-arg-consumer";
          data.target = if legacy-api == null then "none" else "resolved";
        };
        root = self.cm;
      };
  };
in
{
  # The control for the failure tests below that use withImportExtraDeps.
  lib-import-extra-deps-empty-list-evaluates = evaluates (withImportExtraDeps (_: [ ]));

  # The marker of an import whose extraDeps holds `ref.apps.contract` depends
  # on the contract's PackageInstance marker, tagged "extra:".
  lib-import-extra-deps-ref-orders-after-instance-marker =
    let
      cluster = withImportExtraDeps (ref: [ ref.apps.contract ]);
    in
    ordersAfter cluster cluster.instances.apps.contract.root
    || throw "import marker does not depend on the contract's PackageInstance; annotation: ${dependsOn (importMarker cluster)}";

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
    in
    ordersAfter cluster cluster.instances.legacy.upstream.root
    || throw "import marker does not depend on the other import's marker; annotation: ${dependsOn (importMarker cluster)}";

  # A resource entry adds an edge to that resource.
  lib-import-extra-deps-resource-entry =
    let
      res = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "ordering-gate";
        namespace = k8s.clusterScoped;
        labels."app.kubernetes.io/managed-by" = "kix";
      };
      cluster = withImportExtraDeps (_: [ res ]);
    in
    ordersAfter cluster res
    || throw "import marker does not depend on the resource entry; annotation: ${dependsOn (importMarker cluster)}";

  # A ref activates an optional target, as `deps.x = ref.a.b` does.
  lib-import-extra-deps-ref-activates-optional-managed =
    let
      cluster = withImportExtraDeps' { optional = true; } (ref: [ ref.apps.contract ]);
    in
    (
      markerOf "apps" "contract" cluster != null
      && hasName "contract" (manifests cluster)
      && ordersAfter cluster cluster.instances.apps.contract.root
    )
    || throw "an extraDeps ref did not activate the optional managed instance";

  lib-import-extra-deps-ref-activates-optional-import =
    let
      cluster = mkCluster [
        baseInstances
        (
          { ref, ... }:
          {
            instances.legacy.upstream = {
              package = eval.mkImport { out.name = "upstream"; };
              optional = true;
            };
            instances.legacy.legacy-api = {
              package = legacyImport;
              extraDeps = [ ref.legacy.upstream ];
            };
          }
        )
      ];
    in
    (
      markerOf "legacy" "upstream" cluster != null
      && ordersAfter cluster cluster.instances.legacy.upstream.root
    )
    || throw "an extraDeps ref did not activate the optional import";

  # A ref to an optional target that another instance's `deps` activates.
  lib-import-extra-deps-ref-to-optional-activated-by-deps =
    let
      cluster = mkCluster [
        baseInstances
        (
          { ref, ... }:
          {
            instances.apps.contract = {
              package = mkCmPackage {
                name = "contract";
                out.who = "contract";
              };
              optional = true;
            };
            instances.apps.user = {
              package = {
                meta.version = "test";
                build =
                  {
                    self,
                    scope,
                    contract,
                    ...
                  }:
                  {
                    cm = scope.mkResource {
                      apiVersion = "v1";
                      kind = "ConfigMap";
                      name = "user";
                      data.who = contract.who;
                    };
                    root = self.cm;
                  };
              };
              deps.contract = ref.apps.contract;
            };
            instances.legacy.legacy-api = {
              package = legacyImport;
              extraDeps = [ ref.apps.contract ];
            };
          }
        )
      ];
    in
    ordersAfter cluster cluster.instances.apps.contract.root
    || throw "an extraDeps ref to an optional instance that deps activates did not order after it";

  # An inactive import's refs activate nothing.
  lib-import-extra-deps-inactive-import-activates-nothing =
    let
      cluster = mkCluster [
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
              optional = true;
              extraDeps = [ ref.apps.contract ];
            };
          }
        )
      ];
    in
    (markerOf "legacy" "legacy-api" cluster == null && !(hasName "contract" (manifests cluster)))
    || throw "an inactive import's extraDeps activated its target";

  # An import that only an optional build argument activates does not
  # activate its refs' targets, so a ref to an optional target fails.
  lib-import-extra-deps-optional-arg-activated-import-refusal =
    let
      cluster =
        withOptionalTarget:
        mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              instances.apps.contract = {
                package = mkCmPackage { name = "contract"; };
                optional = withOptionalTarget;
              };
              instances.apps.consumer.package = optionalArgConsumer;
              instances.legacy.legacy-api = {
                package = legacyImport;
                optional = true;
                extraDeps = [ ref.apps.contract ];
              };
            }
          )
        ];
    in
    (evaluates (cluster false) && markerOf "legacy" "legacy-api" (cluster false) != null)
    && evalFails (cluster true)
    || throw "an import activated by an optional build argument evaluated with a ref to an inactive instance";

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

  # The entry check runs on an import nothing activates as well.
  lib-import-extra-deps-inactive-import-bad-entry-fails =
    let
      cluster =
        entries:
        mkCluster [
          baseInstances
          {
            instances.legacy.legacy-api = {
              package = legacyImport;
              optional = true;
              extraDeps = entries;
            };
          }
        ];
    in
    (evaluates (cluster [ ]) && evalFails (cluster [ "oops" ]))
    || throw "a malformed extraDeps entry on an inactive import evaluated";

  # Two imports whose refs name each other fail with a Kix message instead
  # of Nix's infinite recursion; one direction alone is covered by ref-to-import.
  lib-import-extra-deps-cycle-fails =
    evalFails (mkCluster [
      baseInstances
      (
        { ref, ... }:
        {
          instances.legacy.a = {
            package = eval.mkImport { out.name = "a"; };
            extraDeps = [ ref.legacy.b ];
          };
          instances.legacy.b = {
            package = eval.mkImport { out.name = "b"; };
            extraDeps = [ ref.legacy.a ];
          };
        }
      )
    ])
    || throw "a cycle of extraDeps refs between imports evaluated";

  # A managed instance's marker already follows its resources; the option
  # would be ignored there, so it fails, whether the instance is active or
  # not. The same clusters without extraDeps are the control.
  lib-import-extra-deps-on-managed-instance-fails =
    let
      cluster =
        other:
        mkCluster [
          baseInstances
          (
            { ref, ... }:
            {
              instances.apps.contract.package = mkCmPackage { name = "contract"; };
              instances.apps.other = {
                package = mkCmPackage { name = "other"; };
              }
              // other ref;
            }
          )
        ];
      withExtraDeps = ref: { extraDeps = [ ref.apps.contract ]; };
    in
    (
      evaluates (cluster (_: { }))
      && evaluates (
        cluster (_: {
          optional = true;
        })
      )
      && evalFails (cluster withExtraDeps)
      && evalFails (cluster (ref: withExtraDeps ref // { optional = true; }))
    )
    || throw "extraDeps on a managed instance evaluated";
}
