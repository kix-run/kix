# 2026-10-03 · `cli/kix-cli/src/commands/plan.rs` · `prune_entries` reports `delete` for an orphan the dry run never tried to delete.

With `--prune`, an orphan with no prune answer, for example because the dry
run stopped before its prune phase, gets the fate `delete`. The reference page
says `delete` means the dry-run delete was accepted.
