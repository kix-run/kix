# 2026-10-17 · `lefthook.yml` · The pre-commit `clippy-rust` hook fails outside a devenv shell, so agents commit with it excluded.

The hook runs `devenv shell -- cargo clippy ...`. On a machine where `devenv` is not on PATH (an agent session with only a rustup toolchain) it exits 127 and blocks every commit that touches `cli/**/*.rs`, and `format-rust` also fails unless `RUSTUP_TOOLCHAIN` is set. Agents then run clippy by hand and commit with `LEFTHOOK_EXCLUDE=clippy-rust`, which nothing checks.
- Hit again 2026-10-26 while committing a test in cli/kix-cli/tests; ran clippy and cargo fmt in `nix develop` and committed with LEFTHOOK_EXCLUDE=clippy-rust,format-rust.
