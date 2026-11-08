# Tests for the architecture.controllerRequiresCrds scorecard rule, which
# warns when a package defines CustomResourceDefinitions and runs a workload,
# but no workload depends on the definitions.

{
  lib,
  mkCluster,
  containerBase,
  ...
}:

let
  rules = import ../../rules { inherit lib; };

  widgetCrd =
    scope:
    scope.mkCRD {
      spec = {
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
    };

  controller =
    scope: requires:
    scope.mkDeployment {
      name = "op";
      inherit requires;
      spec = {
        selector.matchLabels.app = "op";
        template.spec.containers = [
          (
            containerBase
            // {
              name = "op";
              image = "example.test/op:1";
            }
          )
        ];
      };
    };

  # An operator that lists its CRD only in root.requires.
  unordered = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        crds.widgets = widgetCrd scope;
        deployment = controller scope [ ];
        root = {
          resource = self.deployment;
          requires = [ self.crds.widgets ];
        };
      };
  };

  # The same operator with the controller depending on the CRD.
  ordered = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        crds.widgets = widgetCrd scope;
        deployment = controller scope (builtins.attrValues self.crds);
        root = self.deployment;
      };
  };

  # A package that ships a definition for a controller that runs elsewhere.
  crdOnly = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        crds.widgets = widgetCrd scope;
        root = self.crds.widgets;
      };
  };

  findingsOf =
    package:
    builtins.filter (f: lib.hasSuffix "controllerRequiresCrds" (f.rule or ""))
      ((mkCluster [
        {
          scorecard = {
            enable = true;
            rules.architecture = rules.architecture;
          };
          instances.a.op.package = package;
        }
      ]).scorecardReport or {
        findings = [ ];
      }
      ).findings;

in
{
  controller-requires-crds-warns-on-root-requires-only =
    let
      findings = findingsOf unordered;
      message = (builtins.head findings).message;
    in
    (
      builtins.length findings == 1
      && (builtins.head findings).severity == "warning"
      && lib.hasInfix "defines the CustomResourceDefinitions widgets.example.test and runs Deployment/op" message
      && lib.hasInfix "no workload depends on those definitions" message
      && lib.hasInfix "root.requires does not order the controller after them" message
    )
    || throw "root.requires only: ${builtins.toJSON findings}";

  controller-requires-crds-silent-when-workload-requires-crd =
    findingsOf ordered == [ ]
    || throw "ordered operator flagged: ${builtins.toJSON (findingsOf ordered)}";

  controller-requires-crds-silent-for-crd-only-package =
    findingsOf crdOnly == [ ]
    || throw "CRD-only package flagged: ${builtins.toJSON (findingsOf crdOnly)}";
}
