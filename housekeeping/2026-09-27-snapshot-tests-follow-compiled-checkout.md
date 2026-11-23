# 2026-09-27 · `cli/kix-cli/tests/snapshot_test.rs` · The snapshot tests build whichever checkout the test binary was compiled in, not the one `cargo test` runs from.

`kix()` sets the working directory from `env!("CARGO_MANIFEST_DIR")`,
which is fixed at compile time. insta finds its snapshot files the same
way. With one `CARGO_TARGET_DIR` shared across git worktrees, `cargo test`
in a second worktree reused the first worktree's test binary, because
cargo judges freshness by mtime and a new worktree's sources are older
than the first build. The binary then snapshot-tested the first checkout,
so a branch whose activation path had changed reported 5 passed.

The problem stays hidden only while every checkout has its own target
dir, as the dev shells set up today (`devenv.nix`, the `flake.nix`
shellHook, and the clippy hook in `lefthook.yml`). A shared target dir,
such as one set to save disk space, brings it back. The other tests under
`cli/kix-cli/tests/` that read `CARGO_MANIFEST_DIR` have the same problem.
