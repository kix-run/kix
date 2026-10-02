# 2026-10-01 · `kix/lib/eval/import.nix` · `kix.mkImport { from; }` takes `out` from the root resource and drops the package's `root.out` extras.

`evaluateImportInstance` builds `out = (rootRes.out or { }) // importDef.out`, so keys a package adds through `root.out` are missing on an import. An imported valkey has no `out.authSecret` or `out.authPasswordKey`, and immich and harbor then connect to it without a password because they guard on `valkey.out ? authSecret`. Nothing warns. `clusters/example-import.nix` imports valkey this way.

Decision required from Adam: whether an import carries `root.out` (and how it would read the dependencies those values come from), or consumers must treat a missing key as an error.
