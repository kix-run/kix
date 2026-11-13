# 2026-11-13 · `cli/` · The check on the characters of a cluster name is written four times.

`kix-cli/src/dispatch.rs:310`, `kix-core/src/eval/nix.rs:235`, and `kix-core/src/eval/cli_backend.rs:199` and `:300` each test `is_alphanumeric() || '-' || '_'`. A change to the allowed names has to find all four. One `validate_cluster_name` in kix-core would hold the rule.
