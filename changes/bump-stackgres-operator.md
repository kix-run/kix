+++
kind = "changed"
packages = ["experimental/stackgres-operator"]
+++
`experimental/stackgres-operator` moves from StackGres 1.19.2 to 1.19.5. The operator Pod restarts once, and its webhooks no longer validate deletes, so deleting a StackGres resource no longer fails while the operator is unavailable. Running PostgreSQL clusters keep their Pods, but each `SGCluster` reports `PendingRestart` until you restart it or run a `securityUpgrade` SGDbOps on it. That moves its Pods to the new images.
