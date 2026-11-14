# 2026-11-14 · `cli/kix-cli/src/commands/rollback.rs` · `kix rollback` replaces a data-holding object without the migration stop `kix deploy` has.

The rollback's plan pairs data-holding objects it removes with ones it adds (`Planned::migration_pairs`), as a deploy's does. `kix deploy` stops on such a pair until `--accept-migrations`, and prints the pairs. `kix rollback` has no such flag, never calls `migration_gate`, and prints nothing about the pairs, so a rollback past a volume rename swaps the volume without a word.

Decision required from Adam: whether a rollback stops on a migration (and gains `--accept-migrations`), or only lists it.
