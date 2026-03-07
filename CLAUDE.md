# kixpkgs

Kubernetes packages built with Nix. Each package is a Helm chart migrated to a kix module.

## Structure
- `lib/` — kixlib, shared builders for K8s resources
- `modules/` — base module system (manifests option)
- `pkgs/<name>/` — one directory per migrated chart
- `examples/` — example configs showing module usage
- `scripts/verify-parity` — diff Helm output vs kix output

## Key conventions
- All modules receive `kixlib` via specialArgs
- Resources are built with kixlib builders, not raw attrsets
- Each module exports to `config.manifests.<name>` — one entry per resource, not per module
- Resource names are human-readable (e.g., "coredns"), NOT Nix store paths
- Verification: `./scripts/verify-parity <chart-name>`

## Documentation convention
This project is in active development. **Leave detailed comments everywhere** explaining:
- Why a decision was made (not just what the code does)
- What alternatives were considered and rejected
- Known issues and TODOs with enough context that someone can pick them up later
- Links to the original Helm chart patterns being replaced

The header comment in `lib/default.nix` captures the major architectural decisions.
When adding new code, follow the same pattern — future-you and Luca will thank you.

## Skills
- `helm-to-kix` — Use when migrating a Helm chart to a kix module
