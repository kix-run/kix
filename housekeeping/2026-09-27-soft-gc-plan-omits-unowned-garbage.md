# 2026-09-27 · `cli/kix-cli/src/plan.rs` · Soft `kix gc` deletes garbage outside any package without showing it in the plan.

`plan::diff_garbage` walks packages only and always sets `cluster_level: None`, but soft mode deletes every resource in `garbage_manifests`, which includes resources no package owns. A cluster-scoped resource outside a package (a ClusterRole, say) is deleted after a confirmation prompt whose plan never named it. `diff_graphs` already compares unowned resources through `unowned_resources`; `diff_garbage` does not.
