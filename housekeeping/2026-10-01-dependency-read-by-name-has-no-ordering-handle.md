# 2026-10-01 · `kix/lib/eval/view.nix` · A package cannot order a workload after a dependency that nothing in its spec names.

A dependency view has no `outPath`, so `requires = [ dep ]` breaks the manifest JSON, and `dep.root` is the PackageInstance record, which `kix/pi-checks.nix` refuses as a resource dependency. Ordering comes only from an `out.*` value that lands in the manifest. Velero reads `velero-repo-credentials` by name at runtime, so `kix/packages/velero` emits a second `scope.mkSecretRef` for the same Secret just to have something its workloads can require.
