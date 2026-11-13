# 2026-11-13 · `cli/kix-cli/src/commands/upgrade/mod.rs` · `run` is about 510 lines, and `refuse` returns `Result<()>` though it always fails.

`run` (line 40) is hard to follow and to test in parts. `refuse` (552) and `refuse_older` (565) always return an error, so callers write `unreachable!("refuse exits")` after them (638, 644). Returning a `Report` lets callers write `return Err(refuse(..))`.
