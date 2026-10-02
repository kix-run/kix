# 2026-09-28 · `cli/kix/src/eval/build.rs` · The CLI reports a cluster that fails to evaluate as "cluster not found" whenever the Nix output contains the words "attribute" and "missing".

`build.rs` (around line 106) and `ffi.rs` `classify_eval_error` treat any
failure whose text holds both words as a missing cluster. A Nix stack
trace says "while evaluating the attribute", and a scorecard warning says
"is missing resource settings", so a real error such as a type error in
an option is replaced by "cluster 'X' not found. Available clusters: ..."
with X in the list. Seen with `kix build how-to-platform-cloudflare-tunnel`
in kix-examples, whose real error is "A definition for option `image' is
not of type `submodule'". The 2026-09-27 entry about `how-to-adoption`
has the same cause: its real error is "attribute 'root' missing" at
`ref.apps.legacy-api-contract.root` in kix-examples'
`how-to/adoption/cluster.nix`.
- Hit again 2026-10-01 while planning instance-config error locations: `ffi.rs` `classify_eval_error` also matches "does not exist", so a misspelled instance option ("The option `instances.<ns>.<inst>.config.replicaz' does not exist") is reported as a missing cluster.
