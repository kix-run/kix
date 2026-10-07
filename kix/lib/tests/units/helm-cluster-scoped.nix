# Tests for the built-in cluster-scoped kinds a chart renders: helm.nix
# gives them no namespace, since the API server ignores one on them.
# Loaded by ../default.nix with the other files in this directory.

{
  lib,
  publicKix,
  mkCluster,
  baseInstances,
  manifests,
  ...
}:

let
  chartPackage = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        binding = publicKix.wrapHelmResource {
          inherit scope;
          resource = {
            apiVersion = "admissionregistration.k8s.io/v1";
            kind = "ValidatingAdmissionPolicyBinding";
            metadata.name = "chart-binding";
            spec = {
              policyName = "chart-policy";
              validationActions = [ "Deny" ];
            };
          };
        };
        root = self.binding;
      };
  };

  binding = lib.findFirst (m: (m.metadata.name or "") == "chart-binding") null (
    manifests (mkCluster [
      baseInstances
      { instances.infra.chart.package = chartPackage; }
    ])
  );
in
{
  helm-cluster-scoped-kind-has-no-namespace =
    (binding != null && !(binding.metadata ? namespace))
    || throw "chart ValidatingAdmissionPolicyBinding: ${builtins.toJSON (binding.metadata or null)}";
}
