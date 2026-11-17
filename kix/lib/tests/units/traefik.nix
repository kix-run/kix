# Tests for the traefik package's meta.k8s range.

{
  lib,
  kixlib,
  ...
}:

let
  traefikPackage = import ../../../packages/experimental/traefik;
  metaLib = import ../../meta.nix { inherit lib; };
in
let
  meta =
    (traefikPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "traefik";
        namespaceName = "gateway-system";
      };
      availability = "none";
    }).meta;
  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "traefik";
          namespaceName = "gateway-system";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K1871]") (refusals v);
in
{
  # A cluster that declares a Kubernetes version Traefik does not support is
  # refused with the change record's id. The meta check is called directly,
  # because a failed meta assertion fails the cluster before its messages
  # can be read.
  traefik-k8s-range =
    (
      refused "1.33"
      && refused "1.38.0"
      && refusals "1.34.3" == [ ]
      && refusals "1.37" == [ ]
      && refusals null == [ ]
    )
    || throw "traefik k8s range: 1.33 ${builtins.toJSON (refusals "1.33")}, 1.38.0 ${builtins.toJSON (refusals "1.38.0")}, 1.34.3 ${builtins.toJSON (refusals "1.34.3")}";
}
