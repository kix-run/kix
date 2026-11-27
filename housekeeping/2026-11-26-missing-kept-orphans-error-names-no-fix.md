# 2026-11-26 · `cli/kix/src/cluster/tenancy.rs` · The error for a missing or unreadable kept-orphans revision does not say how to fix it.

`remedy(true)` says only that Kix cannot tell which kept objects are still the cluster's to delete. `kix gc --full-scan` rebuilds that list (`rebuild_kept_list` in `kix-cli/src/commands/gc/mod.rs`), but neither the `kix deploy --prune` nor the soft `kix gc` refusal names it.
