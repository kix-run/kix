# Kix

Kix is a Kubernetes compiler. Packages in `kix/packages/` produce K8s resources; contracts in `kix/contracts/` say what a package publishes for other packages to read; cluster definitions in `clusters/` wire them together.

Claude Code also loads every file in `.claude/rules/` with this file. The
longer rules live there, and the sections below that point to them keep their
headings so that references such as "`CLAUDE.md` § Versioning and breaking
changes" still lead somewhere.

## Key rule

When modifying Kix APIs, package conventions, or the diff tooling, keep the `kix-migration` skill (`.claude/skills/kix-migration/SKILL.md`) up to date. This is the primary reference for LLMs working on migrations; stale guidance causes wasted effort.

When modifying how packages vendor their CRDs, or `scripts/vendor-crds.py`, keep the `crd-vendoring` skill (`.claude/skills/crd-vendoring/SKILL.md`) up to date. It is the maintainer of that script and the reference for adding CRD-bearing packages.

When changing package conventions, the lib APIs packages use (`kix/lib/vocab/`, `scope.*` builders, `meta` keys), or the package review process, keep the `package-review` skill (`.claude/skills/package-review/SKILL.md`) up to date. Authors and reviewers run its checklist against every new or changed package, so a stale item either misses a defect or flags correct code.

When changing package conventions, the lib APIs packages use, the test or verification steps for a package, or the authoring process, keep the `package-authoring` skill (`.claude/skills/package-authoring/SKILL.md`) up to date. Authors follow it before and while writing a package, and its pattern table cites package line numbers, so update those when you move the code they point at.

When modifying CLI public APIs, commands, data flows, or crate structure, keep `cli/README.md` up to date. This is the primary reference for LLMs working on CLI features; stale docs cause wasted exploration.

When implementing new features or completing existing ones, check `ROADMAP.md` and mark completed items as `[x]`, expand descriptions with implementation details, or add new items discovered during development.

If you want to understand internals of `kix/lib`, read `kix/lib/architecture.md`. If you edit anything in `kix/lib`, you may or may not need to update `architecture.md`.

The user-facing documentation lives in `docs/src/content/docs/` (deployed to `https://kix.run/docs/`). When you change user-visible API surface, package-authoring helpers, cluster options, or durable conceptual guidance, update the corresponding pages in `docs/src/content/docs/reference/` and `docs/src/content/docs/explanation/`. Follow `docs/CLAUDE.md` and `CLAUDE.prose.md` when editing docs. Do not create separate top-level documentation folders outside `docs/`.

| Topic | Documentation file |
|---|---|
| Package function, `meta`, `options`, `build`, diagnostics | `docs/src/content/docs/reference/package-anatomy.mdx` |
| `scope.mk*` resource/workload builders, `.out` surface, `kix.keep` | `docs/src/content/docs/reference/resources-and-out.mdx` |
| `kix.*` helpers (mounts, env, expose, monitor, healthCheck, pins, availability) | `docs/src/content/docs/reference/composition-helpers.mdx` |
| Secrets (`mkSecret`), CRDs (`mkCRD`), RBAC (`scope.rbac.*`) | `docs/src/content/docs/reference/secrets-crds-and-rbac.mdx` |
| Helm (`importChart`, `helmChart`) and external imports (`mkImport`) | `docs/src/content/docs/reference/helm-and-imports.mdx` |
| Project configuration (`kix.toml`) and builders (`kix`, `nix`, `remote`) | `docs/src/content/docs/reference/kix-toml.mdx` |
| Top-level cluster options (`cluster.*`, `namespaces`, `networkPolicy`, `scorecard`) | `docs/src/content/docs/reference/cluster-configuration.mdx` |
| Instance schema (`deps`, `ref`, `aliases`, `partsOverlays`), `mkEnv`, `mergeFragments` | `docs/src/content/docs/reference/instances-and-composition.mdx` |
| Built-in flavors (`kix.flavors.*`), capability matrix, platform imports | `docs/src/content/docs/reference/flavors-and-capabilities.mdx` |
| Scorecard schemas and built-in rules | `docs/src/content/docs/reference/scorecard-and-rules.mdx` |
| Always-on cross-resource validation checks | `docs/src/content/docs/reference/validation-checks.mdx` |
| `kix.run/*` annotations/labels, `Activation`, `PackageInstance`, deploy receipts | `docs/src/content/docs/reference/annotations-crds-and-receipts.mdx` |
| Core architecture & mental model explanations | `docs/src/content/docs/explanation/the-dependency-graph.mdx`, `docs/src/content/docs/explanation/packages-and-clusters.mdx`, `docs/src/content/docs/explanation/network-policy.mdx`, `docs/src/content/docs/explanation/helm-integration.mdx` |

## Housekeeping: log what you notice

Add every problem you notice and do not fix to the
[`housekeeping/`](housekeeping/) directory, one problem to a file, and commit
it as you go. Approval is not needed, the problem does not have to relate to
the work in hand, and the entry can go on any branch and ride along in any
pull request. We develop this repository through agents, so anything you
notice and do not record is lost when the session ends. A new file under
`housekeeping/` is the one documentation file you may create unasked. Format
and rules: [`CLAUDE.housekeeping.md`](CLAUDE.housekeeping.md).

## Git hygiene

Never `git stash pop`/`apply` unless you created the stash in this session and verified it is the top entry (`git stash list`: check the message matches yours). This repo's stash stack carries old `autostash` leftovers; a blind pop resurrects them into the working tree. To test a hypothesis against a clean tree, use `git worktree add` (or `git show HEAD:<file>`) instead of stashing. Chain stash push→pop with `&&`, never `;`.

**No `Co-Authored-By` trailers.** The `commit-msg` hook in `lefthook.yml`
rejects them and the hook wins. This repo does not record co-authorship in
commit messages, so an agent harness that appends the trailer automatically
must leave it off here. Git history and the pull request already record who
did the work.

## Structured thinking

Use the `structured-thinking` skill (instead of plan mode) when the user wants to think through, brainstorm, design, or analyze something. It routes to `discussions/` or `discussions/interesting_thoughts/`, or for business topics to the private `kix-run/planning-private` repository, and produces a durable doc.

Two rules the skill enforces and you should honor outside it too:

- **Keep discussion docs short.** When a topic needs a new take, don't extend the old doc: start a fresh one, carry forward only the undiscussed/still-important parts, and archive the old. Target ~400 lines per doc. Future / non-blocking ideas go to `discussions/interesting_thoughts/`, never the active folder.
- **Archive on ship.** When a feature that traces back to a discussions doc lands, re-invoke the skill in the same session: split shipped content from still-open questions (lift to `ROADMAP.md § Open design questions` or `interesting_thoughts/`), move the doc to `archive/`, update the README.

## Fixing bugs

Fix a bug at its cause. Before you fix it, zoom out and ask whether it is a
symptom of an architectural problem: two pieces of code that own the same
decision, a concept the design is missing, or a boundary in the wrong place.
If it is, say so, and propose the change to the design as well as the local
fix.

If the only fix you can find is a special case, a retry or timing
workaround, a heuristic, or a flag whose meaning depends on state, do not
build it. Write up two or three options with what each costs, say which you
recommend, and put that in the pull request description or a housekeeping
entry. A known bug with a clear write-up is better than a fix that makes the
code harder to reason about. When you hand bug fixes to subagents, give them
this rule too.

## Code comments

Write for a maintainer reading the current code without the PR. Apply `CLAUDE.prose.md`.

- **Explain why, not what the code already says.** Document invariants, non-obvious constraints, external quirks, and public API contracts. Delete comments that just restate the next line or narrate `if`/`else` branches. Self-explanatory private helpers need no comment; otherwise keep inline comments to 1–2 sentences.
- **Describe only the current contract.** No issue/PR numbers (`#123`), `discussions/` or `housekeeping/` paths, deleted-code tombstones, or comparisons with old code.
- **Write plain, natural English.**
  - Start function comments with a verb (`# Return ...`, `# Validate ...`), never a verbless noun phrase (`# The X a Y activates, or null.`, `# Why X fails...`).
  - One idea per sentence. Do not chain clauses with colons/semicolons or invert word order (`"an import marker no object uses included"`).
  - No aphorisms (`"the position is the dependency, not a choice"`), private metaphors (`"passengers"`, `"witness"`, `"the shelf"`), or defensive filler (`"on purpose"`, `"by design"`).
- **Stay accurate and scoped.** Update or delete comments when behavior changes. Do not touch unrelated comments unless asked.

## Copywriting / positioning

The positioning rules for homepage, README, and pitch copy are in
[`.claude/rules/user-facing-text.md`](.claude/rules/user-facing-text.md).
Before writing any prose, including code comments and docstrings, read
`CLAUDE.prose.md`.

## Versioning and breaking changes

[`.claude/rules/versioning.md`](.claude/rules/versioning.md) holds these
rules: what counts as a breaking change, the kinds of change record and when
a pull request needs one, the Change kind check, required stops, and how a
project names its version of Kix.

## Stability levels

A package, a contract, or a module is stable or experimental. The rules are
in [`.claude/rules/versioning.md`](.claude/rules/versioning.md), after the
versioning rules.

## User-facing text: copy pass

Before opening a pull request that adds or rewrites text a person reads, run
`scripts/copy-pass` on the branch. The full rule, including when to tick
`- [x] Copy pass`, is in
[`.claude/rules/user-facing-text.md`](.claude/rules/user-facing-text.md).

## DSL design principles

- **Don't invent new fields.** The DSL should work with standard K8s manifest fields, not introduce custom spec keys that could confuse users or diverge from K8s semantics.
- **Automation over brevity.** DSL features exist to prevent mistakes (mismatched selectors, forgotten dependencies), not to save lines of code.
- **Resources are rich objects.** Resources expose derived properties (name, selector, labels) through `out`, so consumers query the resource directly rather than calling helper functions or relying on string interpolation tricks. Prefer `self.sa.out.name` over `"${self.sa}"`.

## Build

Use the homelab-kind cluster (`clusters/homelab/`) as the canonical
smoke-test; it wires together most of the package set (stackgres, cilium,
monitoring, ingress, etc.) and catches most regressions:

```bash
nix run .#kix -- check homelab-kind
```

Because `homelab-kind` uses Helm charts, evaluate it through `kix` (or
`./scripts/kix-manifests.sh . homelab-kind ./result` when you need the
manifest directory on disk) rather than plain `nix build`.

## Build caches and disk

Keep build output and git worktrees outside the checkout, and do not use
`path:` flakerefs. Two hooks in `.claude/hooks/` enforce this.
[`.claude/rules/build-caches.md`](.claude/rules/build-caches.md) explains
why and what to do when a hook refuses.

## Diff against live cluster

```bash
./scripts/kix-dump.py --all [--context <ctx>] cluster-dump/
./scripts/compare-cluster-dump.py ./result cluster-dump/
```

## Subagent guidelines

- **Define what "done" looks like:** give a concrete check command and expected outcome.
- **Constrain the workflow:** specify the edit/verify loop. No git commands, no unnecessary builds, no broad exploration.
- **Fail fast:** if they break things badly, return immediately instead of trying to recover.
- **Include known context in the prompt** rather than having agents rediscover it. If it is in files, tell them which files to read.
- **Keep verification with the parent:** agents edit, parent builds/integrates.
- **Reference skill files directly** but never say "understand X"; that triggers expensive exploration.
