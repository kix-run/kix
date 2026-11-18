# Tests for the Kubernetes range that metrics-server declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  packagePath = ../../../packages/experimental/metrics-server;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (import packagePath {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "metrics-server";
        namespaceName = "metrics-server";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "metrics-server";
          namespaceName = "metrics-server";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
in
{
  # The compatibility matrix says 1.34 and later, with no upper bound, so
  # 1.33 is refused and 1.34, 1.37, and a cluster with no version are
  # accepted.
  metrics-server-k8s-range =
    (refusals "1.33" != [ ] && refusals "1.34" == [ ] && refusals "1.37" == [ ] && refusals null == [ ])
    || throw "metrics-server-k8s-range: 1.33 ${builtins.toJSON (refusals "1.33")}, 1.34 ${builtins.toJSON (refusals "1.34")}, 1.37 ${builtins.toJSON (refusals "1.37")}";
}
