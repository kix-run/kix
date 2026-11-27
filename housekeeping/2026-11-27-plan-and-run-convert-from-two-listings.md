# 2026-11-27 · `cli/kix/src/cluster/revision/convert.rs` · A plan's conversion and the one the run writes come from two listings that can differ.

`planner::ledger_for` converts the old records from the listing the plan made, and `ActivationRecord::begin` converts them again, under the lock, from a new listing. An older Kix or a hand edit can change notes or objects between the two without moving the lock generation, so the run then acts on the plan's orphans while the revisions it stored say otherwise. The second review of the migration found no deletion that follows from it.
