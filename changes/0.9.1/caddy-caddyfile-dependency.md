+++
kind = "changed"
packages = ["caddy"]
+++
`caddy` takes the Caddyfile from a `caddyfile` dependency, a secret with the key `Caddyfile` whose keys all appear in /etc/caddy. `configSecretName` still works with a warning, and 0.10 removes it and the default Secret `<instance>-config`.
