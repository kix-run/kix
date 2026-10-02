# 2026-10-01 · `kix/lib/eval/import.nix` · `kix.mkImport { from; }` takes `out` from the root resource and drops the package's `root.out` extras.

`evaluateImportInstance` builds `out = (rootRes.out or { }) // importDef.out`, so keys a package adds through `root.out` are missing on an import. An imported valkey has no `out.authSecret` or `out.authPasswordKey`, and immich and harbor then connect to it without a password because they guard on `valkey.out ? authSecret`. Nothing warns. `clusters/example-import.nix` imports valkey this way.

Decision required from Adam: whether an import carries `root.out` (and how it would read the dependencies those values come from), or consumers must treat a missing key as an error.
- Hit again 2026-10-02 by `kix/packages/stackgres-cluster`: an import from it gets `out.port` only because the SGCluster resource sets `outputs.port`, and it has no `out.superuserSecret`, so stackgres-database references the Secret by the cluster's name for an import.
- Hit again 2026-10-02 by `kix/packages/n8n`: an imported valkey has no `out.authSecret`, so n8n sends no password. Its `env` accepts `QUEUE_BULL_REDIS_PASSWORD` in that case only, so the user wires an untracked Secret by hand and no check ties it to the import.
- Hit again 2026-10-01 by `snapshot-controller` (`out.crds`), `zfs-localpv`, `storage-classes` and `velero`: they put their typed `out` on a root written as `{ resource; requires; out; }`, and `evaluateImportInstance` reads only `rawRoot.resource`, so an import from them fails on a missing attribute instead of a message naming the import.
