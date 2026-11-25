# Tests for `controller` on `scope.mkCRD` and `scope.mkCRDRef`: every custom
# resource of the kind depends on the named workload through a
# `controller:` entry of `kix.run/depends-on`, a kind without one keeps
# today's entries, and a value that is not a workload fails when the kind is
# declared.

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

  operatorDeployment =
    scope:
    scope.mkDeployment {
      name = "operator";
      availability.max = "none";
      spec = {
        replicas = 1;
        selector.matchLabels = scope.selectorLabels;
        template = {
          metadata.labels = scope.selectorLabels;
          spec.containers = [
            {
              name = "operator";
              image = "example.test/operator:1";
            }
          ];
        };
      };
    };

  # A package with an operator Deployment, a check ConfigMap, a Widget kind
  # declared with `declare`, and one Widget built from it. `declare` gets the
  # scope and the package's own resources.
  widgetPackage = declare: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        operator = operatorDeployment scope;
        check = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "check";
          extra.data.ok = "true";
        };
        widgetCrd = declare scope self;
        widget = scope.mkCR self.widgetCrd { name = "w"; };
        root = self.widget;
      };
  };

  viaCRD =
    extra: scope: self:
    scope.mkCRD (
      {
        spec = widgetSpec;
        holdsData = false;
      }
      // extra self
    );

  viaRef =
    extra: scope: self:
    scope.mkCRDRef (
      {
        group = "example.test";
        kind = "Widget";
        plural = "widgets";
        version = "v1";
        holdsData = false;
      }
      // extra self
    );

  build =
    declare:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = widgetPackage declare;
      }
    ];

  # The depends-on entries of the Widget, and the hashes of the operator and
  # the check.
  entriesOf =
    declare:
    let
      cluster = build declare;
      raw = cluster.instances.app.widgets.raw;
      hashOf = r: builtins.unsafeDiscardStringContext r.out.identityHash;
    in
    {
      dependsOn = lib.splitString "," (
        (byName "w" (manifests cluster)).metadata.annotations.${kixKeys.dependsOn} or ""
      );
      operator = hashOf raw.operator;
      check = hashOf raw.check;
    };

  # The Widget names the operator as its controller, once, and not also as
  # a plain requirement.
  namesController =
    declare:
    let
      e = entriesOf declare;
    in
    builtins.elem "controller:${e.operator}" e.dependsOn
    && !(builtins.elem "requires:${e.operator}" e.dependsOn);

  withController =
    viaFn:
    viaFn (self: {
      controller = self.operator;
    });

  # A cluster whose package declares the Widget kind with `controller` set
  # to `value`, and builds no Widget.
  declaredOnly =
    viaFn: value:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.widgets.package = {
          meta.version = "test";
          build =
            { self, scope, ... }:
            {
              operator = operatorDeployment scope;
              widgetCrd = viaFn (self: { controller = value self; }) scope self;
              root = self.widgetCrd;
            };
        };
      }
    ];

  helpers = import ../caught.nix { inherit lib; };
  refusal =
    (helpers.caughtSentences ../../core/resource.nix { inherit lib; }).validateController
      "scope.mkCRD widgets"
      "example.test/Widget"
      {
        kind = "Service";
        name = "operator";
        outPath = "/nix/store/x";
      };
in
{
  lib-crd-controller-on-mkcrd =
    namesController (withController viaCRD)
    || throw "a Widget built from scope.mkCRD does not name its controller: ${builtins.toJSON (entriesOf (withController viaCRD))}";

  lib-crd-controller-on-mkcrdref =
    namesController (withController viaRef)
    || throw "a Widget built from scope.mkCRDRef does not name its controller: ${builtins.toJSON (entriesOf (withController viaRef))}";

  # A list names each workload. The check, in crRequires as well, keeps its
  # `requires:` entry.
  lib-crd-controller-list-and-cr-requires =
    let
      e = entriesOf (
        viaCRD (self: {
          controller = [ self.operator ];
          crRequires = [ self.check ];
        })
      );
    in
    (
      builtins.elem "controller:${e.operator}" e.dependsOn
      && builtins.elem "requires:${e.check}" e.dependsOn
    )
    || throw "a Widget with a controller list and crRequires: ${builtins.toJSON e}";

  # Naming the operator in both crRequires and controller writes one
  # `controller:` entry.
  lib-crd-controller-dedupes-cr-requires =
    let
      both = viaCRD (self: {
        controller = self.operator;
        crRequires = [ self.operator ];
      });
    in
    namesController both
    || throw "a Widget with the operator in crRequires and controller: ${builtins.toJSON (entriesOf both)}";

  # Without controller, or with null, the Widget does not depend on the
  # operator and writes no `controller:` entry.
  lib-crd-controller-default-none =
    let
      unset = entriesOf (viaCRD (_: { }));
      nulled = entriesOf (
        viaRef (_: {
          controller = null;
        })
      );
      none = e: !(builtins.any (lib.hasInfix e.operator) e.dependsOn);
    in
    (none unset && none nulled)
    || throw "a Widget without a controller depends on the operator: ${
      builtins.toJSON [
        unset
        nulled
      ]
    }";

  # The refusal names the declaration, the kind, and what was given.
  lib-crd-controller-refusal-message =
    lib.hasInfix
      "scope.mkCRD widgets: controller for example.test/Widget must be a workload or list of workloads (got Service \"operator\")."
      (refusal.thrown or "")
    || throw "controller refusal: ${builtins.toJSON refusal}";

  # Both declarations refuse a controller that is not a workload even when no
  # custom resource of the kind is built. The controls with the operator
  # build.
  lib-crd-controller-refused-at-declaration =
    (
      evalFails (declaredOnly viaCRD (_: "operator"))
      && evalFails (declaredOnly viaRef (_: { }))
      && !(evalFails (declaredOnly viaCRD (self: self.operator)))
      && !(evalFails (declaredOnly viaRef (self: self.operator)))
    )
    || throw "a kind declared with a controller that is not a workload built, or a control failed";

  # A misspelt argument is refused with the id, the argument, the kind, and
  # the accepted names. The same declaration without it builds.
  lib-crd-unknown-argument-message =
    let
      full = (helpers.loadCaughtFull ../../core/resource.nix) { inherit lib; };
      refused =
        site:
        full.refuseUnknownCrdArguments {
          inherit site;
          declares = "example.test/Widget";
          accepted = full.mkCRDArguments;
          args.controler = true;
        };
      text = (refused "scope.mkCRD").thrown;
    in
    lib.all (needle: lib.hasInfix needle text) [
      "[K9267]"
      "scope.mkCRD for example.test/Widget received unknown argument(s): controler. Kix rejected this CRD declaration."
      "Rename or remove the unknown argument(s). Accepted arguments: spec, labels, annotations, ownership"
      "controller"
    ]
    || throw "unknown CRD argument message: ${text}";

  lib-crd-unknown-argument-refused =
    let
      typo = self: {
        controler = self.operator;
      };
    in
    (
      evalFails (build (viaCRD typo))
      && evalFails (build (viaRef typo))
      && !(evalFails (build (viaCRD (_: { }))))
      && !(evalFails (build (viaRef (_: { }))))
    )
    || throw "scope.mkCRD or scope.mkCRDRef accepted an unknown argument, or a valid declaration failed";
}
