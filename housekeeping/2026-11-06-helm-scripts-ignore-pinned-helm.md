# 2026-11-06 · `scripts/render-helm-dump.sh`, `docs/nix/captures-live.nix` · Two tools run a different Helm from the one Kix renders charts with.

`kix/lib/helm.nix` renders every chart with the Helm release named in `kix/lib/helm-versions.json`. `scripts/render-helm-dump.sh` runs `nixpkgs#kubernetes-helm` from the flake registry, and `docs/nix/captures-live.nix` runs `pkgs.kubernetes-helm`. Their Helm version follows nixpkgs, so a chart they render can differ from the Kix render.
