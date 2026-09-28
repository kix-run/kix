# 2026-09-27 · `kix/packages/{metabase,tailscale}` · Two packages fail `security.nonRoot` at error severity, so no cluster in this repository can install them as they are.

Each sets neither `runAsNonRoot` nor a non-zero `runAsUser` on a
container: metabase's `web` and tailscale's `operator`. No cluster
names these packages, so the finding stayed hidden until the
`every-package-evaluates` check in `kix/package-eval.nix` evaluated them
and had to downgrade the rule for each (`nonRoot`). Whether each image
runs as another user is untested.
