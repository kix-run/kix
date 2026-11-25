# 2026-11-25 · `kix gc --full-scan` · The listing labels a PackageInstance `package: _cluster` while its siblings name the instance.

A test on a real cluster listed `PackageInstance/web` as `package: _cluster` and
the Deployment and Service of the same instance as `package: baseline/web`. The
listing prints the object's `kix.run/package` and `kix.run/package-namespace`
annotations (`print_garbage_plan` in `cli/kix-cli/src/commands/gc/render.rs`),
so the PackageInstance record carries different values from the objects of its
instance. The stamp comes from the Kix library, probably where records are
stamped as cluster-level objects (`kix/lib/default.nix`, `kix/lib/eval/cluster.nix`).
Readers cannot tell which instance a record in the listing belongs to.
