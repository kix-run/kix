# 2026-11-13 · `cli/kix-cli/src/commands/rollback.rs` · `kix rollback` has its own copy of the deploy pipeline.

The file is 989 lines. It copies the dry-run gate (`refused_writes`, line 825, which calls `Target::connect` a second time at 831), the path for a build with nothing to apply, and builds a `SchedulerConfig` twice (435 and 839). `commands/deploy/mod.rs` (600, 629) and `commands/plan.rs` (225, 235) hold more copies. A fix to one copy misses the others: [rollback-dry-run-ignores-unanswered-nodes](2026-11-13-rollback-dry-run-ignores-unanswered-nodes.md) is one result.

A rollback deploys a stored build, so it could share one path with deploy: planned build, dry run, gate, run. A smaller first step is a `SchedulerConfig::cli(..)` constructor that all three commands call.
