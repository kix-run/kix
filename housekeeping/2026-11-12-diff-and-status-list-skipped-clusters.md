# 2026-11-12 · `cli/kix-cli/src/commands/gc/mod.rs` · `kix diff` and `kix status` print one "Skipped N objects that belong to Kix cluster X" line for every other Kix cluster.

With four example clusters on one kind cluster, each command opened with three such lines. They say nothing about the cluster asked for, and the list grows with every cluster.
