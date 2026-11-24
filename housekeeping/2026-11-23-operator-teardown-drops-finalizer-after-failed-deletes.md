# 2026-11-23 · `cli/kix-operator/src/controller.rs` · The operator removes its finalizer from a deleted Activation even when it could not delete the record's objects.

`delete_closure` logs each failed delete, unrecognized kind, and object
that changed after it was read, and then returns `Ok`. `handle_delete`
then removes the `kix.run/operator-gc` finalizer, so Kubernetes deletes
the record and the objects stay with no record that names them. Only
`kix gc --full-scan` finds them afterwards. `handle_delete` also removes
the finalizer without deleting anything when the record has no
`spec.source` or `load_manifests` fails on it.

Decision required from Adam: keep the finalizer and retry while a
delete failed (and give the user a way to give up), or remove it as now
and record a Warning Event that lists what was left.
