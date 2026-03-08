# CoreDNS kix module — migrated from the coredns Helm chart (v1.45.0, appVersion 1.13.1)
#
# Source Helm chart stored at: charts/coredns/ for reference and parity testing.
#
# Split into:
#   options.nix   — all option declarations (the API surface)
#   resources.nix — resource construction, helpers, and config wiring
#
# Resources produced:
#   - ServiceAccount (optional, behind serviceAccount.create)
#   - ClusterRole + ClusterRoleBinding
#   - ConfigMap (Corefile + zone files)
#   - Deployment
#   - Service
#
# ServiceMonitor is handled via Level 3 monitoring.targets (see resources.nix).

{
  lib,
  ...
}:

{
  imports = [
    ./options.nix
    ./resources.nix
  ];
}
