# 2026-11-25 · `cli/kix/src/cluster/apply/mod.rs` · The operator and the CLI each code their own rule for an object the cluster no longer holds.

`detect_changes_live` writes an unchanged object again when it has a
`deletionTimestamp` (its own `live_deleting` set) or is absent. The CLI plan
follows the same rule through `inventory::Live::lost`. The two agree today,
but a change to one (for example, to how a missing kind counts) will not
reach the other. `detect_changes_live` could ask `Live::lost`.
