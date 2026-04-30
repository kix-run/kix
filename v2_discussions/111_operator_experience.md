# 111 — Cluster operator experience: pre-deploy plan, stateful trust, operational flow

**Status:** RFC
**Relevance:** Active
**Related:** `90_ludo_north_star_ideation.md`, `105_ludo_homelab_operational_readiness.md`, `106_ops_lifecycle_verbs_and_capacity_check.md`, `67_stateful_migration_orchestration.md`, `81_deploy_as_lifecycle_engine.md`, `98_deploy_execution_topology.md`, `cli/README.md`, `cli/kix-cli/src/plan.rs`, `cli/kix/src/cluster/migrate.rs`, `cli/kix/src/eval/store_graph.rs`
**Supersedes:** none.

---

## 1. Why this doc

Engine-side designs exist for everything an operator needs (planner, transitions, lifecycle verbs, migration pairs, backup contracts, drift). What's missing is what the operator actually *sees* before they press apply. The pieces today:

- 67 §3.3 sketches an interactive four-option migration prompt — for pairs only.
- 98 §5 mocks a live execution grid for *during* deploy, not before.
- The CLI today has `kix diff` and `kix deploy` with package-grouped output (`plan.rs::print_package_plan`) and migration-pair phase-1 detection (`migrate.rs::detect_migration_pairs`). Useful, but the report does not communicate blast radius, why a resource is changing, or statefulness in any prominent way.

The shared substrate everything in this doc reads from already exists in code:

- `StoreGraph` with `PackageNode`, `ResourceNode`, and **`cross_deps: Vec<CrossDep>`** (package→package edges with the specific resource→resource that produced them).
- `kix.dev/lifecycle` annotation on every resource (`stateful` | `durable` | `ephemeral` | unset).
- `kix.dev/identity-hash`, `kix.dev/depends-on`, `kix.dev/package`, `kix.dev/package-namespace` annotations.
- `PackageDiff` with content-vs-propagation distinction (`resource_diffs` vs `dep_affected_resources`).
- `MigrationPair { slot, source, target, reason }` from phase-1 detection.
- Activation linkage (`identity_hash`, `previousActivation`) → `gen N → gen N+1`.

The plan **is** the DAG diff plus migration-pair handling on top. Everything else in this doc is a view over that.

## 2. One taxonomy: node states and edges

The DAG diff places every node — resource or package — in exactly one state:

| State | Meaning | Glyph |
|---|---|---|
| `unchanged` | identity-hash identical between closures | (omitted from views) |
| `changed` | identity-hash differs because real manifest content changed (stripped of propagation annotations) | `~` |
| `dep-changed` | identity-hash differs **only** because a dependency's hash propagated up; no real content delta | `⤴` |
| `added` | not in old, in new | `+` |
| `removed` | in old, not in new | `-` |

Same names at resource and package level. A package is `changed` if any owned resource is `changed`; `dep-changed` if all its diffs are propagation-only; `added`/`removed` if the package itself appears or disappears. There is no separate "orphan" or "pruning" concept at the plan level — a removed resource is just `removed`. The deploy executor may handle removals as a distinct phase, but the plan is silent on that.

Edges (from `cross_deps` and `kix.dev/depends-on`) inherit a binary label: an edge is *touched* iff either endpoint is non-unchanged.

This taxonomy is the entire vocabulary the rest of the report uses.

## 3. The pre-deploy report: views over the plan

The plan is the DAG diff + migration pairs. The report is a stack of views, each a strict projection over that plan, ordered eye-friendly: aggregate first, full picture last.

### 3.1 Worked example

```
ludo · gen7 → gen8

PACKAGES   3 changed · 1 added · 0 removed · 4 dep-changed · 47 unchanged
RESOURCES  8 changed · 4 added · 3 removed · 12 dep-changed · 162 unchanged
STATEFUL   1 migration pair · 2 in-place stateful changes

VERSION DELTA
  immich/immich              1.2.4   → 1.3.0
  cilium/cilium              1.16.1  → 1.17.0
  + immich/immich-dashboard  0.1.0           (new)

BY PACKAGE
  immich/
    ~ immich            1.2.4 → 1.3.0   ⚐stateful
        ~ Deployment/immich
            spec.template.spec.containers[0].image:  1.2.4 → 1.3.0
    + immich-dashboard  0.1.0
        + Deployment/immich-dashboard
        + Service/immich-dashboard
        + Ingress/immich-dashboard
  postgres/
    ⤴ postgres                          ⚐stateful
        cause:   cilium  (cross_dep cilium-cnp/postgres → cilium)
        ⤴ 5 dep-changed resources       (-v to expand)
  cilium/
    ~ cilium            1.16.1 → 1.17.0
        ~ DaemonSet/cilium
        ~ ConfigMap/cilium-config
        ~ ClusterRole/cilium
        ~ ServiceAccount/cilium
        - Job/cilium-migrate-v16
  immich-old/
    - immich-old                        (package removed)
        - Deployment/immich-old
        - Service/immich-old
        - Ingress/immich-old

STATEFUL
  Migration pairs:
    immich/storage   PVC/storage-old → PVC/storage-new
        storageClass: local-path → zfs-tank
  In-place stateful changes:
    StatefulSet/postgres   spec.template.spec.containers[0].image
    PVC/grafana-storage    spec.resources.requests.storage  5Gi → 10Gi

BLAST RADIUS
  cilium/cilium  ──changed──→
        cilium-cnp/immich        (dep-changed)
        cilium-cnp/postgres      (dep-changed)
        cilium-cnp/n8n           (dep-changed)
        cilium-cnp/vaultwarden   (dep-changed)
        postgres/postgres        (dep-changed, transitive via cilium-cnp/postgres)
  immich/immich  ──changed──→ (none)

RAW DAG DIFF
  214 nodes · 487 edges · 27 nodes touched · 41 edges touched
  → kix graph --diff   to render
```

### 3.2 The views

| View | Reads from | What it answers |
|---|---|---|
| **Header** | activation `identity_hash` + `previousActivation` | which generation transition this is |
| **Summary lines** | counts of nodes by state at package + resource level; count of `MigrationPair`; count of resources with `lifecycle=stateful` whose hash changed | "how big is this deploy" |
| **Version delta** | `PackageChangeDiff` where `old_version != new_version`, plus `added`/`removed` packages with versions | NixOS-generation read; the headline of what's moving |
| **By package** | `PackageDiff` grouped by namespace; per-package owned resources with their state and field diffs | the spine — every operator drill-in starts here |
| **Stateful** | filter §By package to resources with `lifecycle=stateful` and any state ≠ unchanged; merge with `MigrationPair` list | one place to scan for data-touching change |
| **Blast radius** | for each `changed` package, walk `cross_deps` reverse edges transitively; emit the dep-changed packages reached | inverts dep-changed: cause → effects |
| **Raw DAG diff** | every node and touched edge with state | the floor; full picture for when the views aren't enough |

### 3.3 Row anatomy

A by-package row carries:

- glyph + name (one of `~`/`⤴`/`+`/`-`)
- old_version → new_version when both exist and differ (only meaningful on `changed`/`added`/`removed`; `dep-changed` packages by definition have no version delta)
- `⚐stateful` glyph if any owned resource has `lifecycle=stateful`
- migration-pair link if the package owns one side of a `MigrationPair`
- on `dep-changed` rows only: a `cause:` line citing the responsible incoming `cross_deps` edge (one short pointer; the full set is the Blast Radius view's job)

A by-package resource row carries:

- glyph + ResourceId
- on `~`: collapsed field-diff lines (one path per line, `before → after`); under `-v` expand to the full structural diff
- on `⤴`: aggregated count by default (`5 dep-changed resources`); under `-v` enumerate
- on `+`/`-`: just the ResourceId

Removed resources of a removed package render under that package, not in a separate section.

### 3.4 Distinctions worth keeping

- **`~` and `⤴` look different on purpose.** A `~` row is the operator drilling *in* on a real change. A `⤴` row is the operator scanning *past* it — the relevant fact is the cause-package on the next line, not the resource list. Same glyph would conflate causes with symptoms.
- **Stateful is a view, not a section bolted onto by-package.** Lifecycle annotations + migration pairs + in-place diffs on stateful resources form one coherent lens; they all read from the same data, just filtered.
- **Blast radius is transitive.** The store-path hash bump fans out transitively at apply time, so a one-hop blast view would understate what the deploy actually re-applies. We follow the hash propagation faithfully.

### 3.5 Renderers and depth

The full report is the L2-equivalent. Two collapses worth supporting, both pure rendering choices:

- **Compact** — drop the per-resource lines under each `~` package, keep only the package-level row + counts. Roughly today's `print_package_plan`.
- **Verbose (`-v`)** — expand `⤴` resource lists, expand `~` field diffs to full structural form (today's `format_diffs` output).

JSON / YAML emit the same structured Plan unconditionally; the text renderer picks compact vs default vs verbose.

## 4. Stateful trust gate

Partial apply is not a thing in kix. Every deploy is atomic from the operator's mental model. Therefore terminal-time per-change acknowledgement is friction without safety — it just adds keystrokes between the operator and the same outcome.

The gate has two surfaces, neither a per-change prompt:

### 4.1 In-report: visual prominence

The Stateful view (§3.2) puts every state-touching change in one place at the top of the long output, ahead of the by-package details. A `⚐stateful` glyph on by-package rows ensures the operator can't scroll past one. Migration pairs render with their `reason` (already produced by `migrate.rs::derive_reason`) so the operator sees *why* (storageClass changed, kind changed, size changed) without drilling.

That is the entire on-CLI surface. Single `y/N` covers the whole deploy.

### 4.2 CI authorship gate

The actual review-by-human gate lives in the PR pipeline. Mechanism:

- A package/instance has a maintainership list (config shape is Open Question 3 below).
- The PR check renders the Plan and identifies any state-touching Transition (`changed`/`removed` on resources with `lifecycle=stateful`, or any `MigrationPair`).
- For each such change, it checks whether the PR author is on the maintainer list for the touching package/instance.
- If not, auto-merge is blocked; explicit approval from a maintainer is required.

Routine apps merge freely. Touching `postgres/data` requires DBA approval. The operator running `kix deploy` from their laptop trusts that anything in main has cleared this gate.

## 5. Operational flow: `kix status` as the entry point

The operator's first command of the day is `kix status`. It is the union of activation history + drift + capability health, presented to drive the next action.

```
$ kix status ludo

Activation:  ludo@gen7  (applied 2026-04-26 14:20 by luca)
Git HEAD:    a8f3c21    (3 commits ahead of last activation)
Drift:       ✓ in sync with desired (last check 2m ago)

Capability health:
  backup       ✓ last success 4h ago (immich, postgres, vaultwarden)
  certs        ✓ next expiry in 47d
  storage      ✓ zfs-tank 142Gi free of 800Gi
  alerts       ⚠ 1 firing: PostgresHighWAL (since 12m)

Next actions:
  kix diff      — 3 commits worth of changes pending
  kix history   — see past activations
  kix upgrade   — k3s 1.30 → 1.31 available
```

Properties:

1. **One screen.** Sections summarise; details live behind verbs.
2. **Per-source.** Each line cites where it came from: `git log` for the commit count, the drift detector for sync, doc 108's backup engine `out.lastSuccess` for backup, doc 110's alert provider for firing alerts. `kix status` aggregates; it does not invent.
3. **Suggested actions.** A firing alert outranks a pending diff; an expiring cert outranks both. Operator chooses.
4. **Read-only.** Safe to run anywhere; CI runs `kix status --output=json` to gate PRs ("don't merge if drift").
5. **Composable later.** A `--watch` ratatui dashboard is a follow-up (doc 90 §H); v1 is the static one-shot.

`kix status` requires activation history (doc 106 §1.5) and drift detector (doc 106 §1.4) to land first. It is therefore a *late* item in the build order, but the right design anchor — every verb is built for `status` to point at.

### 5.1 Verb composition

Once `status` has communicated state, the operator picks one of:

| Verb | Purpose |
|---|---|
| `kix diff` | Render the Plan from current activation to git HEAD. Read-only. |
| `kix deploy` | Apply the Plan. Confirmation render is the same Plan as `diff`. |
| `kix upgrade --target k3s=v1.31` | Eval the cluster against an alternative flavor; rehearse in kind; apply if green. |
| `kix restore --workload pg-main --to <ts>` | Apply the backup engine's restore plan as a sibling activation. |
| `kix rollback` | Apply the previous activation's manifests in reverse. |
| `kix history` | Query activation log. |
| `kix drift` | Force a drift check. |
| `kix graph --diff` | Render the raw DAG diff (the floor of §3.1). |

Each verb hands control back to `kix status`. Flow is: status → action → status. No implicit chaining.

## 6. Failure-recovery model

Default: **halt-and-report**. On any Transition failure, the scheduler stops new work, lets in-flight siblings finish, and reports. The cluster sits in a partially-applied state visible via `kix status`. Operator inspects, fixes, re-runs `kix deploy` which resumes from the failed node forward. This matches today's `scheduler.rs` halt-dependents/continue-siblings behaviour.

Opt-in: **`--rollback-on-failure`**. For high-stakes deploys (CI, scheduled k3s upgrade windows). On failure: scheduler halts, then re-applies the previous activation's manifests for everything this deploy touched. Migration sub-DAGs are atomic regardless of this flag — the doc 67 phase 2 design preserves a snapshot at the start of each pair.

`--rollback-on-failure` requires every change to have a defined inverse. `~` and `+` recover via the previous-gen manifest stored on the activation. `-` of a stateful resource refuses to plan unless the engine has retained the manifest content. Without retention, the flag refuses and exits with an actionable error rather than silently downgrading.

## 7. What this doc is *not*

- Not a redesign of the planner, scheduler, migration mechanics, or backup contract — those have their own docs (81, 98, 67, 108).
- Not an operator-substrate move (90 §H, separate session).
- Not a multi-team operator UX (45, separate concerns).

This doc only specifies the operator-facing surface over what the engine docs build.

## 8. Open questions

1. **Plan fingerprint pinning at PR review.** Stamp the Plan fingerprint on the PR and refuse merge when the rebased Plan diverges. Defends against silent stateful-change drift introduced by rebase. Cost: a CI step that re-evaluates on each push.
2. **`cluster.out.alerts` surface for `kix status`.** Doc 110 ships PrometheusRule resources; the status view wants the *current firing state*. Read from Alertmanager directly (operational concern) or from a kix-side aggregator? Probably the former.
3. **Maintainership / authorship config shape for §4.2.** `clusters/<n>.nix`, package `meta`, or a separate `OWNERS`-style file? Different answers for monorepo vs federated (doc 45).
4. **Blast Radius rendering when the closure is wide.** A small change in cilium can dep-change every consumer. Always render the full transitive set, or cap at N with a `+M more` tail? Lean toward a cap with `--blast-full` to expand.
5. **Compact vs default vs verbose precedence.** Should the default text render include the per-resource lines under each `~` package, or stay one-line-per-package and require a flag to expand? Today's `print_package_plan` is one line per package + resources only under `-v`. The §3.1 example assumes default is the richer form; revisit once tried on a real ludo plan.

## 9. What to build first

Sequenced for L1–L4 of doc 90, smallest-first.

1. **Plan struct upgrade.** Extend `PackageDiff` (or a new `Plan` struct on top) to carry: per-package state (`changed`/`added`/`removed`/`dep-changed`), stateful-glyph flag, dep-changed cause pointer (one incoming `cross_deps` edge). Same struct feeds `kix diff`, `kix deploy` confirmation, and `kix status`.
2. **Stateful view.** Lift filter logic on `lifecycle=stateful` + `MigrationPair` into a reusable view function. Render at the top of the report.
3. **Blast Radius view.** Reverse-walk `cross_deps` from each `changed` package transitively. Render under By Package. Cap with a configurable `--blast-cap`.
4. **Glyph split (`~` vs `⤴`).** Update `print_package_plan` to render dep-changed packages with the dedicated glyph and the `cause:` line.
5. **`kix graph --diff`.** Add a diff overlay to the existing `kix graph` DOT/JSON output. Tags every node with its state and every edge as touched/untouched.
6. **`kix status` v0.** Static one-shot. Activation + drift + capability health. Read-only.
7. **CI authorship gate.** GitHub Action that consumes the Plan, evaluates per-change stateful flag, checks PR author against maintainer list.
8. **`--rollback-on-failure`.** Requires the engine to define inverse for every change kind and refuse-with-actionable-error when an inverse is unavailable.

Items 1–4 enrich the report itself and are the unblocking work. 5 gives the floor view. 6 unlocks the daily loop. 7 unlocks ludo-on-real-hardware confidence. 8 is quality of life.
