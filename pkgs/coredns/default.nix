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
#   - Service (metrics, optional — behind prometheus.service.enabled)
#   - ServiceMonitor (optional — behind prometheus.monitor.enabled)
#
# When the cross-cutting monitoring module is active (monitoring.enabled = true),
# the per-chart ServiceMonitor is suppressed in favor of the centralized one.

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
