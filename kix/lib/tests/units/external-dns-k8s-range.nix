# Tests for the Kubernetes range that external-dns declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  ednsPackage = import ../../../packages/experimental/external-dns;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (ednsPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "external-dns";
        namespaceName = "external-dns";
      };
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "external-dns";
          namespaceName = "external-dns";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K3140]") (refusals v);
in
{
  # A version below 1.21 is refused with the record's id. Upstream states no
  # upper bound, so 1.21, a current version, and a much later one are
  # accepted, and so is a cluster with no version.
  external-dns-k8s-range =
    (
      refused "1.20"
      && refusals "1.21" == [ ]
      && refusals "1.36" == [ ]
      && refusals "1.40" == [ ]
      && refusals null == [ ]
    )
    || throw "external-dns-k8s-range: 1.20 ${builtins.toJSON (refusals "1.20")}, 1.21 ${builtins.toJSON (refusals "1.21")}, 1.36 ${builtins.toJSON (refusals "1.36")}, 1.40 ${builtins.toJSON (refusals "1.40")}";
}
