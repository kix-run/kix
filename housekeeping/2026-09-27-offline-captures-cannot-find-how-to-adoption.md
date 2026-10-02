# 2026-09-27 · `docs/nix/captures.nix` · The full offline capture check fails at `how-to/adoption-parts-overlay` because `kix check how-to-adoption` finds no such cluster in kix-examples.

`nix run ./docs#regen-captures-offline -- --check`, with kix-examples at
its locked revision or at main (both `3b0a04e`), stops with
"cluster 'how-to-adoption' not found". The name appears in kix-examples'
sources but no flake output exposes it under that name, so every group
after it goes unchecked. Seen while checking regenerated `check.json`
captures; eight groups checked one at a time with `--group` passed.
- Hit again 2026-10-01 while building kix-examples against kixpkgs 6bcdbb21: `nix build .#cluster-how-to-adoption --override-input kixpkgs …` fails with "attribute 'root' missing" at `how-to/adoption/cluster.nix:39` (`extraDeps = [ ref.apps.legacy-api-contract.root ]`). It builds with kix-examples' locked kixpkgs, so the evaluation error, not a missing output, is what the CLI reports as "not found".
- Hit again 2026-10-02 with kixpkgs `bd79a38b` and kix-examples `7130ab3`: the five capture groups `how-to/adoption-{parts-overlay,helm-labels,preserve-selectors,import-service,extra-deps}` keep their old sidecars. In a cluster module, `ref.<ns>.<inst>` is now a pointer with only `_type = "kix-ref"`, `namespace` and `instanceName`, and an import instance's `extraDeps` passes it through without dereferencing it. The form `ref.<namespace>.<instance>.root` that `add-explicit-ordering-with-extradeps.mdx` documents therefore fails, and dropping `.root` would hand the marker a value it silently ignores. The fix belongs in `kix/lib/eval/import.nix` (resolve `kix-ref` entries to the target instance's PackageInstance marker) together with the example.
