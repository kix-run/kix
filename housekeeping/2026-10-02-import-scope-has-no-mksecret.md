# 2026-10-02 · `kix/lib/eval/import.nix` · `kix.mkImport { from = <package>; }` fails with "attribute 'mkSecret' missing" for a package whose build calls `scope.mkSecret`.

The import-mode scope defines `mkSecretRef` but not `mkSecret` (or `forwardEdges`), so
`kix.mkImport { from = packages.stackgres-database; }` cannot evaluate, and an
existing per-app database cannot stand in for `stackgres-database` that way. The
error names neither the import nor the package. Seen while probing immich with an
imported `database` dependency.
