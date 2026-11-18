# Tests for the Kubernetes range that spegel declares in meta.k8s. The meta
# check runs directly, because a failed meta assertion fails the cluster
# before its messages can be read.

{ lib, kixlib, ... }:

let
  spegelPackage = import ../../../packages/experimental/spegel;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (spegelPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "spegel";
        namespaceName = "spegel";
      };
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "spegel";
          namespaceName = "spegel";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K8826]") (refusals v);
in
{
  # Versions below 1.35 and above 1.37 are refused with the change record's
  # id. Patch releases inside the range and a cluster with no version are
  # accepted.
  spegel-k8s-range =
    (
      refused "1.34"
      && refused "1.38.0"
      && refusals "1.35.0" == [ ]
      && refusals "1.37.4" == [ ]
      && refusals null == [ ]
    )
    || throw "spegel-k8s-range: 1.34 ${builtins.toJSON (refusals "1.34")}, 1.38.0 ${builtins.toJSON (refusals "1.38.0")}, 1.35.0 ${builtins.toJSON (refusals "1.35.0")}, 1.37.4 ${builtins.toJSON (refusals "1.37.4")}";
}
