# kixpkgs

Nix-based Kubernetes manifest generator. Packages in `packages/` produce K8s resources; cluster definitions in `clusters/` wire them together.

## Key rule

When modifying kix APIs, package conventions, or the diff tooling, keep the `kix-migration` skill (`.claude/skills/kix-migration/SKILL.md`) up to date. This is the primary reference for LLMs working on migrations — stale guidance causes wasted effort.

When modifying CLI public APIs, commands, data flows, or crate structure, keep `cli/README.md` up to date. This is the primary reference for LLMs working on CLI features — stale docs cause wasted exploration.

When implementing new features or completing existing ones, check `ROADMAP.md` and mark completed items as `[x]`, expand descriptions with implementation details, or add new items discovered during development.

If you want to understand internals of kix/lib, read kix/lib/architecture.md. If you edit anything in kix/lib, you may or may not need to update the architecture.md

The user-facing reference docs are `docs-legacy/BEST-PRACTICES.md` (durable, principles-first) and `docs-legacy/HANDBOOK.md` (dense, low-level mechanics). When you change user-visible API surface or durable guidance, update them. The breadth-first inventory in `docs-legacy/FEATURE-CATALOG.md` is the third sibling — keep it in sync when adding new APIs. Do not create additional top-level docs; extend these.

## Git hygiene

Never `git stash pop`/`apply` unless you created the stash in this session and verified it is the top entry (`git stash list` — check the message matches yours). This repo's stash stack carries old `autostash` leftovers; a blind pop resurrects them into the working tree. To test a hypothesis against a clean tree, use `git worktree add` (or `git show HEAD:<file>`) instead of stashing. Chain stash push→pop with `&&`, never `;`.

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

Before writing ANY prose (copy, docs, blog posts), read `CLAUDE.prose.md` for
Adam's accumulated writing corrections (no em dashes, banned words, AI-tell
constructions, messaging constraints). Add to it when he corrects style.

Before restructuring the landing-page hero (layer order, CTA placement, what
belongs above the fold), read `CLAUDE.hero-design.md` for the researched
consensus on dev-tool hero anatomy.


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

## Build caches and disk

Two failure modes here are invisible in the tool output, so a PreToolUse hook
guards each. Both live in `.claude/hooks/` and are wired up by
`.claude/settings.json`; both take `--check` so you can run them by hand.

**Never let build output sit inside the checkout.** A `path:` flakeref copies
a directory into the Nix store with no filtering at all: `.gitignore` is not
consulted, `.git` goes in too, and a fresh copy is made every time any byte of
the tree changes. On 9 Sep 2026 that left two `-source` paths of 47.7 GB and
48.4 GB in the store against a 40 MB git-filtered tree of the same commit, and
filled a 1.9 TB disk overnight. The bulk was `.claude/worktrees/` (30 GB) and
cargo target dirs (16 GB). Nothing in the Nix output names the cause.

`nix_store_guard.py` measures the gitignored bytes a `path:` copy would drag in
and refuses past 2 GB, and refuses any Nix command with under 12 GB free on the
store volume. The remedy it prints is usually to drop the `path:` prefix, since
a plain directory makes Nix use the git fetcher, which skips gitignored files.
Note that the git fetcher also skips untracked files, so `git add` anything new
the evaluation must see.

`devenv.nix` keeps its cargo target dir under `$XDG_CACHE_HOME`, keyed on the
checkout path, for the same reason. Do not move it back into the tree. If you
add another build cache, put it outside the checkout or gitignore it and expect
the guard to shout.

**`target/debug/deps` is flat and cargo never prunes it.** Past roughly 150k
entries every rustc in the build stalls on path lookups, and it does not look
like a slow build, it looks like an idle machine (upstream
rust-lang/cargo#16665, no fix). `cargo_target_guard.py` counts the entries
before any compiling cargo subcommand and refuses at that point. The fix is to
delete the target dir and pay one cold rebuild. Do not repoint
`CARGO_TARGET_DIR` to dodge it; that just starts a second pile.

Keep git worktrees outside the repo. `.claude/worktrees/` is gitignored, which
hides it from git and from nothing else.

## Diff against live cluster

```bash
./scripts/kix-dump.py --all [--context <ctx>] cluster-dump/
./scripts/compare-cluster-dump.py ./result cluster-dump/
```

## Subagent guidelines

- **Define what "done" looks like** — give a concrete check command and expected outcome.
- **Constrain the workflow** — specify the edit/verify loop. No git commands, no unnecessary builds, no broad exploration.
- **Fail fast** — if they break things badly, return immediately instead of trying to recover.
- **Include known context in the prompt** rather than having agents rediscover it. If it is in files, tell them which files to read.
- **Keep verification with the parent** — agents edit, parent builds/integrates.
- **Reference skill files directly** but never say "understand X" — that triggers expensive exploration.
