# 2026-11-24 · `scripts/kix-manifests.sh` · The script runs whatever `kix` is on PATH, which can be too old to read this repository.

On a machine with Kix 0.8.0 installed, `./scripts/kix-manifests.sh . cloud-identity-eks <out>` stopped with "kix.toml has an unknown setting `library`". `CLAUDE.md` and agent briefs tell agents to run the script as written. They then lose time until they find that `KIX="nix run .#kix --"` is needed, or they fall back to `nix run .#kix -- build -o json`. The script could default to the repository's own Kix.
