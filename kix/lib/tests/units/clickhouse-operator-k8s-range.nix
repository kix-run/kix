# Tests for the Kubernetes range that clickhouse-operator declares in
# meta.k8s. The meta check runs directly, because a failed meta assertion
# fails the cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  operatorPackage = import ../../../packages/experimental/clickhouse-operator;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (operatorPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "clickhouse-operator";
        namespaceName = "clickhouse-system";
      };
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "clickhouse-operator";
          namespaceName = "clickhouse-system";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "Kubernetes 1.25 and later") (refusals v);
in
{
  # A version below 1.25 is refused with the reason. Upstream states no
  # upper bound, so 1.25, a current version, and a much later one are
  # accepted, and so is a cluster with no version.
  clickhouse-operator-k8s-range =
    (
      refused "1.24"
      && refusals "1.25" == [ ]
      && refusals "1.34" == [ ]
      && refusals "1.40" == [ ]
      && refusals null == [ ]
    )
    || throw "clickhouse-operator-k8s-range: 1.24 ${builtins.toJSON (refusals "1.24")}, 1.25 ${builtins.toJSON (refusals "1.25")}, 1.34 ${builtins.toJSON (refusals "1.34")}, 1.40 ${builtins.toJSON (refusals "1.40")}";
}
