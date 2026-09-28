# 2026-09-27 · `lefthook.yml` · The Rust pre-commit hooks fail on a machine without a rustup default toolchain or devenv, before checking anything.

`format-rust` runs `cargo fmt --check` on the host, which on a machine
with rustup installed but no default toolchain stops with "rustup could
not choose a version of cargo to run". `clippy-rust` runs `devenv shell`,
which is not on PATH when the repository is used through `nix develop`.
Both abort the commit without running a check. CI
(`.github/workflows/cli-tests.yml`) runs `cargo-fmt` and `cargo-clippy`
inside `nix develop`, and notes why it names those binaries. Hit
2026-09-27 committing a gc change; the same checks passed under
`nix develop`.
