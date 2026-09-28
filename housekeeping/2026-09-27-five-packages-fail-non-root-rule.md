# 2026-09-27 · `kix/packages/tailscale` · tailscale fails `security.nonRoot` at error severity, so no cluster in this repository can install it as it is.

Its `operator` container sets neither `runAsNonRoot` nor a non-zero
`runAsUser`. No cluster names the package, so the finding stayed hidden
until the `every-package-evaluates` check in `kix/package-eval.nix`
evaluated it and had to downgrade the rule (`nonRoot`). Whether the image
runs as another user is untested.
