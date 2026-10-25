# 2026-10-09 · `cli/kix-cli/src/cli.rs` · `kix gc --include-unstamped` is accepted without `--hard`, and then does nothing.

Only hard gc reads unstamped objects, but `GcArgs::include_unstamped` has
no `requires = "hard"`, unlike `--include-unattributed` and
`--include-copies`. A soft run with the flag gives no error and no sign
that the flag was ignored.
