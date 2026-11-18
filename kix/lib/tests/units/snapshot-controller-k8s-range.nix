# Tests for the Kubernetes range that snapshot-controller declares in
# meta.k8s. The meta check runs directly, because a failed meta assertion
# fails the cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  snapshotControllerPackage = import ../../../packages/experimental/snapshot-controller;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (snapshotControllerPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "snapshot-controller";
        namespaceName = "storage";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "snapshot-controller";
          namespaceName = "storage";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "supports Kubernetes 1.25 and later") (refusals v);
in
{
  # Upstream states a minimum (1.25) and no maximum. A version below it is
  # refused with the reason. The minimum, a current version, a version
  # newer than any release, and a cluster with no version are accepted.
  snapshot-controller-k8s-range =
    (
      refused "1.24.9"
      && refusals "1.25" == [ ]
      && refusals "1.36.1" == [ ]
      && refusals "1.99" == [ ]
      && refusals null == [ ]
    )
    || throw "snapshot-controller-k8s-range: 1.24.9 ${builtins.toJSON (refusals "1.24.9")}, 1.25 ${builtins.toJSON (refusals "1.25")}, 1.36.1 ${builtins.toJSON (refusals "1.36.1")}, 1.99 ${builtins.toJSON (refusals "1.99")}";
}
