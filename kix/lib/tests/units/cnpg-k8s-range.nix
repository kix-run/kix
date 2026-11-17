# Tests for the Kubernetes range that cnpg-operator declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  operatorPackage = import ../../../packages/stable/cnpg-operator;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (operatorPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "cnpg-operator";
        namespaceName = "cnpg-system";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "cnpg-operator";
          namespaceName = "cnpg-system";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K4963]") (refusals v);
in
{
  # Tested-only versions (1.33, 1.37) and any version outside the supported
  # range are refused with the record's id. The supported versions (1.34,
  # 1.36) are accepted, and so is a cluster with no version.
  cnpg-k8s-range =
    (
      refused "1.33"
      && refused "1.37"
      && refusals "1.34" == [ ]
      && refusals "1.36" == [ ]
      && refusals null == [ ]
    )
    || throw "cnpg-k8s-range: 1.33 ${builtins.toJSON (refusals "1.33")}, 1.37 ${builtins.toJSON (refusals "1.37")}, 1.34 ${builtins.toJSON (refusals "1.34")}, 1.36 ${builtins.toJSON (refusals "1.36")}";
}
