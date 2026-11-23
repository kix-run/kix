+++
kind = "fixed"
packages = ["victoria-metrics-operator", "experimental/rabbitmq-operator"]
+++
`VMOperatorReconcileErrors` (`victoria-metrics-operator`) and `RabbitMQOperatorReconcileErrors` (`rabbitmq-operator`) no longer fire on the optimistic-lock conflicts that a busy, healthy operator retries at once. They now fire when more than 10% of a controller's reconciles fail over 30 minutes, with more than two errors, for 15 minutes. This is the rule that the other operator packages already use. The description now gives the share of reconciles that failed.
