# Valkey kix module — migrated from the Bitnami valkey Helm chart (v3.0.2, appVersion 8.1.1)
#
# Uses mkChartModule to enforce the chart module contract.
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey

{
  lib,
  pkgs,
  config,
  kixlib,
  ...
}:

kixlib.mkChartModule {
  name = "valkey";
  inherit
    lib
    pkgs
    config
    kixlib
    ;
  chartOptions = import ./options.nix;
  resources = import ./resources.nix;
}
