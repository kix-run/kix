# 2026-09-27 · `cli/kix-operator/src/controller.rs` · The operator's Activation teardown copies gc's delete loop instead of sharing it.

`handle_delete` builds its own kind-to-ApiResource map, falls back to the `default` namespace, and deletes each resource in a loop, as `delete_resources` in `cli/kix-cli/src/commands/gc.rs` does. The two copies must each filter `lifecycle::never_pruned` themselves, and a fix to one (a skip, a propagation policy, a 404 rule) does not reach the other. The operator's copy also ignores a kind missing from discovery without logging it.
