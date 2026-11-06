# 2026-11-06 · `scripts/nw1-diff.sh` · The script builds `.#cluster-nw1`, which no flake in the repository defines.

`nix build .#cluster-nw1` fails before the diff starts, so the script cannot run. Neither `flake.nix` nor `clusters/flake.nix` lists a `nw1` cluster, though `nw1/` still holds the migration dump. If the cluster comes back and uses Helm, the script also needs `scripts/kix-manifests.sh`, because plain `nix build` cannot render charts.
