# 2026-10-01 · `kix/lib/eval/import.nix` · A package run through `kix.mkImport { from }` fails on a bare "attribute missing" when its build calls a scope builder the import scope lacks, such as `mkCRDRef` or `mkSecret`.

`mkImportScope` offers the resource, ref and workload builders but not
`mkCRD` or `mkCRDRef`. An operator package used as an import's `from`
therefore fails on its own `scope.mkCRDRef` line, and the error names no
import and no reason, although HANDBOOK §23 says such a package "fails with
the reason named". `kix.mkImport { crds }` covers an environment that only
needs CRD handles; a `from` package that builds its `out.crds` still cannot.
- Hit again 2026-10-02 while probing immich with an imported `database`: the import scope defines `mkSecretRef` but not `mkSecret` (or `forwardEdges`), so `kix.mkImport { from = packages.stackgres-database; }` fails with "attribute 'mkSecret' missing", naming neither the import nor the package.
