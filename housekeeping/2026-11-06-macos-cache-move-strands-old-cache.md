# 2026-11-06 · `cli/kix/src/eval/store.rs` · Kix on macOS no longer reads its old cache in `~/Library/Caches/kix`.

`default_cache_dir` now gives `~/.cache/kix` on macOS, as on Linux. Before, it gave `~/Library/Caches/kix`. Kix does not move or read the old folder, so after an upgrade a Mac loses its saved activations (`activations/<cluster>.path` and their GC roots) and its eval cache, and the old store stays on disk. The changelog for the rootless runtime should say so and tell Mac users they can delete `~/Library/Caches/kix`.
