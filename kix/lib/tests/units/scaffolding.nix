# Tests for how kix/lib/eval/view.nix builds a package's view.

{
  lib,
  mkCluster,
  manifests,
  ofKind,
  namesOf,
  hasName,
  ...
}:

let
  # A package with both a `crds.*` parts folder and `out.crds`, as an
  # operator that vendors its CRDs and hands consumers builders keyed by Kind.
  fooOperatorPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        crds.fooThings = scope.mkCRD {
          spec = {
            group = "example.com";
            names = {
              kind = "FooThing";
              plural = "foothings";
              singular = "foothing";
              listKind = "FooThingList";
            };
            scope = "Namespaced";
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
        };
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "foo-operator";
        };
        root = {
          resource = self.cm;
          requires = [ self.crds.fooThings ];
          out.crds.FooThing = self.crds.fooThings;
        };
      };
  };

  # Builds a FooThing from the operator's `out.crds`.
  fooConsumerPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        fooOperator,
        ...
      }:
      {
        thing = scope.mkCR fooOperator.out.crds.FooThing {
          name = "my-thing";
          spec.size = 1;
        };
        root = self.thing;
      };
  };
in
{
  # A `crds` parts folder and `out.crds` on one package: the build
  # evaluates, the view's `crds` is `out.crds`, the CRD is still emitted, and
  # a consumer builds a CR from `out.crds.FooThing`.
  scaffolding-out-crds-beside-crds-folder =
    let
      cluster = mkCluster [
        {
          instances.ops.fooOperator.package = fooOperatorPackage;
          instances.ops.consumer.package = fooConsumerPackage;
        }
      ];
      ms = manifests cluster;
      view = cluster.instances.ops.fooOperator;
      crdNames = namesOf (ofKind "CustomResourceDefinition" ms);
    in
    (
      view.out.crds ? FooThing
      && view.crds ? FooThing
      && !(view.crds ? fooThings)
      && builtins.elem "foothings.example.com" crdNames
      && hasName "my-thing" (ofKind "FooThing" ms)
    )
    || throw "out.crds beside a crds folder: view.crds keys ${builtins.toJSON (builtins.attrNames view.crds)}, CRDs ${builtins.toJSON crdNames}, manifests ${builtins.toJSON (namesOf ms)}";
}
