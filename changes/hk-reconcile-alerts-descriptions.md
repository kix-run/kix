+++
kind = "fixed"
packages = ["cnpg-operator", "experimental/arc", "experimental/infisical-operator", "experimental/tailscale"]
+++
`CNPGOperatorReconcileErrors` (`cnpg-operator`), `ArcControllerReconcileErrors` (`arc`), `InfisicalOperatorReconcileErrors` (`infisical-operator`), and `TailscaleOperatorReconcileErrors` (`tailscale`) no longer fire when only two reconciles fail in 30 minutes. Prometheus estimates the count of errors in the window and can read two errors as slightly more than two, which passed the alert's floor of more than two errors. Their descriptions are also reworded.
