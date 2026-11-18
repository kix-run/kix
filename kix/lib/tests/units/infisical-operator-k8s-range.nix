# Tests for the Kubernetes range that infisical-operator declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  packagePath = ../../../packages/experimental/infisical-operator;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (import packagePath {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "infisical-operator";
        namespaceName = "infisical";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "infisical-operator";
          namespaceName = "infisical";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
in
{
  # Upstream's documentation lists Kubernetes 1.29 through 1.33 as supported.
  # 1.28 and 1.34 are refused, 1.29, 1.31, and 1.33 are accepted, and a
  # cluster with no version is accepted.
  infisical-operator-k8s-range =
    (
      refusals "1.28" != [ ]
      && refusals "1.29" == [ ]
      && refusals "1.31" == [ ]
      && refusals "1.33" == [ ]
      && refusals "1.34" != [ ]
      && refusals null == [ ]
    )
    || throw "infisical-operator-k8s-range: 1.28 ${builtins.toJSON (refusals "1.28")}, 1.29 ${builtins.toJSON (refusals "1.29")}, 1.33 ${builtins.toJSON (refusals "1.33")}, 1.34 ${builtins.toJSON (refusals "1.34")}";
}
