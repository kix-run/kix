# 2026-10-02 · `kix/lib/helm.nix` · `scope.helm.importChart`'s `deps` and `networkDeps` arguments have no package and no test.

`importChart` merges the context of every `dep.out.*` value in `deps` into `networkDeps`, so a chart that reads a dependency's address gets the ordering and network-policy edge (`kix/lib/helm.nix:342-388`). The only caller was the promtail package, which is gone. No package under `kix/packages` and nothing under `kix/lib/tests` passes either argument, so a change that breaks them goes unnoticed. `guide/03-advanced.md` still teaches the `deps` form.
