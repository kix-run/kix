# 2026-10-01 · `kix/lib/vocab/compose.nix` · `kix.options.healthCheck` names its toggle `enable`, while every other package toggle is `enabled`.

`kix.options.monitor` and the package conventions use `enabled`, so an instance writes `metrics.enabled = true` but `healthCheck.enable = true`. A misspelling fails evaluation with an unknown-option error, so nothing breaks silently, but each author trips over it once. Renaming touches every package that uses `kix.options.healthCheck`, the `kix.healthCheck` helper that reads it, and the cluster files that set it.
