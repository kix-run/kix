# 2026-10-02 · `cli/kix-operator/src/k8s_events.rs` · The operator reports a resource whose running workload waits for a restart as plain `ResourceReady`.

`kix deploy` prints "ready, restart pending: <reason>" for
`NodeDetail::PendingRestart`, but the operator's event mapping falls through
to its `ResourceReady` arm, so a deploy run by the operator records no
Warning event and nobody is told to restart anything. It hits an `OnDelete`
DaemonSet with pods on the previous template (Mayastor's io-engine) and a
custom resource in its declared `pendingRestart` state (a KubeVirt
VirtualMachine with `RestartRequired=True`).
