# 2026-10-17 · `kix/packages/victoria-metrics-alert` · `alertmanager.settings` lands in a Secret without the inline-credential refusal that `alertmanager` applies.

`kix/packages/alertmanager/inline-secrets.nix` throws when `settings`
carries a credential key (`slack_api_url`, `auth_password`, `webhook_url`,
and the rest) and points at the `_file` twin. victoria-metrics-alert
renders the same configuration into `<name>-alertmanager-config` with no
such check, so a token written into its `settings` reaches the Nix store
and every build without a warning. Found while writing
`v2_discussions/160_secret_provenance.md`.
