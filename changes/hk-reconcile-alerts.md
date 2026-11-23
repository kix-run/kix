+++
kind = "fixed"
packages = ["victoria-metrics-operator", "experimental/rabbitmq-operator"]
+++
`VMOperatorReconcileErrors` (`victoria-metrics-operator`) and `RabbitMQOperatorReconcileErrors` (`rabbitmq-operator`) no longer trigger false alerts when a busy, healthy operator hits optimistic-lock conflicts and immediately retries them. Matching Kix's other operator packages, both alerts now fire only when a controller's 30-minute reconcile failure rate exceeds 10% (with more than two errors) for 15 minutes, and their descriptions now report the failure percentage.
