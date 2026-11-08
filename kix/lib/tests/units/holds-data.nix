# Tests for `kix.run/holds-data`: the `holdsData` declaration on
# scope.mkCRD and scope.mkCRDRef, the mark built-in kinds get from their
# shape (`holdsDataOf`), and the build check that refuses a stateful
# package's custom resources whose kind declares no `holdsData`.

{
  lib,
  k8s,
  kixKeys,
  mkCluster,
  manifests,
  byName,
  evalFails,
  ...
}:

let
  # A package that declares a Gadget CRD and references a Widget CRD, with
  # `gadget` and `widget` merged into each declaration, and builds one of
  # each. `lifecycle` is the package's meta.lifecycle.
  gadgetsPackage =
    {
      gadget ? { },
      widget ? { },
      lifecycle ? null,
      unsafe ? [ ],
      extraParts ? _: { },
    }:
    {
      meta = {
        version = "test";
        inherit unsafe;
      }
      // lib.optionalAttrs (lifecycle != null) { inherit lifecycle; };
      build =
        { self, scope, ... }:
        {
          gadgetCrd = scope.mkCRD (
            {
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
                ];
              };
            }
            // gadget
          );
          widgetCrd = scope.mkCRDRef (
            {
              group = "example.com";
              kind = "Widget";
              plural = "widgets";
              version = "v1";
            }
            // widget
          );
          gadgetCr = scope.mkCR self.gadgetCrd { name = "g"; };
          widgetCr = scope.mkCR self.widgetCrd { name = "w"; };
          root = self.gadgetCrd;
        }
        // extraParts scope;
    };

  build =
    pkg:
    mkCluster [
      {
        namespaces.app = { };
        instances.app.gadgets.package = pkg;
      }
    ];

  markOf = name: ms: ((byName name ms).metadata.annotations or { }).${kixKeys.holdsData} or null;

  builds = cluster: builtins.deepSeq (manifests cluster) true;

  declared = {
    gadget.holdsData = true;
    widget.holdsData = false;
  };
in
{
  # A declared kind's custom resources carry its answer as "true" or "false".
  holds-data-declared-crd =
    let
      ms = manifests (build (gadgetsPackage declared));
    in
    (markOf "g" ms == "true" && markOf "w" ms == "false")
    || throw "unexpected marks: g=${toString (markOf "g" ms)} w=${toString (markOf "w" ms)}";

  # Volume claims, volumes, and StatefulSets with claim templates are marked
  # "true". Other built-in kinds are left unmarked.
  holds-data-built-in-shapes =
    let
      of =
        apiVersion: kind: spec:
        k8s.holdsDataOf null { inherit apiVersion kind spec; };
      pvcCluster = build (gadgetsPackage {
        inherit (declared) gadget widget;
        unsafe = [ "raw-pvc" ];
        extraParts = scope: {
          claim = scope.mkResource {
            apiVersion = "v1";
            kind = "PersistentVolumeClaim";
            name = "data";
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = "1Gi";
            };
          };
          settings = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "settings";
            extra.data.a = "b";
          };
        };
      });
      ms = manifests pvcCluster;
    in
    (
      of "v1" "PersistentVolumeClaim" { } == true
      && of "v1" "PersistentVolume" { } == true
      && of "apps/v1" "StatefulSet" { volumeClaimTemplates = [ { metadata.name = "data"; } ]; } == true
      && of "apps/v1" "StatefulSet" { volumeClaimTemplates = [ ]; } == null
      && of "apps/v1" "StatefulSet" { } == null
      && of "apps/v1" "Deployment" { } == null
      && of "v1" "Secret" { } == null
      &&
        k8s.holdsDataOf false {
          apiVersion = "example.com/v1";
          kind = "Gadget";
        } == false
      && markOf "data" ms == "true"
      && markOf "settings" ms == null
    )
    || throw "a built-in kind was marked wrongly";

  # A stateful package that renders a custom resource of a kind without
  # `holdsData` fails to build. The same package with both kinds declared
  # builds, and so does an undeclared one that is not stateful.
  holds-data-stateful-refuses-undeclared =
    (
      evalFails (
        build (gadgetsPackage {
          lifecycle = "stateful";
        })
      )
      && evalFails (
        build (gadgetsPackage {
          lifecycle = "stateful";
          inherit (declared) gadget;
        })
      )
      && builds (build (gadgetsPackage (declared // { lifecycle = "stateful"; })))
    )
    || throw "a stateful package's undeclared custom resource was not refused, or a declared one was";

  # A custom resource built with scope.mkResource carries no declaration, even
  # when its kind's mkCRDRef has one, so a stateful package that renders one
  # is refused.
  holds-data-stateful-refuses-raw-custom-resource =
    let
      withRaw =
        lifecycle:
        build (
          gadgetsPackage (
            declared
            // {
              inherit lifecycle;
              extraParts = scope: rec {
                probeCrd = scope.mkCRDRef {
                  group = "monitoring.example.com";
                  kind = "Probe";
                  plural = "probes";
                  version = "v1";
                  holdsData = false;
                };
                monitor = scope.mkResource {
                  apiVersion = "monitoring.example.com/v1";
                  kind = "Probe";
                  name = "probe";
                  spec = { };
                  requires = [ probeCrd ];
                };
              };
            }
          )
        );
    in
    (evalFails (withRaw "stateful") && builds (withRaw "ephemeral"))
    || throw "a raw custom resource in a stateful package was not refused, or one in an ephemeral package was";

  # A non-stateful package needs no declaration, and its undeclared custom
  # resources stay unmarked.
  holds-data-non-stateful-not-refused =
    let
      ms = manifests (build (gadgetsPackage { }));
    in
    (markOf "g" ms == null && markOf "w" ms == null)
    || throw "an undeclared custom resource in a non-stateful package was marked";

  # `holdsData` is a boolean.
  holds-data-rejects-non-boolean =
    (
      evalFails (
        build (gadgetsPackage {
          gadget.holdsData = "yes";
        })
      )
      && evalFails (
        build (gadgetsPackage {
          widget.holdsData = 1;
        })
      )
      && builds (build (gadgetsPackage declared))
    )
    || throw "a non-boolean holdsData was accepted";

  # scope.mkResource takes no `holdsData`, for a built-in kind or a custom
  # one. It is declared per kind on mkCRD or mkCRDRef.
  holds-data-scope-mk-resource-refuses-it =
    let
      withPart =
        part:
        build (
          gadgetsPackage (
            declared
            // {
              extraParts = scope: rec {
                probeCrd = scope.mkCRDRef {
                  group = "monitoring.example.com";
                  kind = "Probe";
                  plural = "probes";
                  version = "v1";
                  holdsData = false;
                };
                extra = part probeCrd scope;
              };
            }
          )
        );
      configMap =
        args: _: scope:
        scope.mkResource (
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "settings";
            extra.data.a = "b";
          }
          // args
        );
      probe =
        args: probeCrd: scope:
        scope.mkResource (
          {
            apiVersion = "monitoring.example.com/v1";
            kind = "Probe";
            name = "probe";
            requires = [ probeCrd ];
          }
          // args
        );
      viaMkCR =
        args: probeCrd: scope:
        scope.mkCR probeCrd ({ name = "probe"; } // args);
    in
    (
      evalFails (
        withPart (configMap {
          holdsData = true;
        })
      )
      && builds (withPart (configMap { }))
      && evalFails (
        withPart (probe {
          holdsData = true;
        })
      )
      && builds (withPart (probe { }))
      && evalFails (
        withPart (viaMkCR {
          holdsData = true;
        })
      )
      && builds (withPart (viaMkCR { }))
    )
    || throw "scope.mkResource or mkCR accepted a holdsData argument, or refused an object without one";

  # Kinds in the groups Kix treats as built-in (`core/api-groups.json`) take
  # their mark from their shape, so a declaration for one is refused,
  # `networking.k8s.io` included.
  holds-data-refuses-built-in-groups =
    let
      withRef =
        group: holdsData:
        build (
          gadgetsPackage (
            declared
            // {
              extraParts = scope: rec {
                ref = scope.mkCRDRef (
                  {
                    inherit group;
                    kind = "Snapshot";
                    plural = "snapshots";
                    version = "v1";
                  }
                  // lib.optionalAttrs (holdsData != null) { inherit holdsData; }
                );
                snapshot = scope.mkCR ref { name = "s"; };
              };
            }
          )
        );
      direct =
        apiVersion:
        k8s.mkResource {
          inherit apiVersion;
          kind = "Ingress";
          name = "i";
          namespace = "app";
          _crd = {
            declaredBy = "a test";
            holdsData = true;
          };
        };
      seals = r: (builtins.tryEval (builtins.deepSeq r.rawManifest true)).success;
    in
    (
      evalFails (withRef "snapshot.storage.k8s.io" true)
      && builds (withRef "snapshot.storage.k8s.io" null)
      && builds (withRef "snapshot.example.com" true)
      && !(seals (direct "networking.k8s.io/v1"))
      && !(seals (direct "apps/v1"))
      && seals (direct "example.com/v1")
    )
    || throw "holdsData was accepted for a built-in group, or refused for a custom one";

  # The group list is shared with the CLI's `is_known_api`.
  holds-data-built-in-groups =
    (
      !(k8s.facts.isForeignGroup "v1")
      && !(k8s.facts.isForeignGroup "apps/v1")
      && !(k8s.facts.isForeignGroup "networking.k8s.io/v1")
      && !(k8s.facts.isForeignGroup "gateway.networking.k8s.io/v1")
      && !(k8s.facts.isForeignGroup (import ../../core/annotations.nix).apiVersion)
      && k8s.facts.isForeignGroup "postgresql.cnpg.io/v1"
      && k8s.facts.isForeignGroup "extensions/v1beta1"
    )
    || throw "isForeignGroup drew the built-in boundary wrongly";
}
