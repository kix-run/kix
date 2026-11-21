# 2026-11-21 · `cli/kix-cli` · `kix doctor` passes when `[versions]` leaves a cluster out.

A project with a `[versions]` table in `kix.toml` must list every cluster
in it. When `flake.nix` defines a cluster the table leaves out, `kix doctor`
still reports every check as passed. `kix list clusters` shows the cluster
as `not listed in [versions]`, and `kix build` on it stops with an error
that says which lists it can go in.

`check_versions` in `cli/kix-cli/src/commands/doctor.rs` compares the table
with `flake.lock` only. It does not read the clusters of `flake.nix`,
because `kix doctor` evaluates nothing. `run_clusters` in
`cli/kix-cli/src/commands/list.rs` does read them.

A fix would have `kix doctor` read the cluster names when the project has a
`[versions]` table, and fail the check for each cluster the table leaves
out. That costs one evaluation of the attribute names.

Seen while testing kix#288 against two kind clusters on 21 November 2026.
