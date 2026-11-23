+++
kind = "added"
library = ["kix.reconcileErrorsAlert"]
+++
`kix.reconcileErrorsAlert` returns the reconcile errors alert for an operator built on controller-runtime, for use in the `alerts` of `kix.monitor` or `kix.alerts`. It fires when more than 10% of a controller's reconciles fail over 30 minutes, with more than two errors, so the conflicts that a busy, healthy operator retries do not fire it. The cnpg-operator, arc, infisical-operator, tailscale, rabbitmq-operator, and victoria-metrics-operator packages use it.
