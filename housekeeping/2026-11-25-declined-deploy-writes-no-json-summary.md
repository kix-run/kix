# 2026-11-25 · `cli/kix-cli/src/commands/deploy/mod.rs` · A deploy whose prompt is declined writes no JSON `summary` line.

`kix deploy --log-format json` without `--yes` exits 0 when the user declines
the prompt, and stdout stays empty. A program reading the log cannot tell
that from a run that died before printing. The nothing-to-apply case now ends
with a `summary` line; the declined prompt and the other early `Exit::Success`
returns in `run` do not.
