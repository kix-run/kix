# Tests for the Kubernetes range that openbao declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  openbaoPackage = import ../../../packages/experimental/openbao;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (openbaoPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "openbao";
        namespaceName = "secrets";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "openbao";
          namespaceName = "secrets";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K6360]") (refusals v);
in
{
  # Versions below and above the three most recent minor releases are
  # refused with the record's id. The supported versions 1.35 and 1.37 are
  # accepted, and so is a cluster with no version.
  openbao-k8s-range =
    (
      refused "1.34"
      && refused "1.38"
      && refusals "1.35" == [ ]
      && refusals "1.37" == [ ]
      && refusals null == [ ]
    )
    || throw "openbao-k8s-range: 1.34 ${builtins.toJSON (refusals "1.34")}, 1.38 ${builtins.toJSON (refusals "1.38")}, 1.35 ${builtins.toJSON (refusals "1.35")}, 1.37 ${builtins.toJSON (refusals "1.37")}";
}
