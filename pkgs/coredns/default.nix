# CoreDNS kix module — migrated from the coredns Helm chart (v1.45.0, appVersion 1.13.1)
#
# Uses mkChartModule to enforce the chart module contract:
#   - options.nix returns chart-specific options (enable/namespace/clusterDomain added by contract)
#   - resources.nix returns { manifestList, extraConfig }
#
# Source Helm chart stored at: charts/coredns/ for reference and parity testing.

{
  lib,
  pkgs,
  config,
  kixlib,
  ...
}:

kixlib.mkChartModule {
  name = "coredns";
  inherit lib pkgs config kixlib;
  chartOptions = import ./options.nix;
  resources = import ./resources.nix;
}
