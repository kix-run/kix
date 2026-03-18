# kixpkgs

Nix-based Kubernetes manifest generator. Packages in `packages/` produce K8s resources; cluster definitions in `clusters/` wire them together.

## Key rule

When modifying kix APIs, package conventions, or the diff tooling, keep the `kix-migration` skill (`.claude/skills/kix-migration/SKILL.md`) up to date. This is the primary reference for LLMs working on migrations — stale guidance causes wasted effort.

## Build

```bash
nix build .#cluster-nw1 --extra-experimental-features pipe-operators
```

## Diff against live cluster

```bash
./scripts/kix-dump.py --all [--context <ctx>] cluster-dump/
./scripts/kix-diff.py ./result cluster-dump/
```
