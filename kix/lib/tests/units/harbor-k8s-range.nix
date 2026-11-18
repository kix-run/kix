# Tests for the Kubernetes range that harbor declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  packagePath = ../../../packages/stable/harbor;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (import packagePath {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "harbor";
        namespaceName = "harbor";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "harbor";
          namespaceName = "harbor";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );

  refused = v: builtins.any (lib.hasInfix "[K5312]") (refusals v);
in
{
  # Upstream states 1.20 and later, with no upper bound, so 1.19 is refused
  # with the change record's id, and 1.20, 1.38, and a cluster with no
  # version are accepted.
  harbor-k8s-range =
    (refused "1.19" && refusals "1.20" == [ ] && refusals "1.38" == [ ] && refusals null == [ ])
    || throw "harbor-k8s-range: 1.19 ${builtins.toJSON (refusals "1.19")}, 1.20 ${builtins.toJSON (refusals "1.20")}, 1.38 ${builtins.toJSON (refusals "1.38")}";
}
