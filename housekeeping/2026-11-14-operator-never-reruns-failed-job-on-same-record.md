# 2026-11-14 · `cli/kix-operator/src/controller.rs` · `kix rollback --operator`, and `kix deploy --operator` of the deployed build, never run a failed rerun Job again.

The operator reads the last runs of Jobs only when it starts a Queued record (`Reconcile::Start`), so a failed Job under `kix.run/rerun` runs again once per submitted deploy. `kix rollback --operator` patches the source of the current Active record, and `kix deploy --operator` of the build already deployed applies the same record name. Neither record becomes Queued, so the operator only repairs it and the failed Job stays failed. The direct `kix deploy` and `kix rollback` run it again in both cases.

Decision required from Adam: what marks "a deploy someone submitted" to the operator. Options: make both commands queue the record again; record the generation the operator last started (`status.observedGeneration`) and read last runs when it moves; or leave it.
