# 2026-11-23 · `kix/lib/eval/import.nix` · The import scope refuses scope names it could serve, so most operator packages cannot be an import's `from`.

`mkImportScope` implements the resource, workload, `mkServiceRef`, and `mkSecretRef` builders, `fail`, and `rbac`, and refuses every other name of the package scope with a named error. Some refused names deploy nothing: `networkPolicyEnforcer`, `networkPolicyEnforced`, `labels`, `namespaces`, `forService`, `forNamespace`, and `mkCRDRef` (the same file already builds CRD handles with `k8s.mkCRDRefHandle` for `kix.mkImport { crds }`). 24 package files read `scope.networkPolicyEnforcer`, 19 call `scope.mkCRD`, and 11 call `scope.forService`, so none of them works as `from`, and a `from` package cannot build its `out.crds`.

Decision required from Adam: keep the import scope as a separate scope, build it from `mkScope` with only the builders that deploy something swapped out, or remove `from` in favour of setting `out` directly.
