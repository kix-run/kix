# 2026-11-06 · `cli/kix/src/eval/nix.rs` · `nix path-info --json` without `--json-format` is deprecated.

Nix 2.34 prints "'--json' without '--json-format' is deprecated; please specify '--json-format 1' or '--json-format 2'. This will become an error in a future release." Kix runs this command for every build it loads and for `kix bundle`. When a later Nix makes it an error, loading any build fails. Older Nix versions do not accept `--json-format`, so the fix must depend on the Nix that Kix runs.
