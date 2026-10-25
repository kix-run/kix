# 2026-10-17 · `docs-legacy/HANDBOOK.md` · The tier 2 chart example types the version twice.

Lines 1063-1072 set `version = "1.2.3"` in `fetchHelmChart` and again in `meta.version`. package-review M2 and M4 require one `release` binding feeding both, so the example teaches the mistake the review catches.
