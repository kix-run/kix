# 2026-11-28 · `cli/kix-cli/src/commands/gc/mod.rs` · `kix gc --full-scan` deletes objects no revision names in no useful order.

`ordering_stub` keeps only an object's identity and its `kix.run/identity-hash` and `kix.run/depends-on` annotations. Objects this Kix wrote carry neither annotation, and the stub drops the content Kix derives edges from (a RoleBinding to its Role, a policy to its target). So an unattributed object gets no edges at all, and `--include unattributed` can delete an operator before its custom resources.
