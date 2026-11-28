# 2026-11-28 · `cli/kix/src/cluster/observe.rs` · `kix status` and the read-only plan report an object as in sync when only a ceded field Kix owns differs from the build.

Readers without a new build (`kix status`, `kix plan --read-only` through `AppliedHashes::for_live`) compare the live object only with the applied hash, which leaves ceded fields out. A ceded field that Kix still owns and that another build wrote while Kix owned it is invisible to them, although the next `kix deploy` applies the object because of it.
