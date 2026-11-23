+++
kind = "added"
library = ["kix.reconcileErrorsAlert"]
+++
`kix.reconcileErrorsAlert` builds a standard reconcile-error alert for controller-runtime operators, for use in the `alerts` set of `kix.monitor` or `kix.alerts`. The alert fires when a controller's 30-minute reconcile failure rate exceeds 10% (with more than two errors) for 15 minutes, avoiding false alerts when a busy, healthy operator retries optimistic-lock conflicts. `arc`, `cnpg-operator`, `infisical-operator`, `rabbitmq-operator`, `tailscale`, and `victoria-metrics-operator` now use this helper.
