# 2026-10-01 · `kix/lib/eval/import.nix` · `kix.mkImport { from }` ignores the `out` of a root written as `{ resource; requires; out; }`, so the import exposes only the root resource's own `out`.

`evaluateImportInstance` takes `rawRoot.resource` and reads `rootRes.out`,
then merges the import's own `out` over it; `rawRoot.out` is never read.
Packages that put their typed `out` on the root record (`snapshot-controller`
with `out.crds`, `zfs-localpv`, `storage-classes`, `velero`) therefore lose
it when imported with `from`, and a consumer fails on a missing attribute
instead of a message naming the import.
