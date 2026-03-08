# cert-manager kix module — migrated from the jetstack cert-manager Helm chart (v1.19.4)
#
# Uses mkChartModule to enforce the chart module contract.
# Source Helm chart: jetstack/cert-manager

{
  lib,
  pkgs,
  config,
  kixlib,
  ...
}:

kixlib.mkChartModule {
  name = "cert-manager";
  inherit lib pkgs config kixlib;
  chartOptions = import ./options.nix;
  resources = import ./resources.nix;
}
