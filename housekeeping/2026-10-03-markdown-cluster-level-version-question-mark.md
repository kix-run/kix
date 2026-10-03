# 2026-10-03 · `cli/kix-cli/src/plan/mod.rs` · The Markdown plan prints `_cluster ?` as the summary of the cluster-level group.

`render_change_markdown` falls back to `?` when a package has no version, and the cluster-level pseudo-package never has one, so every PR comment with a cluster-level change shows `<code>_cluster</code> ? (4 dep-affected)`. The text plan prints "cluster-level resources" with no version instead.
