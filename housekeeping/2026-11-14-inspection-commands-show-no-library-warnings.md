# 2026-11-14 · `cli/kix-cli/src/commands` · `kix graph`, `kix list`, and `kix images` evaluate the cluster but do not show the library's warnings.

They read `ClusterOutput` from the evaluator, which holds the warnings, and drop them. `kix check`, `kix build`, and every command that builds through `commands::build_flake` show them. Showing them on stderr from `CommandContext::eval_cluster_or_suggest` would cover all of these at once, but `kix check` uses the same path and lists them in its own output.
