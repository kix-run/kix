# 2026-11-26 · `kix/lib/plugins/netpol/derive.nix` · The hostNetwork warning says CiliumNetworkPolicy on clusters that write NetworkPolicy.

`processInstance` warns "DaemonSet/node-exporter uses hostNetwork, so CiliumNetworkPolicy does not filter its traffic." on GKE and EKS too, where Kix writes the standard NetworkPolicy. The enforcer instance has no enforcer of its own, so the warning cannot read the policy kind from it, and six recorded command outputs under `docs/src/command-output/how-to/` quote the current text.
