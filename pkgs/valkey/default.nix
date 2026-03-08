# Valkey kix module — migrated from the Bitnami valkey Helm chart (v3.0.2, appVersion 8.1.1)
#
# Source Helm chart: oci://registry-1.docker.io/bitnamicharts/valkey
#
# Split into:
#   options.nix   — all option declarations (the API surface)
#   resources.nix — resource construction, helpers, and config wiring
#
# This module produces Kubernetes resources for Valkey in two modes:
#
# 1. REPLICATION MODE (default, sentinel.enabled = false):
#    - Primary StatefulSet (1 replica)
#    - Replica StatefulSet (N replicas)
#    - Primary Service, Replica Service, Headless Service
#    - 2 ServiceAccounts (primary, replica)
#    - 3 ConfigMaps (configuration, health scripts, start scripts)
#
# 2. SENTINEL MODE (sentinel.enabled = true):
#    - Single "node" StatefulSet with 3 containers (valkey, sentinel, metrics)
#    - Sentinel Service, Headless Service
#    - 1 ServiceAccount (shared)
#    - 3 ConfigMaps (configuration, health scripts, start scripts)
#
# Optional resources (behind enable flags, both modes):
#    - PodDisruptionBudget
#    - NetworkPolicy
#    - Metrics Service + ServiceMonitor (requires metrics.enabled)

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
