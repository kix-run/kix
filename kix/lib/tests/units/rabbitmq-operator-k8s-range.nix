# Tests for the Kubernetes range that rabbitmq-operator declares in meta.k8s.
# The meta check runs directly, because a failed meta assertion fails the
# cluster before its messages can be read.

{ lib, kixlib, ... }:

let
  operatorPackage = import ../../../packages/experimental/rabbitmq-operator;
  metaLib = import ../../meta.nix { inherit lib; };

  meta =
    (operatorPackage {
      inherit lib;
      kix = kixlib;
      scope = {
        instanceName = "rabbitmq-operator";
        namespaceName = "rabbitmq-system";
      };
      availability = "none";
    }).meta;

  refusals =
    k8sVersion:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        (metaLib.checkMetaStatic {
          packageMeta = meta;
          instanceName = "rabbitmq-operator";
          namespaceName = "rabbitmq-system";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        }).assertions
      )
    );
  refused = v: builtins.any (lib.hasInfix "[K5618]") (refusals v);
in
{
  # The README's Compatibility section requires Kubernetes 1.31 or later and
  # states no upper bound, so 1.30 is refused with the record's id, and 1.31
  # and 1.34 (the production version) are accepted. A cluster with no
  # version is not checked.
  rabbitmq-operator-k8s-range =
    (
      refused "1.30"
      && refused "1.25"
      && refusals "1.31" == [ ]
      && refusals "1.34" == [ ]
      && refusals null == [ ]
    )
    || throw "rabbitmq-operator-k8s-range: 1.30 ${builtins.toJSON (refusals "1.30")}, 1.31 ${builtins.toJSON (refusals "1.31")}, 1.34 ${builtins.toJSON (refusals "1.34")}";
}
