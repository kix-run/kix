# 2026-11-13 · `cli/kix-cli/src/commands/rollback.rs` · `kix rollback` still builds its own plan document and prompts on its own.

Rollback now shares deploy's dry run, refusal checks, start decision, and run (`commands/plan.rs`, `commands/deploy/mod.rs`). It still makes its plan document by hand (`rollback::document`), because `Planned` holds an `InstallableBuild` and a rollback target is a `StoreGraph` that may predate the domain migration. So a rollback does not overlay the dry run's answers on the package plan, checks no drift, and has its own confirmation prompt and summary lines. A fix to `commands::plan::document` misses rollback.

A rollback deploys a stored build, so one `Planned` for both would close the gap. That needs a decision on whether a rollback may install a build that renders Kix's CRDs under a retired group.
