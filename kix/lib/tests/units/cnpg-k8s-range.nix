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
  # Below the range (1.30) and above it (1.38) are refused with the record's
  # id. Inside it (1.34.3) is accepted, and so is a cluster with no version.
  cnpg-k8s-range =
    (refused "1.30" && refused "1.38.0" && refusals "1.34.3" == [ ] && refusals null == [ ])
    || throw "cnpg-k8s-range: 1.30 ${builtins.toJSON (refusals "1.30")}, 1.38.0 ${builtins.toJSON (refusals "1.38.0")}, 1.34.3 ${builtins.toJSON (refusals "1.34.3")}";
}
