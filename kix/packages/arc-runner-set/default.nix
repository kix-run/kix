# GitHub Actions Runner Scale Set — wraps the upstream gha-runner-scale-set chart.
#
# One instance per AutoscalingRunnerSet. The runner-scale-set controller
# (deployed separately by the `arc` package) reconciles these CRs into
# listener Deployments and ephemeral runner Pods.
#
# Chart:   oci://ghcr.io/actions/actions-runner-controller-charts
# Name:    gha-runner-scale-set
# Version: 0.14.2

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "oci://ghcr.io/actions/actions-runner-controller-charts";
    name = "gha-runner-scale-set";
    version = "0.14.2";
    hash = "sha256-Gi0QTlVIbK03Opwz8879CyaM1Wd0PlfqXajh3fdeDMA=";
  };

  defaultValues = { };
in
{
  meta = {
    version = "0.14.2";
    description = "A GitHub Actions runner scale set from the upstream gha-runner-scale-set chart, reconciled by the arc controller";
    owner = "platform";
    isHelm = true;
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = scope.instanceName;
      };
    in
    resources.mkParts {
      root = builtins.head (resources.byKind "AutoscalingRunnerSet");
    };
}
