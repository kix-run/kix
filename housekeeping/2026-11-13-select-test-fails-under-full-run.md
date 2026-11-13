# 2026-11-13 · `cli/kix-cli/tests/select_test.rs` · A version-selection test failed once in a full workspace run and passes alone.

`a_chosen_kix_never_selects_again_and_says_who_chose_it` panicked at line 130 during `cargo test --workspace --no-fail-fast`, then passed three runs in a row with `--test select_test`. It probably shares a directory or an environment variable with another test that runs at the same time.
