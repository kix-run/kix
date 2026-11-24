# Tests for `crRequires` on `scope.mkCRD` and `scope.mkCRDRef`: every custom
# resource of the kind requires the listed resources, and a value that is
# not a list fails when the kind is declared.

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

  # The Widget requires both the check and the kind's declaration.
  requiresCheck =
    declare:
    let
      e = entriesOf declare;
    in
    builtins.elem e.check e.dependsOn && builtins.elem e.crd e.dependsOn;

  # A cluster whose package declares the Widget kind with a crRequires that
  # is not a list, and builds no Widget.
  declaredOnly =
    declare:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              widgetCrd = declare scope { };
              root = self.widgetCrd;
            };
        };
      }
    ];

  helpers = import ../caught.nix { inherit lib; };
  refusal =
    (helpers.caught ../../core/resource.nix { inherit lib; }).validateCrRequires "scope.mkCRD widgets"
      "example.test/Widget"
      { };
in
{
  lib-crd-cr-requires-on-mkcrd =
    requiresCheck viaCRD
    || throw "a Widget built from scope.mkCRD does not require its crRequires and the CRD: ${builtins.toJSON (entriesOf viaCRD)}";

  lib-crd-cr-requires-on-mkcrdref =
    requiresCheck viaRef
    || throw "a Widget built from scope.mkCRDRef does not require its crRequires and the CRD marker: ${builtins.toJSON (entriesOf viaRef)}";

  # Without crRequires the Widget does not require the check.
  lib-crd-cr-requires-default-empty =
    let
      e = entriesOf (scope: _: viaCRD scope [ ]);
    in
    !(builtins.elem e.check e.dependsOn)
    || throw "a Widget requires the check without crRequires: ${builtins.toJSON e}";

  # The refusal names the declaration and the kind.
  lib-crd-cr-requires-refusal-message =
    lib.hasInfix
      "scope.mkCRD widgets: crRequires for example.test/Widget must be a list of resources (got set)"
      (refusal.thrown or "")
    || throw "crRequires refusal: ${builtins.toJSON refusal}";

  # Both declarations refuse a crRequires that is not a list even when no
  # custom resource of the kind is built. The controls with a list build.
  lib-crd-cr-requires-refused-at-declaration =
    (
      evalFails (declaredOnly viaCRD)
      && evalFails (declaredOnly viaRef)
      && !(evalFails (declaredOnly (scope: _: viaCRD scope [ ])))
      && !(evalFails (declaredOnly (scope: _: viaRef scope [ ])))
    )
    || throw "a kind declared with a crRequires that is not a list built, or a control failed";
}
