# Tests for the Kubernetes range that tempo declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  packagePath = ../../../packages/experimental/tempo;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (import packagePath {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "tempo";
        namespaceName = "tracing";
      };
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "tempo";
          namespaceName = "tracing";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K2763]") (refusals v);
in
{
  # Tempo's documentation requires Kubernetes 1.25 or later and states no
  # upper bound, so 1.24 is refused and 1.25, 1.37, and a cluster with no
  # version are accepted.
  tempo-k8s-range =
    (refused "1.24" && refusals "1.25" == [ ] && refusals "1.37" == [ ] && refusals null == [ ])
    || throw "tempo-k8s-range: 1.24 ${builtins.toJSON (refusals "1.24")}, 1.25 ${builtins.toJSON (refusals "1.25")}, 1.37 ${builtins.toJSON (refusals "1.37")}";
}
