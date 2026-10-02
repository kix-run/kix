# 2026-10-02 · `cli/kix-cli/src/plan.rs` · `kix diff` names a random Activation as the old one when the cluster holds several.

`record_name` takes the first record-kind manifest it finds in `graph.resources.values()`, which is unordered. Against a live cluster the old graph holds every Activation object, Superseded ones included. On stage1, which has one Active and two Superseded `stage1-*` records, `kix diff stage1` printed a different old name on almost every run, so the `Activation: <old> -> <new>` line cannot be trusted. Seen on main and on `cli/kube-2`.
