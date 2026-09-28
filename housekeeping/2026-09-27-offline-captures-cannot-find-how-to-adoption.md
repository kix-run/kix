# 2026-09-27 · `docs/nix/captures.nix` · The full offline capture check fails at `how-to/adoption-parts-overlay` because `kix check how-to-adoption` finds no such cluster in kix-examples.

`nix run ./docs#regen-captures-offline -- --check`, with kix-examples at
its locked revision or at main (both `3b0a04e`), stops with
"cluster 'how-to-adoption' not found". The name appears in kix-examples'
sources but no flake output exposes it under that name, so every group
after it goes unchecked. Seen while checking regenerated `check.json`
captures; eight groups checked one at a time with `--group` passed.
