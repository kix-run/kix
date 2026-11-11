+++
kind = "error"
packages = ["experimental/caddy"]
id = "K2263"
+++
`caddy` reads the Caddyfile only from its `caddyfile` dependency, which every
`caddy` instance now needs. Kix no longer reads the Secret named by
`configSecretName` or the default Secret `<instance>-config`. Add a secret with
the key `Caddyfile` and give it the alias `caddyfile`, such as a
`packages.secret` or `packages.secret-ref` instance with
`aliases = [ "caddyfile" ]`. Each key of that secret becomes a file in
/etc/caddy, so put `crs-setup.conf` in the same secret if your Caddyfile
imports it. A build that sets `configSecretName` fails with an error that
names the `caddyfile` dependency.
