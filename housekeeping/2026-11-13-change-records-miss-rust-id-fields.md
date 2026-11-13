# 2026-11-13 · `scripts/change_records` · The id check does not see a Rust `id: "K1234"` field.

`ID_IN_SOURCE_RE` matches `[K1234]` or the Nix form `id = "K1234"`. The refusals in `cli/kix-cli/src/removed.rs` carry their ids as `id: "K1234"` struct fields and print the brackets at run time, so `scripts/change-records.py check` reports that no file prints the id. Tests now repeat each id in brackets only to satisfy the check.
