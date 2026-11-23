# Tests for `crRequires` on `scope.mkCRD` and `scope.mkCRDRef`: every custom
# resource of the kind requires the listed resources, before the CRD.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  byName,
  evalFails,
  ...
}:

let
  widgetSpec = {
    group = "example.test";
    names = {
      kind = "Widget";
      plural = "widgets";
    };
    scope = "Namespaced";
    versions = [
      {
        name = "v1";
        served = true;
        storage = true;
        schema.openAPIV3Schema.type = "object";
      }
    ];
  };

  # A package with a check ConfigMap, a Widget kind declared with `declare`,
  # and one Widget built from it.
  widgetPackage = declare: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        check = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "check";
          extra.data.ok = "true";
        };
        widgetCrd = declare scope [ self.check ];
        widget = scope.mkCR self.widgetCrd { name = "w"; };
        root = self.widget;
      };
  };

  viaCRD =
    scope: crRequires:
    scope.mkCRD {
      spec = widgetSpec;
      holdsData = false;
      inherit crRequires;
    };

  viaRef =
    scope: crRequires:
    scope.mkCRDRef {
      group = "example.test";
      kind = "Widget";
      plural = "widgets";
      version = "v1";
      holdsData = false;
      inherit crRequires;
    };

  build =
    declare:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = widgetPackage declare;
      }
    ];

  # The depends-on entries of the Widget and the requires entries of the
  # check and the kind's declaration.
  entriesOf =
    declare:
    let
      cluster = build declare;
      raw = cluster.instances.app.widgets.raw;
      hashOf = r: "requires:${builtins.unsafeDiscardStringContext r.out.identityHash}";
    in
    {
      dependsOn = lib.splitString "," (
        (byName "w" (manifests cluster)).metadata.annotations.${kixKeys.dependsOn} or ""
      );
      check = hashOf raw.check;
      crd = hashOf raw.widgetCrd;
    };

  # The check comes before the CRD in the Widget's requires.
  requiresCheckFirst =
    declare:
    let
      e = entriesOf declare;
      indexOf = entry: lib.lists.findFirstIndex (x: x == entry) null e.dependsOn;
    in
    indexOf e.check != null && indexOf e.crd != null && indexOf e.check < indexOf e.crd;
in
{
  lib-crd-cr-requires-on-mkcrd =
    requiresCheckFirst viaCRD
    || throw "a Widget built from scope.mkCRD does not require its crRequires before the CRD: ${builtins.toJSON (entriesOf viaCRD)}";

  lib-crd-cr-requires-on-mkcrdref =
    requiresCheckFirst viaRef
    || throw "a Widget built from scope.mkCRDRef does not require its crRequires before the CRD marker: ${builtins.toJSON (entriesOf viaRef)}";

  # Without crRequires the Widget does not require the check.
  lib-crd-cr-requires-default-empty =
    let
      e = entriesOf (scope: _: viaCRD scope [ ]);
    in
    !(builtins.elem e.check e.dependsOn)
    || throw "a Widget requires the check without crRequires: ${builtins.toJSON e}";

  lib-crd-cr-requires-refuses-non-list =
    evalFails (build (scope: checks: viaCRD scope (builtins.head checks)))
    || throw "crRequires that is not a list was accepted";
}
