# 2026-09-18 · `kix/lib/vocab/compose.nix` · `kix.service.fromWorkload` cannot build a headless Service.

Passthrough merges at the top level, so `spec.clusterIP = "None"` replaces
the whole spec. valkey hand-rolls its headless Service instead and eats a
`selectorCoherence` warning on every build.
