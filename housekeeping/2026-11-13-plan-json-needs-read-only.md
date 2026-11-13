# 2026-11-13 · `cli/kix-cli/src/dispatch.rs` · `kix plan -o json` is refused unless `--read-only` is set.

The format table (line 90) allows JSON for `kix plan` only with `--read-only`, though the full plan could print the same document. A script that wants the plan with the server-side dry run cannot get it as JSON. Allowing it adds output and breaks nothing.
