# 2026-10-02 · `kix/lib` · Label selector matching is written out seven times, and only one copy reads matchExpressions.

`kix/lib/plugins/netpol/scrape.nix` has `matchesSelector`, the only full metav1.LabelSelector matcher. The matchLabels-only subset test is repeated in `eval/validate.nix` (`selectorMatchesLabels`), `plugins/availability/module.nix`, `helm-dag.nix`, and three times in `rules/architecture.nix`. A check that one day needs `matchExpressions` will get a fourth variant instead of the shared one, and the copies already differ in how they treat a missing key.
