# kixpkgs

Nix-based Kubernetes manifest generator. Packages in `packages/` produce K8s resources; cluster definitions in `clusters/` wire them together.

## Key rule

When modifying kix APIs, package conventions, or the diff tooling, keep the `kix-migration` skill (`.claude/skills/kix-migration/SKILL.md`) up to date. This is the primary reference for LLMs working on migrations — stale guidance causes wasted effort.

When modifying CLI public APIs, commands, data flows, or crate structure, keep `cli/README.md` up to date. This is the primary reference for LLMs working on CLI features — stale docs cause wasted exploration.

## Breaking changes

The kix API is in active development. Breaking changes are fine — none of the clusters are actively deployed. Prioritize clean design over backwards compatibility.

## DSL design principles

- **Don't invent new fields.** The DSL should work with standard K8s manifest fields, not introduce custom spec keys that could confuse users or diverge from K8s semantics.
- **Automation over brevity.** DSL features exist to prevent mistakes (mismatched selectors, forgotten dependencies), not to save lines of code.
- **Resources are rich objects.** Resources expose derived properties (name, selector, labels) through `out`, so consumers query the resource directly rather than calling helper functions or relying on string interpolation tricks. Prefer `self.sa.out.name` over `"${self.sa}"`.

## Build

```bash
nix build .#cluster-nw1 --extra-experimental-features pipe-operators
```

## Diff against live cluster

```bash
./scripts/kix-dump.py --all [--context <ctx>] cluster-dump/
./scripts/kix-diff.py ./result cluster-dump/
```

## Subagent guidelines

- **Define what "done" looks like** — give a concrete check command and expected outcome.
- **Constrain the workflow** — specify the edit/verify loop. No git commands, no unnecessary builds, no broad exploration.
- **Fail fast** — if they break things badly, return immediately instead of trying to recover.
- **Include known context in the prompt** rather than having agents rediscover it. If it is in files, tell them which files to read.
- **Keep verification with the parent** — agents edit, parent builds/integrates.
- **Reference skill files directly** but never say "understand X" — that triggers expensive exploration.
