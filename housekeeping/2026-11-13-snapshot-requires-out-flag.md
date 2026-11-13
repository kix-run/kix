# 2026-11-13 · `cli/kix-cli/src/cli/observe.rs` · `kix snapshot` requires `--out`, while `kix bundle` and `kix export` give it a default.

`SnapshotArgs.out` (line 105) has no default. `kix bundle` defaults to `<CLUSTER>.kixbundle` and `kix export` to `./kix-export` (`cli/build.rs:37`, `:67`). A default such as `./<CLUSTER>-snapshot` would make the three alike. Adding a default is not a breaking change.
