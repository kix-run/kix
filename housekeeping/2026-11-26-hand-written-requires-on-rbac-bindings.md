# 2026-11-26 · `kix/packages/experimental` · Some workloads list their own RBAC binding in `requires`, which the graph now adds itself.

`mayastor/control-plane.nix` (`agentCoreClusterRoleBinding`), `mayastor/node.nix` (`csiNodeClusterRoleBinding`), `gateway-api/default.nix` (`safeUpgradesBinding`), and the webhook check Job in `external-secrets/webhook.nix` require the binding of their own ServiceAccount. `graph::dependency_pairs` in the CLI now makes every workload depend on those bindings. The entries are harmless, but a package author copying them will think the edge is needed.
