# 2026-11-19 · `kix list packages -o json` · A row's namespace is only inside its `status` string.

Rows of one cluster can share a `name`, one for each namespace. The namespace appears only as `installed [<namespace>]` in `status`, so a program has to parse that text to tell the rows apart. `PackageRow` in `cli/kix-cli/src/commands/list.rs` has no `namespace` field.
