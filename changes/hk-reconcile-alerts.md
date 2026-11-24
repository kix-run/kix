+++
kind = "fixed"
packages = ["victoria-metrics-operator", "experimental/rabbitmq-operator"]
+++
`VMOperatorReconcileErrors` (`victoria-metrics-operator`) and `RabbitMQOperatorReconcileErrors` (`rabbitmq-operator`) no longer fire false alerts when a busy, healthy operator retries optimistic-lock conflicts. Both alerts now fire only when a controller's 30-minute reconcile failure rate exceeds 10% (with at least three errors) for 15 minutes, and their descriptions now include the failure percentage.
