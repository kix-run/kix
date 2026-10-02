# 2026-10-02 · `clusters/test-operators.nix` · The mayastor instance spells the Kix domain in a node label, so `cargo test -p kix-lib keys` fails.

`config.csiNode.nodeSelector."kix.run/test-schedule" = "never";` (line 67) trips `manifest::keys::tests::no_other_file_spells_a_kix_domain`, which allows the domain only in `core/annotations.nix` and `keys.rs`. Any label no node carries works the same, for example `example.com/test-schedule`.
