# 2026-10-02 · `cli/kix-operator/src/k8s_events.rs` · The operator reports an OnDelete DaemonSet with pods pending a restart as plain `ResourceReady`.

`kix deploy` prints "N pods pending manual restart (OnDelete)" for
`NodeDetail::PendingRestart`, but the operator's event mapping falls through
to its `ResourceReady` arm, so a deploy run by the operator records no
Warning event and nobody is told to restart io-engine pods. Mayastor's
io-engine is the DaemonSet this hits.
