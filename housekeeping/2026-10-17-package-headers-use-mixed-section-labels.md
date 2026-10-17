# 2026-10-17 · `kix/packages/*/default.nix` · Package headers use several labels for the same sections.

Dependencies appear as `Dependencies:` (17 packages), `DI deps:` (37), or `Required/Optional dependencies:` (immich). The `out` contract appears as `` `out`: `` (15), `Exposes:` (27), or `out:` (11). package-review P2 (line 320) names no labels. The package-authoring skill now prescribes `Dependencies:` and `` `out`: ``; P2 should name them too, and older headers should follow.
