# 2026-10-03 · `cli/kix/src/plan/live.rs` · The upgraded operator fails every reconcile of an Active record made before CRD ref markers carried `kix.run/crd-served-versions`.

`LiveChanges::plan` (through `DeployPlan::from_graph_and_changes`) refuses a CRD ref marker without `kix.run/crd-served-versions` (2026-10-02). An Active record built before then has such markers, so the operator errors on every requeue and writes no status, and `kix rollback --operator` to that record waits out its timeout instead of refusing at once. The CLI's own refusal is accepted while no clusters are deployed.
