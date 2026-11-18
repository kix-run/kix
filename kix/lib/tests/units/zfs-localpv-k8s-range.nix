# Tests for the Kubernetes range that zfs-localpv declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  zfsPackage = import ../../../packages/experimental/zfs-localpv;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (zfsPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "zfs-localpv";
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
          instanceName = "zfs-localpv";
          namespaceName = "storage";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "supports Kubernetes 1.23") (refusals v);
in
{
  # Upstream's README states Kubernetes 1.23 and later, with no upper bound.
  # 1.22 is refused. 1.23 and a release past the range's tested lanes are
  # accepted, and so is a cluster with no version.
  zfs-localpv-k8s-range =
    (refused "1.22" && refusals "1.23" == [ ] && refusals "1.37.0" == [ ] && refusals null == [ ])
    || throw "zfs-localpv-k8s-range: 1.22 ${builtins.toJSON (refusals "1.22")}, 1.23 ${builtins.toJSON (refusals "1.23")}, 1.37.0 ${builtins.toJSON (refusals "1.37.0")}";
}
