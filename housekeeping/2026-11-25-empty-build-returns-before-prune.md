# 2026-11-25 · `cli/kix-cli/src/commands/plan.rs` · An empty build stops `kix deploy` before it connects, so `--prune` deletes nothing.

`prepare` returns `None` with "Nothing to deploy." when the build has no
resources, and `deploy` exits 0 without reading the active record or pruning
its objects. Kix's own CRDs are normally in every build, so this may be
unreachable. If it is reachable, a user who empties a definition to remove a
cluster gets no prune and no warning.
