# 2026-10-09 · `cli/kix/src/build_source.rs` · `build_source` and `eval` import each other.

`build_source` builds on `eval` (stamping, the store graph, store paths), but
`eval::cli_backend` calls `Build::local` and `eval::bundle` re-exports
`build_source::Provenance`. This is the last cycle between kix-lib's
top-level modules besides `manifest` and `legacy_domain`, so neither can be
read or tested without the other.
