# 2026-10-17 · `kix/packages/firezone` · firezone pins Firezone 0.7.26, a release line upstream no longer supports.

Upstream's current releases are the 1.x line, with a different deployment
model (a control plane plus gateways), which the package does not support.
The 0.7 line receives no fixes. Carried forward from the entry on firezone's
plain-text secret options, which the secret dependencies of 2026-10-17
fixed. Related: `2026-10-01-firezone-external-url-ignores-its-route.md`.

Decision required from Adam: port the package to 1.x, or delete it with its
`clusters/test-immich.nix` instances.
- Hit again 2026-11-18 while trying a bump to the upstream tag `1.0.5`. That
  tag is a May 2024 release of the 1.x clients, gateway, and relay, not a
  server. Upstream publishes no versioned image of the 1.x control plane
  (`ghcr.io/firezone/portal`, `web`, `api`, and `domain` carry only commit
  and pull request tags), gives no path from 0.7 data to 1.x, and its FAQ
  says the control plane is not designed to be self-hosted. So no 1.x
  release can replace this package's image.
