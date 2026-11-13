# 2026-11-13 · `cli/kix-cli/src/commands/diff.rs` · `kix plan --read-only` reaches into the diff command's private code.

`commands/plan.rs` calls `diff::compare`, and `diff::Comparison` and `diff::Baseline` (lines 85 to 136) are `pub(super)` only for this one caller. The diff command's internals are now a shared API that nothing names as one. Moving `compare` into `crate::plan` or a `commands/compare.rs` would give both commands one owner to call.
