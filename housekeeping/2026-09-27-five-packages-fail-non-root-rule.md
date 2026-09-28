# 2026-09-27 · `kix/packages/{caddy,dns-exporter,event-logger,metabase,tailscale}` · Five packages fail `security.nonRoot` at error severity, so no cluster in this repository can install them as they are.

Each sets neither `runAsNonRoot` nor a non-zero `runAsUser` on a
container: caddy's `caddy`, dns-exporter's `dns-exporter`, event-logger's
`event-logger`, metabase's `web` and tailscale's `operator`. No cluster
names these packages, so the finding stayed hidden until the
`every-package-evaluates` check in `kix/package-eval.nix` evaluated them
and had to downgrade the rule for each (`runsAsRoot`). Whether each image
runs as another user is untested.
