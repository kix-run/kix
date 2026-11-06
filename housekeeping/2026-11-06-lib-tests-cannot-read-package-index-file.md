# 2026-11-06 · `kix/lib/tests` · The eval-only test matrix cannot read `packageIndex`, the `kix-packages.json` a build ships.

`cluster.packageIndex` is `builtins.toFile` over a string that carries store
path context, and in the test matrix (`nix build .#checks.x86_64-linux.kix-lib-tests`)
forcing it fails with "is not allowed to refer to a store path". A test of
what the CLI reads from the index has to settle for `packageIndexContent`,
the attrset before serialization, so a serialization mistake (a key spelled
differently in JSON, a null dropped) would not be caught here. See
`kix/lib/tests/units/lib-cluster-binding.nix`.
