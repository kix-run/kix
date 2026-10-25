# 2026-10-17 · `kix/packages/firezone` · firezone pins Firezone 0.7.26, a release line upstream no longer supports.

Upstream's current releases are the 1.x line, with a different deployment
model (a control plane plus gateways), which the package does not support.
The 0.7 line receives no fixes. Carried forward from the entry on firezone's
plain-text secret options, which the secret dependencies of 2026-10-17
fixed. Related: `2026-10-01-firezone-external-url-ignores-its-route.md`.

Decision required from Adam: port the package to 1.x, or delete it with its
`clusters/test-immich.nix` instances.
