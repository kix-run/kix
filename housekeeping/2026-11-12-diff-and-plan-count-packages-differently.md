# 2026-11-12 · `cli/kix-cli/src/plan/render.rs` · `kix diff` and `kix plan` describe the same change in different words.

For one changed package, `kix diff` prints "3 packages: 2 unchanged, 1 changed, 0 added, 0 removed" and `kix plan` prints "Plan: 1 updated, 2 unchanged". A reader comparing the two cannot tell they agree.
