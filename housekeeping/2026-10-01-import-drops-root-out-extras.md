# 2026-10-01 · `kix/lib/eval/import.nix` · `kix.mkImport { from; }` takes `out` from the root resource and drops the package's `root.out` extras.

`evaluateImportInstance` builds `out = (rootRes.out or { }) // importDef.out`, so keys a package adds through `root.out` are missing on an import. Valkey's consumers no longer depend on this: they hold their dependency to `kix.contracts.redis`, which names any missing field, and an import carries a password with `credentials = ref.<ns>.<secret>`.

Decision required from Adam: whether an import carries `root.out` (and how it would read the dependencies those values come from), or consumers must treat a missing key as an error.
- Hit again 2026-10-02 by `kix/packages/stackgres-cluster`: an import from it gets `out.port` only because the SGCluster resource sets `outputs.port`, and it has no `out.superuserSecret`, so stackgres-database references the Secret by the cluster's name for an import.
- Hit again 2026-10-01 by `snapshot-controller` (`out.crds`), `zfs-localpv`, `storage-classes` and `velero`: they put their typed `out` on a root written as `{ resource; requires; out; }`, and `evaluateImportInstance` reads only `rawRoot.resource`, so an import from them fails on a missing attribute instead of a message naming the import.
