# 2026-11-23 · `cli/kix-operator/src/controller.rs` · The operator still removes its finalizer from a deleted Activation in some cases where objects stay.

`handle_delete` removes the `kix.run/operator-gc` finalizer without
deleting anything when the record has no `spec.source` or
`load_manifests` fails on it, so the objects stay with no record that
names them. `delete_closure` also lets the record go after an object of
an unrecognized kind or one that changed after it was read. Only
`kix gc --full-scan` finds those objects afterwards.
