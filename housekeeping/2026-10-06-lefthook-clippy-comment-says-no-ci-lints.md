# 2026-10-06 · `lefthook.yml` · The clippy hook's comment says no CI workflow lints, but two do.

The comment above `clippy-rust` says "the only CI workflow (pages.yml) builds the site and
never lints", as the reason the hook must stay. `cli-tests.yml` has run `cargo-clippy` and
`cargo-fmt --check` since 2026-09-20, and `lint.yml` now checks the Nix files. A reader
weighing whether the slow clippy hook is still needed gets the wrong answer.
