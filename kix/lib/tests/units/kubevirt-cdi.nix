# Tests for the kix/lib behaviour the kubevirt-cdi rework relies on:
# kix.operandPolicy, the network policy for pods an operator creates.

{
  lib,
  kixKeys,
  mkCluster,
  netpolOn,
  manifests,
  byName,
  ...
}:

let
  operandSpec = {
    endpointSelector.matchLabels.app = "operand";
    ingress = [ { fromEndpoints = [ { matchLabels.app = "operand"; } ]; } ];
  };

  # Renders a ConfigMap standing in for a custom resource, and a policy for
  # the pods an operator would create from it.
  operandPackage =
    { kix, ... }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          cr = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "operand-cr";
          };
          peers = kix.operandPolicy {
            inherit scope;
            name = "operand-peers";
            spec = operandSpec;
          };
          root = {
            resource = self.cr;
            requires = lib.optional (self.peers != null) self.peers;
          };
        };
    };

  instance = {
    instances.app.operand.package = operandPackage;
  };

  policyIn = cluster: byName "operand-peers" (manifests cluster);
in
{
  # Without network policy the helper returns null and nothing renders.
  # With an enforcer the policy carries the name, the derived and
  # policy-type labels, and the spec as given.
  kubevirt-cdi-operand-policy =
    let
      off = policyIn (mkCluster [ instance ]);
      on = policyIn (mkCluster [
        instance
        netpolOn
      ]);
      labels = on.metadata.labels or { };
    in
    (
      off == null
      && on != null
      && on.kind == "CiliumNetworkPolicy"
      && on.metadata.namespace == "app"
      && labels.${kixKeys.derived} or null == "true"
      && labels.${kixKeys.policyType} or null == "operator-managed-workload"
      && on.spec == operandSpec
    )
    || throw "kix.operandPolicy: without enforcer ${builtins.toJSON off}, with enforcer ${builtins.toJSON on}";
}
