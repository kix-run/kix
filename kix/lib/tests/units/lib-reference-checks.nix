# Tests for CRD reference declarations (scope.mkCRDRef: required version,
# per-instance markers, the crd-* annotations), served-version checks on
# custom resources, and optional import activation (eval/cluster.nix
# activatedImports).

{
  lib,
  eval,
  kixKeys,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  hasName,
  evalFails,
  ...
}:

let
  # A package that references the example.com Widget CRD. `refArgs` is
  # merged into the mkCRDRef call; `crArgs`, when set, builds one Widget.
  widgetRefPackage =
    {
      refArgs ? {
        version = "v1";
      },
      crArgs ? null,
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          widgetCrd = scope.mkCRDRef (
            {
              group = "example.com";
              kind = "Widget";
              plural = "widgets";
            }
            // refArgs
          );
          root = self.widgetCrd;
        }
        // lib.optionalAttrs (crArgs != null) {
          widget = scope.mkCR self.widgetCrd ({ name = "w"; } // crArgs);
        };
    };

  # A package that declares a Gadget CRD serving v1 and listing v1beta1 as
  # not served, and builds one Gadget with `crArgs`.
  gadgetPackage = crArgs: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        gadgetCrd = scope.mkCRD {
          spec = {
            group = "example.com";
            scope = "Namespaced";
            names = {
              kind = "Gadget";
              listKind = "GadgetList";
              plural = "gadgets";
              singular = "gadget";
            };
            versions = [
              {
                name = "v1";
                served = true;
                storage = true;
                schema.openAPIV3Schema = {
                  type = "object";
                  x-kubernetes-preserve-unknown-fields = true;
                };
              }
              {
                name = "v1beta1";
                served = false;
                storage = false;
                schema.openAPIV3Schema = {
                  type = "object";
                  x-kubernetes-preserve-unknown-fields = true;
                };
              }
            ];
          };
        };
        gadget = scope.mkCR self.gadgetCrd ({ name = "g"; } // crArgs);
        root = self.gadgetCrd;
      };
  };

  withApp = instances: mkCluster [
    baseInstances
    { inherit instances; }
  ];

  annotationsOf = m: m.metadata.annotations or { };

  # --- activation fixtures ---

  # An optional import answering `x`, as a flavour's platform import does.
  optionalImport = {
    instances.platform.x = {
      package = eval.mkImport {
        kind = "StorageClass";
        apiVersion = "storage.k8s.io/v1";
        out = {
          name = "import-sc";
          who = "import";
        };
      };
      optional = true;
    };
  };

  # A consumer whose `x` dependency is optional or required.
  xConsumer =
    { optional }:
    {
      meta.version = "test";
      build =
        if optional then
          {
            self,
            scope,
            x ? null,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "x-consumer";
              extra.data.who = if x == null then "none" else x.out.who;
            };
            root = self.cm;
          }
        else
          {
            self,
            scope,
            x,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "x-consumer";
              extra.data.who = x.out.who;
            };
            root = self.cm;
          };
    };

  # A managed package answering `x` (and any `aliases` given).
  xProvider =
    {
      who,
      aliases ? [ "x" ],
      scope ? null,
    }:
    {
      meta = {
        version = "test";
        defaultAliases = aliases;
      }
      // lib.optionalAttrs (scope != null) { inherit scope; };
      build =
        { self, scope, ... }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "provider-${who}";
          };
          root = {
            resource = self.cm;
            out = { inherit who; };
          };
        };
    };

  activationCluster = modules: manifests (mkCluster ([ baseInstances optionalImport ] ++ modules));

  # The import's marker: a PackageInstance named after the import instance
  # in its namespace, in import mode.
  importMarker =
    ms:
    lib.findFirst (
      m:
      m.kind == "PackageInstance"
      && m.metadata.name == "x"
      && (m.metadata.namespace or "") == "platform"
      && (annotationsOf m).${kixKeys.mode} or "" == "import"
    ) null ms;

  whoOf = ms: (byName "x-consumer" (ofKind "ConfigMap" ms)).data.who or "missing";
in
{
  # --- mkCRDRef ---

  lib-reference-checks-crdref-without-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { refArgs = { }; };
  });

  lib-reference-checks-crdref-invalid-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { refArgs.version = "V1"; };
  });

  lib-reference-checks-crdref-invalid-scope-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage {
      refArgs = {
        version = "v1";
        crdScope = "namespaced";
      };
    };
  });

  # Two instances in one namespace that reference one CRD render one marker
  # each, named for the instance and carrying the declared kind, version
  # and scope.
  lib-reference-checks-crdref-markers-per-instance =
    let
      ms = manifests (withApp {
        appns.widgets-a.package = widgetRefPackage { };
        appns.widgets-b.package = widgetRefPackage { refArgs.version = "v1beta1"; };
      });
      markers = ofKind "PackageInstance" ms;
      a = byName "crd-ref-widgets-a-widgets-example-com" markers;
      b = byName "crd-ref-widgets-b-widgets-example-com" markers;
    in
    (
      a != null
      && b != null
      && (annotationsOf a).${kixKeys.crdKind} == "Widget"
      && (annotationsOf a).${kixKeys.crdVersion} == "v1"
      && (annotationsOf b).${kixKeys.crdVersion} == "v1beta1"
      && (annotationsOf a).${kixKeys.crdScope} == "Namespaced"
      && (annotationsOf a).${kixKeys.importName} == "widgets.example.com"
    )
    || throw "per-instance CRD ref markers: ${builtins.toJSON (map (m: m.metadata.name) markers)}";

  # --- served versions ---

  lib-reference-checks-cr-at-ref-version-passes =
    let
      ms = manifests (withApp {
        appns.widgets.package = widgetRefPackage { crArgs = { }; };
      });
    in
    (byName "w" (ofKind "Widget" ms)).apiVersion == "example.com/v1"
    || throw "a Widget at the ref's version was not built";

  lib-reference-checks-cr-at-unserved-ref-version-throws = evalFails (withApp {
    appns.widgets.package = widgetRefPackage { crArgs.version = "v2"; };
  });

  lib-reference-checks-cr-at-served-crd-version-passes =
    let
      ms = manifests (withApp { appns.gadgets.package = gadgetPackage { }; });
    in
    (byName "g" (ofKind "Gadget" ms)).apiVersion == "example.com/v1"
    || throw "a Gadget at the CRD's served version was not built";

  # v1beta1 is listed in spec.versions with served = false.
  lib-reference-checks-cr-at-unserved-crd-version-throws = evalFails (withApp {
    appns.gadgets.package = gadgetPackage { version = "v1beta1"; };
  });

  # The reference-mode VM operator names every monitoring.coreos.com kind it
  # converts, at the version upstream serves. The AlertmanagerConfig marker
  # is the longest CRD ref marker name in kixpkgs.
  lib-reference-checks-victoria-metrics-operator-refs =
    let
      ms = manifests (mkCluster [
        {
          instances.monitoring-system.victoria-metrics-operator = {
            package = import ../../../packages/victoria-metrics-operator;
            config = {
              prometheusOperatorCRDs = "reference";
              convert = {
                scrapeConfigs = true;
                alertmanagerConfigs = true;
              };
            };
          };
        }
      ]);
      markers = ofKind "PackageInstance" ms;
      versionOf =
        plural:
        (annotationsOf (byName "crd-ref-victoria-metrics-operator-${plural}-monitoring-coreos-com" markers))
        .${kixKeys.crdVersion};
    in
    (
      versionOf "alertmanagerconfigs" == "v1alpha1"
      && versionOf "scrapeconfigs" == "v1alpha1"
      && versionOf "servicemonitors" == "v1"
      && !(hasName "servicemonitors.monitoring.coreos.com" (ofKind "CustomResourceDefinition" ms))
    )
    || throw "VM operator refs: ${builtins.toJSON (map (m: m.metadata.name) markers)}";

  # --- optional import activation ---

  # An optional dependency that resolves to an optional import activates
  # it: the marker names the StorageClass the deploy waits for.
  lib-reference-checks-optional-dep-activates-import =
    let
      ms = activationCluster [ { instances.appns.consumer.package = xConsumer { optional = true; }; } ];
      marker = importMarker ms;
    in
    (
      whoOf ms == "import"
      && marker != null
      && (annotationsOf marker).${kixKeys.importKind} == "StorageClass"
      && (annotationsOf marker).${kixKeys.importName} == "import-sc"
    )
    || throw "optional dependency did not activate the import: ${whoOf ms}, marker ${builtins.toJSON marker}";

  # Nothing resolves to the import, so it stays inactive.
  lib-reference-checks-unused-import-stays-inactive =
    importMarker (activationCluster [ ]) == null || throw "an unused optional import emitted its marker";

  # A mandatory managed instance answers `x`; the import is not the
  # resolution and stays inactive.
  lib-reference-checks-mandatory-provider-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          instances.infra.provider.package = xProvider { who = "managed"; };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "managed" && importMarker ms == null)
    || throw "mandatory provider: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # An optional managed instance that a required dependency activates wins
  # over the import.
  lib-reference-checks-activated-optional-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          instances.infra.x = {
            package = xProvider { who = "managed"; };
            optional = true;
          };
          instances.appns.consumer.package = xConsumer { optional = false; };
        }
      ];
    in
    (whoOf ms == "managed" && importMarker ms == null)
    || throw "activated optional: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # A shelf package pulled for another dependency also answers `x`. The
  # managed, auto-instantiated instance wins over the import.
  lib-reference-checks-auto-instantiated-leaves-import-inactive =
    let
      ms = activationCluster [
        {
          availablePackages.y.package = xProvider {
            who = "auto";
            aliases = [
              "y"
              "x"
            ];
          };
          instances.appns.y-requirer.package = {
            meta.version = "test";
            build =
              {
                self,
                scope,
                y,
                ...
              }:
              {
                cm = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "y-requirer";
                  extra.data.who = y.out.who;
                };
                root = self.cm;
              };
          };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "auto" && importMarker ms == null)
    || throw "auto-instantiated: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # An optional consumer nothing activates places no demand.
  lib-reference-checks-inactive-consumer-activates-nothing =
    importMarker (activationCluster [
      {
        instances.appns.consumer = {
          package = xConsumer { optional = true; };
          optional = true;
        };
      }
    ]) == null
    || throw "an inactive consumer activated the import";

  # deps.x bound to a value other than a ref: the build uses the value,
  # so the import is not activated.
  lib-reference-checks-direct-wiring-activates-nothing =
    let
      ms = activationCluster [
        {
          instances.appns.consumer = {
            package = xConsumer { optional = true; };
            deps.x = {
              out.who = "direct";
            };
          };
        }
      ];
    in
    (whoOf ms == "direct" && importMarker ms == null)
    || throw "direct wiring: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # deps.x = ref.platform.x names the import, which is then active.
  lib-reference-checks-ref-wiring-activates-import =
    let
      ms = activationCluster [
        (
          { ref, ... }:
          {
            instances.infra.provider.package = xProvider { who = "managed"; };
            instances.appns.consumer = {
              package = xConsumer { optional = true; };
              deps.x = ref.platform.x;
            };
          }
        )
      ];
    in
    (whoOf ms == "import" && importMarker ms != null)
    || throw "ref wiring: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";

  # The only managed candidate has meta.scope = "namespace" and sits in
  # another namespace, so resolution skips it and the import answers.
  lib-reference-checks-foreign-namespaced-candidate-activates-import =
    let
      ms = activationCluster [
        {
          instances.other.provider.package = xProvider {
            who = "namespaced";
            scope = "namespace";
          };
          instances.appns.consumer.package = xConsumer { optional = true; };
        }
      ];
    in
    (whoOf ms == "import" && importMarker ms != null)
    || throw "foreign namespace-scoped candidate: ${whoOf ms}, import marker ${builtins.toJSON (importMarker ms)}";
}
