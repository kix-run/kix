+++
kind = "note"
packages = ["experimental/stackgres-operator"]
+++
`experimental/stackgres-operator` moves from StackGres 1.19.2 to 1.19.5. The operator Pod restarts once and its webhooks no longer validate deletes, so deleting a StackGres resource no longer fails while the operator is unavailable. Running PostgreSQL clusters are not restarted. Each `SGCluster` reports `PendingUpgrade` until you run a `securityUpgrade` SGDbOps on it, which StackGres recommends after an operator upgrade.
