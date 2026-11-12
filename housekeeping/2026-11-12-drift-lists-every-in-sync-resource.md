# 2026-11-12 · `cli/kix-cli/src/commands/drift.rs` · `kix drift` prints a line for every resource in sync, so one drifted object sits among dozens of ✓ lines.

On a kind cluster with four small example clusters it printed 45 lines to report one drifted Deployment. The command takes no cluster name, so the list grows with every Kix cluster sharing the Kubernetes cluster.
