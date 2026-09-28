# 2026-09-27 · `kix/packages/tailscale` · tailscale fails `security.nonRoot` at error severity, so no cluster in this repository can install it as it is.

Its `operator` container sets neither `runAsNonRoot` nor a non-zero
`runAsUser`, and `kix/package-eval.nix` lists it in `knownFailures`.
`tailscale/k8s-operator:v1.82.0` sets no user and the upstream chart sets
no security context, so upstream runs it as root; whether it works as
another user is untested.
