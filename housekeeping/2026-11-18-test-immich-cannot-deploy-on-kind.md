# 2026-11-18 · `clusters/test-immich.nix` · The `immich` test cluster cannot deploy on kind and has no machine-learning worker.

It sets no kind flavor, no CNI role, and no network policy. `flake.nix` lists it among
the clusters that run on kind. The Immich 3.4.1 bump added
`clusters/test-immich-upgrade.nix` (kind, Cilium default deny, server and
worker) for its deploy test, so two Immich test clusters now overlap.
