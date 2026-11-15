# 2026-11-15 · `cli/kix-operator/src/controller.rs` · A newer operator request cannot cancel the deploy that is running.

The operator cancels a running deploy only when the operator itself stops (`Context::shutdown`). A newer request for the same Kix cluster waits until the current deploy ends, however long its resources take, and the readiness timeout is fixed at 300 seconds (`READINESS_TIMEOUT`). Options: keep a token per Kix cluster in the operator's `Context` and cancel it when a newer request for that cluster arrives, which needs a watcher beside kube-runtime's controller (it runs one reconcile per object at a time); carry a timeout on the Activation request.

`start_queued` supersedes only an `Active` or `Degraded` record (`Records::active`). It may start a Queued record of the same Kix cluster while another record is still `Deploying`, so two deploys would write at once. I did not confirm this on a cluster.
