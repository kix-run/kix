# kixpkgs

Nix-based Kubernetes manifest generator. Packages in `packages/` produce K8s resources; cluster definitions in `clusters/` wire them together.

## Key rule

When modifying kix APIs, package conventions, or the diff tooling, keep the `kix-migration` skill (`.claude/skills/kix-migration/SKILL.md`) up to date. This is the primary reference for LLMs working on migrations — stale guidance causes wasted effort.

When modifying CLI public APIs, commands, data flows, or crate structure, keep `cli/README.md` up to date. This is the primary reference for LLMs working on CLI features — stale docs cause wasted exploration.

When implementing new features or completing existing ones, check `ROADMAP.md` and mark completed items as `[x]`, expand descriptions with implementation details, or add new items discovered during development.

If you want to understand internals of kix/lib, read kix/lib/architecture.md. If you edit anything in kix/lib, you may or may not need to update the architecture.md

The user-facing reference docs are `docs-legacy/BEST-PRACTICES.md` (durable, principles-first) and `docs-legacy/HANDBOOK.md` (dense, low-level mechanics). When you change user-visible API surface or durable guidance, update them. The breadth-first inventory in `docs-legacy/FEATURE-CATALOG.md` is the third sibling — keep it in sync when adding new APIs. Do not create additional top-level docs; extend these.

## Structured thinking

Use the `structured-thinking` skill (instead of plan mode) when the user wants to think through, brainstorm, design, or analyze something. It routes to `business_discussions/`, `v2_discussions/`, or `v2_discussions/interesting_thoughts/` and produces a durable doc.

Two rules the skill enforces and you should honor outside it too:

- **Keep discussion docs short.** When a topic needs a new take, don't extend the old doc — start a fresh one, carry forward only the undiscussed/still-important parts, and archive the old. Target ~400 lines per doc. Future / non-blocking ideas go to `v2_discussions/interesting_thoughts/`, never the active folder.
- **Archive on ship.** When a feature that traces back to a v2_discussions doc lands, re-invoke the skill in the same session: split shipped content from still-open questions (lift to `ROADMAP.md § Open design questions` or `interesting_thoughts/`), move the doc to `archive/`, update the README.

## Copywriting / positioning

When editing homepage, README, pitch, or positioning copy, preserve strong
existing copy unless the user explicitly asks for a full rewrite. Prefer minimal
surgical edits over replacing concise positioning with explanatory prose.

For Kix public copy:

- Lead with: "Kix is a Kubernetes compiler."
- Keep "verifiable cluster artifact" as canonical language unless the user asks
  to test alternatives.
- Do not lead with "emits standard Kubernetes resources"; that is an
  interoperability reassurance, not the core pitch.
- Default flow is: define -> evaluate/check -> preview -> deploy.
- Local/pre-commit feedback comes before PR/CI feedback.
- Avoid sentence-ending "with confidence"; prefer "know what will happen before
  they change Kubernetes."

## Breaking changes

The kix API is in active development. Breaking changes are fine — none of the clusters are actively deployed. Prioritize clean design over backwards compatibility.

## DSL design principles

- **Don't invent new fields.** The DSL should work with standard K8s manifest fields, not introduce custom spec keys that could confuse users or diverge from K8s semantics.
- **Automation over brevity.** DSL features exist to prevent mistakes (mismatched selectors, forgotten dependencies), not to save lines of code.
- **Resources are rich objects.** Resources expose derived properties (name, selector, labels) through `out`, so consumers query the resource directly rather than calling helper functions or relying on string interpolation tricks. Prefer `self.sa.out.name` over `"${self.sa}"`.

## Build

Use the ludo-kind cluster as the canonical smoke-test — it wires together
the full package set (stackgres, cilium, cert-manager, ingress, etc.) and
catches most regressions:

```bash
nix build ludo/#cluster-ludo-kind --extra-experimental-features pipe-operators
```

Other clusters (e.g. `.#cluster-nw1`) may need capabilities the current
env lacks (external cilium, etc.); prefer ludo-kind for default checks.

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
