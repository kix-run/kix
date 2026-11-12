# 2026-11-12 · `kix/lib/core/levels.nix` · A wrong package name under `packages.stable` or `packages.experimental` fails with a bare "attribute missing".

`packages.experimental.grafana` gets a helpful message ("is stable now. Write `packages.grafana`"). `packages.stable.cert-manager` gets `error: attribute 'cert-manager' missing`, and a typo such as `packages.experimental.cert-manger` gets the same, with no suggestion.
