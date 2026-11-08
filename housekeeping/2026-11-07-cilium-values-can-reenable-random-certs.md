# 2026-11-07 · `kix/packages/cilium` · User `config.values` can turn on chart paths that generate random certificates.

The package turns Hubble off (`kix/packages/cilium/default.nix:236-238`) because the chart's Hubble and clustermesh TLS templates call `genCA` and `genSignedCert`. User values merge on top (`:252`), and nothing refuses `hubble.enabled` or `clustermesh.useAPIServer`. If a user sets them, each render produces new certificates, so the activation hash changes on every fresh render and two machines disagree.
