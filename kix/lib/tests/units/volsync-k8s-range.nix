# Tests for the Kubernetes range that volsync declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  packagePath = ../../../packages/experimental/volsync;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (import packagePath {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "volsync";
        namespaceName = "volsync";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "volsync";
          namespaceName = "volsync";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );

  refused = v: builtins.any (lib.hasInfix "supports Kubernetes 1.20 or later") (refusals v);
in
{
  # Upstream states 1.20 and later, with no upper bound. Kix needs 1.27 for
  # the mover network policies, so 1.26 is refused with the reason, and
  # 1.27, 1.38, and a cluster with no version are accepted.
  volsync-k8s-range =
    (refused "1.26" && refusals "1.27" == [ ] && refusals "1.38" == [ ] && refusals null == [ ])
    || throw "volsync-k8s-range: 1.26 ${builtins.toJSON (refusals "1.26")}, 1.27 ${builtins.toJSON (refusals "1.27")}, 1.38 ${builtins.toJSON (refusals "1.38")}";
}
