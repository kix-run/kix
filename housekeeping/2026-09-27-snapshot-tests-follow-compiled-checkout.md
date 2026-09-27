# 2026-09-27 · `cli/kix-cli/tests/snapshot_test.rs` · The snapshot tests build whichever checkout the test binary was compiled in, not the one `cargo test` runs from.

`kix()` sets the working directory from `env!("CARGO_MANIFEST_DIR")`,
which is fixed at compile time. With one `CARGO_TARGET_DIR` shared
across git worktrees, `cargo test` in a second worktree reused the
first worktree's test binary, because cargo judges freshness by mtime
and a new worktree's sources are older than the first build. The binary
then snapshot-tested the first checkout, so a branch whose activation
path had changed reported 5 passed. Giving each worktree its own target
dir showed the real failures.
