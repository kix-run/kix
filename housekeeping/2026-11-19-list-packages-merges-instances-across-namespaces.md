# 2026-11-19 · `kix list packages` · Two instances with one name in different namespaces print as one row.

`run_packages` in `cli/kix-cli/src/commands/list.rs` keys its rows by instance name alone. The homelab-kind cluster has an instance `storage` in `immich`, `nas`, `monitoring-system`, and `vaultwarden`, and the list shows one `storage` row with the status of whichever namespace came last. The version, owner, and package of the other instances are lost.
