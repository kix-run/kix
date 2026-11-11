# 2026-11-11 · `cli/kix/src/cluster/ops/record.rs` · A deploy whose deployment record cannot be created up front still applies everything.

`ActivationRecord::create` logs a warning when the up-front apply of the record
fails (for example a 403) and the run carries on. If the run then fails part
way, no record says what it applied, so no later plan can account for those
objects. Stopping before the first apply would trade this for a refusal.
