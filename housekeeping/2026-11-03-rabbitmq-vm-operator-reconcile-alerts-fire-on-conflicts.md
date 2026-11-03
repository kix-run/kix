# 2026-11-03 · `kix/packages/{rabbitmq-operator,victoria-metrics-operator}` · `RabbitMQOperatorReconcileErrors` and `VMOperatorReconcileErrors` fire on any reconcile error, so optimistic-lock conflicts on a busy healthy operator fire them.

Both rules are `rate(controller_runtime_reconcile_errors_total[5m]) > 0` for
15 minutes. controller-runtime counts a conflict as an error and retries at
once. The other operator packages alert on the share of reconciles that
fail over 30 minutes, above 10% and with more than two errors (see
`kix/packages/cnpg-operator`); these two should match, with their promtool
fixtures in `clusters/test-rabbitmq.rules-test.yaml` and
`clusters/test-victoria-metrics.rules-test.yaml`.
