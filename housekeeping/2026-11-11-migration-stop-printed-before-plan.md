# 2026-11-11 · `kix deploy` · The stateful-migration stop prints before the plan, and four commands render migration pairs four ways.

`commands/deploy/mod.rs` checks `migration_pairs` before the plan summary, so a
person deciding whether to pass `--accept-migrations` has not seen the plan.
`deploy/observer.rs`, `commands/plan.rs`, `commands/diff.rs` (text and
Markdown), and `deploy/saved_plan.rs` each format the pairs and the advice
separately.
