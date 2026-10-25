# 2026-10-09 · `lefthook.yml` · The clippy hook and CI run two different clippy versions, so a lint can pass one and fail the other.

The `clippy-rust` hook runs clippy inside `devenv shell`, which has clippy 0.1.95.
`nix develop`, which CI (`cli-tests.yml`) and agents use, has clippy 0.1.93.
On 2026-10-09 `cargo clippy --workspace --all-targets -- -D warnings` passed under
`nix develop`, and the hook then refused the commit with `clippy::unnecessary_sort_by`
in `cli/kix/src/cluster/activation.rs`. Code that passes CI can fail the hook, and a
lint that only the newer clippy knows never reaches CI.
