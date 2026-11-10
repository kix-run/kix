# 2026-11-10 · `kix/lib/vocab/compose.nix` · `kix.operandPolicy` labels every policy `operator-managed-workload`, also when a package selects its own pods.

Packages use `kix.operandPolicy` to open egress on a port they read from config, such as a mail relay's port (`kix.contracts.smtpRelay.egressPolicy`, plausible, vaultwarden, grafana). Those pods belong to the package, not to an operator, so the `kix.run/policy-type` label misdescribes them to anything that reads it. A build cannot return network intents that depend on config, which is why packages reach for this helper.
