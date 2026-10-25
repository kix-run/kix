# 2026-10-07 · `cli/kix/src/cluster/secrets.rs` · A YAML SOPS file nested 100,000 deep takes about 100 seconds to refuse.

`age_only_keys` runs serde_yml over a bundle's SOPS file before anyone
approves a plan. serde_yml refuses the nesting, but only after about 100 s
of CPU in a debug test build (1,000 deep takes milliseconds). On the Kix
Enterprise agent the plan's time limit stops it; elsewhere `kix plan
--bundle` just hangs that long. Seen while writing
`a_deeply_nested_bundle_sops_file_is_refused`.
