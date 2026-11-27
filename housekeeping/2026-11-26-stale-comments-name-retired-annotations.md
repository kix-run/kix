# 2026-11-26 · `cli/` · Code comments still describe the package index and `kix.run/activations` as written by every deploy.

`kix-cli/src/commands/gc/mod.rs` (module doc, last paragraph) says retiring records bounds the `kix.run/activations` annotation, which the next deploy compacts. `kix-core/src/eval/package_index.rs` (module doc) says a deploy writes `status.packageIndex`. `ObjectsFrom::Index` in `kix-cli/src/commands/status/document.rs` says "the deploy record's package index", and the status schema repeats it, though it now also means the record's revisions.
