# 2026-11-21 · `cli/kix-core` · An older Kix refuses any new shape inside `[versions]`.

`Versions::parse` in `cli/kix-core/src/versions.rs` accepts only lists of
cluster names under `[versions]` in `kix.toml`. Every version of Kix in a
project reads that table, including the one that picks the version for a
cluster. An older Kix skips settings it does not know elsewhere in
`kix.toml`, but not inside this table.

So a later release cannot add anything to the table, such as a setting for
one input, without breaking the clusters on older versions.

Before the first release with `[versions]`, decide whether an older Kix
skips a value in the table that is not a list of names. After that release
the rule cannot change for the versions already out.

Found by a review of kix#288 on 21 November 2026.
