# 2026-11-26 · `cli/kix/src/cluster/revision/spec.rs` · `RevisionSet::of` puts the Activation record into the cluster-level revision when the graph was synthesized.

It leaves the record out by comparing each path with `graph.activation_path`. A graph that `StoreGraph::synthesize` rebuilt, and the stamped builds in tests, carry the record under another path, so the record lands in the cluster-level revision. Its hash changes with every build, so that revision then gets a new name on every deploy.
