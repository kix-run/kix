# 2026-10-03 · `kix/packages/grafana` · Grafana's `settings` accepts a literal `client_secret`, which lands in the grafana.ini ConfigMap.

With `oidc.enabled` the package locks `auth.generic_oauth.client_secret`, but
with it off, `settings."auth.generic_oauth".client_secret = "..."` (or the
same key under `auth.github`, `auth.google`, `auth.gitlab`, or
`auth.azuread`, or `smtp.password`) renders into the ConfigMap and the Nix
store. The option description only advises `$__file{}` or env. The datasources
passthrough already refuses literal credentials; `settings` should refuse a
literal value without `$` for Grafana's credential keys the same way
(package-review S1).
