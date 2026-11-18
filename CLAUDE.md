# Kix

Kix is a Kubernetes compiler. Packages in `kix/packages/` produce K8s resources; contracts in `kix/contracts/` say what a package publishes for other packages to read; cluster definitions in `clusters/` wire them together.

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

Use the `structured-thinking` skill (instead of plan mode) when the user wants to think through, brainstorm, design, or analyze something. It routes to `v2_discussions/` or `v2_discussions/interesting_thoughts/`, or for business topics to the private `kix-run/planning-private` repository, and produces a durable doc.

Two rules the skill enforces and you should honor outside it too:

- **Keep discussion docs short.** When a topic needs a new take, don't extend the old doc: start a fresh one, carry forward only the undiscussed/still-important parts, and archive the old. Target ~400 lines per doc. Future / non-blocking ideas go to `v2_discussions/interesting_thoughts/`, never the active folder.
- **Archive on ship.** When a feature that traces back to a v2_discussions doc lands, re-invoke the skill in the same session: split shipped content from still-open questions (lift to `ROADMAP.md § Open design questions` or `interesting_thoughts/`), move the doc to `archive/`, update the README.

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
- **Describe only the current contract.** No issue/PR numbers (`#123`), `v2_discussions/` or `housekeeping/` paths, deleted-code tombstones, or comparisons with old code.
- **Write plain, natural English.**
  - Start function comments with a verb (`# Return ...`, `# Validate ...`), never a verbless noun phrase (`# The X a Y activates, or null.`, `# Why X fails...`).
  - One idea per sentence. Do not chain clauses with colons/semicolons or invert word order (`"an import marker no object uses included"`).
  - No aphorisms (`"the position is the dependency, not a choice"`), private metaphors (`"passengers"`, `"witness"`, `"the shelf"`), or defensive filler (`"on purpose"`, `"by design"`).
- **Stay accurate and scoped.** Update or delete comments when behavior changes. Do not touch unrelated comments unless asked.

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

Before writing ANY prose (including code comments and docstrings), read
`CLAUDE.prose.md` for
Adam's accumulated writing corrections (no em dashes, banned words, AI-tell
constructions, messaging constraints). Add to it when he corrects style.

Before restructuring the landing-page hero (layer order, CTA placement, what
belongs above the fold), read `CLAUDE.hero-design.md` for the researched
consensus on dev-tool hero anatomy.


## Versioning and breaking changes

Kix uses semantic versioning and is still below 1.0. A breaking change to anything stable may go in a minor release (0.5 to 0.6), never in a patch release. An experimental package or contract may break in any release (see Stability levels below). Prefer a clean design to keeping old behavior. Do not count a change as breaking just to be safe.

A change is breaking when a user who upgrades must change something, or gets a different result from the same definition. These are breaking:

- removing or renaming a CLI command, flag, or package option, or changing an exit code
- removing or renaming a field or event in JSON output (`-o json`, `--log-format json`), or changing what a value means. This also moves the `SCHEMA_VERSION` of the plan document or the deploy log.
- a change to the `kix` Nix library or to the package shape `{ scope, lib }: { meta, options, build }` that makes an existing package or cluster definition fail or work differently
- a change to the state Kix writes into a cluster (Activation records, `kix.run/*` annotations, PackageInstance, and Kix's CRDs) that makes existing state read differently
- a change to what a package deploys that the user has to act on, such as moving where it keeps its data

Adding something is not breaking. That covers a new command, flag, option, field, event type, annotation, or field in cluster state. Programs that read Kix's JSON output or cluster state must skip fields and event types they do not know, and the JSON schemas say so. The Rust crates are not a public API.

There are two kinds of breaking change, each a kind of change record (below) with its own heading in `CHANGELOG.md`:

- `error`, `### Breaking (shows an error)`: Kix stops with an error that says what to change. For example, a build fails until a package sets a new value. A user cannot miss this kind.
- `silent`, `### Breaking (no error)`: nothing fails, but the result is different. For example, a package now looks for its files in another folder. A user can miss this kind, so it is the more serious one.

Where you can, turn a breaking change with no error into one that shows an error. For example, make the build refuse the old setting and name the new one. This is a goal, not a rule: do it when the cost is reasonable.

Package options, library functions, and CLI flags have no deprecation period. A release may warn about an option before a later release removes it, but it does not have to, and the removal is the `error` record. The records in `changes/0.9.1/` that say an option "still works with a warning, and 0.10 removes it" were written before this rule, and 0.10 keeps that promise. The release that removes or renames one refuses the old form with an error that names the new one and prints the change record's id, such as `[K0001]`. That refusal stays for at least one minor release.

Each breaking change's record says what users change when they upgrade. A change that needs no action, but that users should know about, is a `note` record, listed under `### Upgrade notes`. For example, the first deploy after an upgrade applies many objects again, or restarts some pods once.

One rule holds even before 1.0: a Kix release reads the cluster state written by any release from the last six months, or by the previous minor release, whichever covers more. Cluster state outlives the binary that wrote it, so a change to that state keeps a way to read the old form for that long. A change that cannot keep this promise sets `required-stop = true` on its record: clusters must be deployed with that release before they upgrade further. `kix upgrade` stops at that release, and `kix deploy`, `kix rollback`, and the operator refuse a cluster that would skip it (the release skill adds the version to `REQUIRED_STOPS` in `cli/kix/src/cluster/stops.rs`). Required stops should be rare. The test `cluster_state` in `cli/kix/src/cluster/state_fixtures.rs` reads the objects kept in `cli/kix/tests/fixtures/cluster-state/<version>/`. A release adds a folder there only when one of its change records has `state = true`.

A project names its version of Kix in `flake.lock`: the release tag `v<version>` of its flake input named `kix` (`cli/kix-core/src/flake_lock.rs`). Kix reads that tag before it parses its arguments, and runs or installs exactly that version, so a project's Kix and its Kix library have the same version. A `kix` input on a local folder or a branch, or a project whose `kix.toml` sets `library = "self"` (this repository), uses a development library: Kix runs the version the user started and compares nothing. The one check left, that the library a project evaluated is the running Kix, lives in `cli/kix-core/src/version/policy.rs`, and no other code compares Kix with a library. `kix.toml` names no version and refuses a `kix` key. Kix downloads only Kix itself, never the programs it runs, which arrive inside the signed release archive.

Every pull request that changes something a Kix user sees adds a change record: one file, `changes/<name>.md`, usually named after the branch. Its TOML header gives the `kind` (`error`, `silent`, `note`, `security`, `added`, `changed`, or `fixed`) and what the change touches, and its text is the line users read. `changes/README.md` has the format, and `scripts/change-records.py check` validates it. Do not edit the release sections of `CHANGELOG.md`: the release writes them from the records and moves the records to `changes/<version>/`. The Changelog workflow checks every record's format, and checks that pull requests that change `cli/` or `kix/` add one. Label a pull request `no-changelog` when nothing a user sees changes, such as tests, CI, or an internal refactor. To cut a release, use the `release` skill (`.claude/skills/release/SKILL.md`).

The Change kind workflow (`scripts/change-kind.py`) builds a set of clusters twice: at the pull request's base, and with the pull request's library and the base's cluster definitions (`clusters/`). It then checks the records against what changed. Because the definitions come from the base, fixing `clusters/` in the same pull request does not hide a change. A cluster that builds at the base and fails with the pull request's library needs an `error` record, and the error message must contain its id. A cluster whose manifests change needs a record. Read the objects the check lists as changed, and choose the kind from what a user who upgrades gets. If they must act on the difference, the record is `silent`, not `fixed`. Say in the pull request description which kind you chose and why. A pull request that removes or changes a line of `cli/kix-cli/tests/snapshots/cli_surface.snap` (commands, flags, and their values) or a field of `cli/kix-cli/schema/` needs a record with a `cli` field. The check has two known limits. It sees only the packages that the clusters it builds use, so a change to a package none of them uses passes with no finding. Nothing checks that the kind in the record is right.

## Stability levels

A package, a contract, or a module is stable or experimental. The folder it is in sets the level, and the name a user types shows it.

| | Stable | Experimental |
|---|---|---|
| Package folder | `kix/packages/stable/<name>/` | `kix/packages/experimental/<name>/` |
| In a cluster | `packages.<name>` (also `packages.stable.<name>`) | `packages.experimental.<name>` |
| Contract file | `kix/contracts/stable/<name>.nix` | `kix/contracts/experimental/<name>.nix` |
| In a package | `kix.contracts.<name>` (also `kix.contracts.stable.<name>`) | `kix.contracts.experimental.<name>` |
| Module file | `kix/modules/stable/<name>.nix` | `kix/modules/experimental/<name>.nix` |
| In a cluster | `kix.modules.<name>` | `kix.modules.experimental.<name>` |
| May break in | a minor release | any release |

- A stable package reads only stable contracts and imports no file of an experimental package. An experimental package may read both. The test `levels-stable-packages-read-stable-contracts` checks this. A file two packages share lives in the stable one when either is stable.
- A package becomes stable once it has run in production long enough to settle, such as in more than one Lithus cluster. New packages start experimental.
- `availablePackages = packages` offers stable packages only. A cluster names each experimental package Kix may add: `packages // { inherit (packages.experimental) cert-manager; }`.
- An experimental package may publish a stable contract. A stable package can then take it as a dependency.
- Graduation is a folder move, in any release, and it changes nothing that is deployed. After it, the experimental name fails with an error that gives the stable one. Do not add a forwarding name.
- An experimental package may have the name of a stable package. It is a rework of that package and replaces it in a minor release.
- No package or contract is named `stable` or `experimental`.
- The library has no experimental level. A break to a library function needs a minor release.
- A change record names an experimental package as `experimental/<name>` in `packages`, and an experimental contract as `kix.contracts.experimental.<name>` in `library`. A breaking record that names only those gives a patch release, and `CHANGELOG.md` lists it under `### Breaking in experimental packages and contracts`.

`kix/lib/core/levels.nix` builds the sets. `kix/packages/default.nix`, `kix/contracts/default.nix`, and `kix/modules/default.nix` list the folders. The old names of what moved to experimental in 0.10 fail with `[K0549]` (`kix/packages/was-stable.nix` and the lists in the two other loaders); remove them in 0.11. Adding a package or a contract is adding a folder or a file, Every contract file returns the result of `mkContract` (`kix/lib/vocab/contract.nix`), with the contract's own functions under `helpers` and its option set under `options`.

## User-facing text: copy pass

Claude writes code well and prose badly. Antigravity, running Gemini 4 Carbon by default, writes much clearer user-facing text. Before opening a pull request that adds or rewrites text a person reads, run `scripts/copy-pass` on the branch. That text includes errors, warnings, and log lines in `cli/` and `kix/`, docs pages, skills, and change records in `changes/`. The script hands the changed text to Carbon, which edits the files in place using `CLAUDE.prose.md` for writing rules and the code and docs as its only source of facts. Review Carbon's edits and check every claim it adds against the code. Keep its wording unless a claim is false. If a claim is false, send it back to Carbon with the right facts instead of rewriting the text yourself. Then run the tests again (some check message text word for word) and commit. Set `COPY_PASS_MODEL` to run `scripts/copy-pass` with a different model.

After `scripts/copy-pass` exits 0, add `- [x] Copy pass` to the pull request description. Never tick the box unless the script ran and exited 0. If `agy` is not installed, `scripts/copy-pass` exits 2. Add an unticked `- [ ] Copy pass` box instead. Include the checkbox whenever the pull request adds or rewrites prose, such as a new error message or a reworded docs page. Leave it out for purely mechanical edits, such as a version bump, a renamed path, or a line citation. The Copy pass workflow passes when the box is ticked or omitted, and fails on an unticked box until someone with `agy` runs the pass.

For an important new message, such as a refusal that stops a deploy, you can also give Carbon the facts and have it draft the text directly: `agy --model "Gemini 4 Carbon (Medium)" --print "<facts and request>"`. Describe who reads it, what they just did, and what they can do next. Ask for the full output as it appears on screen rather than separate strings.

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
store volume, except `nix store gc`, `delete`, and `optimise`, which free space. The remedy it prints is usually to drop the `path:` prefix, since
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

- **Define what "done" looks like:** give a concrete check command and expected outcome.
- **Constrain the workflow:** specify the edit/verify loop. No git commands, no unnecessary builds, no broad exploration.
- **Fail fast:** if they break things badly, return immediately instead of trying to recover.
- **Include known context in the prompt** rather than having agents rediscover it. If it is in files, tell them which files to read.
- **Keep verification with the parent:** agents edit, parent builds/integrates.
- **Reference skill files directly** but never say "understand X"; that triggers expensive exploration.
