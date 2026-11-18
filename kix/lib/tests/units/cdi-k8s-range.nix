# Tests for the Kubernetes range that cdi declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  cdiPackage = import ../../../packages/experimental/cdi;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (cdiPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "cdi";
        namespaceName = "cdi";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "cdi";
          namespaceName = "cdi";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K6643]") (refusals v);
in
{
  # Versions outside the range CDI's end-to-end lanes run (1.34, 1.37.0) are
  # refused with the record's id. The tested versions (1.35, 1.36.1) are
  # accepted, and so is a cluster with no version.
  cdi-k8s-range =
    (
      refused "1.34"
      && refused "1.37.0"
      && refusals "1.35" == [ ]
      && refusals "1.36.1" == [ ]
      && refusals null == [ ]
    )
    || throw "cdi-k8s-range: 1.34 ${builtins.toJSON (refusals "1.34")}, 1.37.0 ${builtins.toJSON (refusals "1.37.0")}, 1.35 ${builtins.toJSON (refusals "1.35")}, 1.36.1 ${builtins.toJSON (refusals "1.36.1")}";
}
