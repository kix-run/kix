# 2026-09-27 · `docs/nix/captures.nix` · The full offline capture check fails at `how-to/adoption-parts-overlay` because `kix check how-to-adoption` finds no such cluster in kix-examples.

`nix run ./docs#regen-captures-offline -- --check`, with kix-examples at
its locked revision or at main (both `3b0a04e`), stops with
"cluster 'how-to-adoption' not found". The name appears in kix-examples'
sources but no flake output exposes it under that name, so every group
after it goes unchecked. Seen while checking regenerated `check.json`
captures; eight groups checked one at a time with `--group` passed.
- Hit again 2026-10-01 while building kix-examples against kixpkgs 6bcdbb21: `nix build .#cluster-how-to-adoption --override-input kixpkgs …` fails with "attribute 'root' missing" at `how-to/adoption/cluster.nix:39` (`extraDeps = [ ref.apps.legacy-api-contract.root ]`). It builds with kix-examples' locked kixpkgs, so the evaluation error, not a missing output, is what the CLI reports as "not found".
- Hit again 2026-10-02 with kixpkgs `bd79a38b` and kix-examples `7130ab3`: the five capture groups `how-to/adoption-{parts-overlay,helm-labels,preserve-selectors,import-service,extra-deps}` keep their old sidecars.
- Still open 2026-10-02 after kixpkgs resolves `ref.<ns>.<inst>` in an import's `extraDeps` (`kix/lib/eval/import.nix`): kix-examples' `how-to/adoption/cluster.nix` still writes `ref.apps.legacy-api-contract.root`, which fails with "attribute 'root' missing" because a `ref` pointer has no `root`. It evaluates with `extraDeps = [ ref.apps.legacy-api-contract ]`; then the docs flake's kix-examples lock needs bumping and the five groups regenerating.
- 2026-10-02: kix-examples branch `rework/w7-import-root` (`e0c7fdb`, on `packages/public-ready` `7130ab3`, not pushed) writes `extraDeps = [ ref.apps.legacy-api-contract ]`. With it, `cluster-how-to-adoption` builds against kixpkgs `rework/w7-import-root`, and `regen-captures-offline --group how-to/adoption-<g>` with `--override-input kix-examples` runs for all five groups; the only drift is the scorecard summary line (`4 info` to `2 info`). Remaining: push that commit, bump `docs/flake.lock` to it, and run `--apply` for the five groups. Until then the extra-deps page renders the old `.root` snippet, because snippets are generated from the locked kix-examples.
