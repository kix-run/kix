# Tests for the Kubernetes range that reloader declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  reloaderPackage = import ../../../packages/experimental/reloader;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (reloaderPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "reloader";
        namespaceName = "reloader";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "reloader";
          namespaceName = "reloader";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K8986]") (refusals v);
in
{
  # The range is open: 1.19 is the first version reloader supports, and
  # every later one is accepted. A cluster with no version is accepted too.
  reloader-k8s-range =
    (
      refused "1.18"
      && refusals "1.19" == [ ]
      && refusals "1.34" == [ ]
      && refusals "1.37.0" == [ ]
      && refusals null == [ ]
    )
    || throw "reloader-k8s-range: 1.18 ${builtins.toJSON (refusals "1.18")}, 1.19 ${builtins.toJSON (refusals "1.19")}, 1.34 ${builtins.toJSON (refusals "1.34")}, 1.37.0 ${builtins.toJSON (refusals "1.37.0")}";
}
