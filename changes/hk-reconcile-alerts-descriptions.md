+++
kind = "fixed"
packages = ["cnpg-operator", "experimental/arc", "experimental/infisical-operator", "experimental/tailscale"]
+++
`CNPGOperatorReconcileErrors` (`cnpg-operator`), `ArcControllerReconcileErrors` (`arc`), `InfisicalOperatorReconcileErrors` (`infisical-operator`), and `TailscaleOperatorReconcileErrors` (`tailscale`) no longer fire when only two reconciles fail in 30 minutes. Because `increase()` extrapolates to the edges of the window, Prometheus can report two errors as slightly above `2`, crossing the old `> 2` threshold. Raising the threshold to `> 2.5` requires at least three errors, and each alert's description now states what to check first.
