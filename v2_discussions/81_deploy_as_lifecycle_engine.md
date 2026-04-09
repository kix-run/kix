# 81 — Deploy as a Kind-Aware Lifecycle Engine

**Status:** RFC
**Related:** `28_gitops_deploy.md` (current GitOps feature surface), `43_activation_operator.md` (activation lifecycle, control loop), `archive/56_unified_operator_reconcile.md` (phase-based reconcile, implemented), `67_stateful_migration_orchestration.md` (stateful migration as a sibling feature consumed by this engine), `79_operator_readiness_edges.md` (DI-derived ordering edges that make this engine's input correct), `50_operator_crd_upgrades.md` (content-hash CRD ordering), `44_operator_remaining_work.md` (operator productionization), `29_compiler-design.md`

---

## 1. Why this RFC exists

The kix deploy engine works (`reconcile.rs`, `apply.rs`, `readiness.rs`, `waves.rs`, `activation.rs`). It walks waves, applies via SSA, polls per-kind health, prunes orphans, and persists progress. Doc 28 is the feature surface, doc 43/56 is the control loop, doc 67 covers stateful migration, doc 79 covers operator-backed ordering. The mechanics are in place.

What we *don't* have is a coherent answer to a simple question:

> When the user runs `kix deploy`, what experience are we trying to deliver?

The current implementation answers it implicitly: "apply manifests in dependency order, wait for `.status` to look healthy, prune the rest." That answer is fine for greenfield, stateless, well-behaved Kubernetes objects. It's wrong — or at best inadequate — for everything else:

- **Failure feedback is wall-clock-shaped**, not state-shaped. A 5-minute readiness budget is the same affordance for `ImagePullBackOff` (terminal in 2 seconds) and a slow-but-progressing rollout (legitimately needs more than 5 minutes). The user gets a generic timeout instead of an actionable error.
- **Updates pretend to be in-place**, then fall over on immutable fields. The current engine has a hardcoded "delete-then-apply for `kind == Job`" branch and nothing else. StatefulSet selectors, Service `clusterIP`, PVC specs, CronJob `jobTemplate.selector` all hit the same wall and surface as cryptic SSA 422s.
- **Prune is a delete loop.** Stateless prune is a `DeleteParams::default()` call. Stateful prune is gated by a manual `meta.lifecycle = "stateful"` annotation that nobody trusts because there's no recourse if you're wrong. There is no notion of *draining* a workload before it goes away, no notion of *handing off* traffic, no per-kind strategy.
- **Migration is a separate document** (67). It's RFC'd as a phase wedged between PLAN and APPLY, with its own user prompt. From the user's POV migration is just another transition the engine should know how to make — not a separate phase with a separate UX.
- **Operator concerns and CLI concerns drift apart.** `reconcile.rs` is shared between CLI and operator (good). But the operator needs cancellation, in-cluster watch streams, leader election, structured events. The CLI needs interactive prompts, terminal-rendered live status, dry-run-as-object. They're fighting over one engine that doesn't have the right primitives for either.

This RFC reframes deploy *as a single concept*: a **kind-aware lifecycle engine** that drives the cluster from one known closure to another, treating each Kubernetes kind as having its own transition machine. The engine knows how each kind likes to be created, updated, recreated, drained, migrated, and removed — and surfaces structured progress and structured failure throughout. The CLI and operator are two front-ends over the same engine; the engine itself is what we're designing here.

The word "lifecycle" is load-bearing. Today the engine treats every resource as a noun. We want it to treat every resource as a verb that has a state machine: a Deployment is *being rolled out*, a PVC is *being bound*, a Job is *running once and being collected*, a StatefulSet is *being recreated with PVC retention*, a Service is *being drained before its endpoints flip*. The engine's job is to drive each of those state machines and report on them coherently.

---

## 2. The mental model

### 2.1 What deploy is, in one sentence

> Deploy drives the cluster from closure A to closure B by executing a per-kind state machine for every resource that differs, surfacing structured progress and structured terminal verdicts throughout, with bounded cost on success and bounded blast radius on failure.

Unpacking each clause:

- **Closure A to closure B.** Two known, immutable, content-addressed inputs. We never reason against live state to *decide* what to do. We may consult live state to *execute* (drain a Deployment, snapshot a PVC) or to *observe* (am I done?). This is the kix invariant from doc 43 §4.2.
- **Per-kind state machine.** Every kind has a known set of transitions it supports (create, update-in-place, recreate, scale, drain, snapshot, delete) and known terminal failure modes. The engine dispatches to the right machine for the kind. CRDs that don't have a registered machine get a generic fallback (apply + watch `.status.conditions`).
- **Structured progress.** Each transition emits typed events: "Deployment foo: 3/5 replicas ready, last change 4s ago, observed generation 17". Not free text. Not opaque dots in a spinner. Consumers (TUI, JSON, operator events, Prometheus) all read the same structured stream.
- **Structured terminal verdicts.** Failures are typed: `ImagePullBackOff { image, registry, reason }`, `FailedScheduling { unsatisfied: [...] }`, `ImmutableFieldConflict { kind, fields }`, `MigrationPaused { pair, reason }`. The CLI renders these as actionable lines; the operator emits them as K8s Events; the JSON consumer machine-parses them. *Same source of truth for all three.*
- **Bounded cost on success.** No re-doing work that's already done. Resume from any wave. Skip unchanged hashes instantly. Watch-based, not polling, so the steady-state cost is "API server pushed me an event."
- **Bounded blast radius on failure.** Halt at the smallest unit that makes sense (a wave, a single resource, a migration). Always leave the cluster in a state from which the user can fix-forward or roll back. Never partially-apply a transition that has a known atomic boundary (a migration pair must complete or revert; a recreate must finish or be retried, not abandoned half-deleted).

### 2.2 Three concentric loops

Doc 43 §3 shows the operator control loop. Doc 28 §4 shows the architecture as three layers. Both are correct but neither captures the layering this RFC needs. Here's the same picture, refactored:

```
┌─────────────────────────────────────────────────────────────┐
│ L1 — Activation loop                                         │
│   Triggered by: new closure, drift tick, manual invoke      │
│   Inputs:  closure A, closure B, policies                   │
│   Outputs: a Plan (ordered list of Transitions)             │
│                                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ L2 — Wave executor                                       │ │
│ │   Walks the Plan in DAG order                           │ │
│ │   For each wave: dispatch transitions in parallel        │ │
│ │   Between waves: gate on aggregated readiness            │ │
│ │   Cancellable, resumable, observable                    │ │
│ │                                                         │ │
│ │ ┌─────────────────────────────────────────────────────┐ │ │
│ │ │ L3 — Per-kind transition machine                     │ │ │
│ │ │   Apply / Recreate / Drain / Migrate / Delete        │ │ │
│ │ │   Per-kind: knows what to watch, what's terminal     │ │ │
│ │ │   Emits structured progress + structured verdicts    │ │ │
│ │ └─────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

The current code conflates L2 and L3 (`reconcile.rs` walks waves *and* polls readiness *and* hardcodes the Job recreate hack *and* prunes). Splitting them is most of the structural payoff of this RFC.

L1 is the activation loop from doc 43 — unchanged in concept, refined in what it produces (a Plan of typed Transitions, not a flat list of actions).

L2 is the wave executor — also mostly unchanged in concept, but cancellation-first and event-driven instead of polling.

L3 is new as a structured concept. Today we have an ad-hoc mix: `apply.rs` does SSA, `readiness.rs` polls per-kind status, `migrate.rs` (sibling crate from doc 67) handles migration. L3 unifies these as **transition machines** with a common interface.

---

## 3. Transitions: the new primitive

Today the engine plans `ChangeAction` values: roughly `Create`, `Update`, `Unchanged`, `Delete`. That vocabulary is too coarse. The first move of this RFC is to introduce **Transitions** as the planner's output: a typed enum that captures *what kind of change we are about to make to a resource*, with all the information the executor needs to drive it.

```
enum Transition {
    Apply       { rid, manifest },                      // SSA, in-place update or create
    Recreate    { rid, old, new, reason: RecreateReason, strategy: RecreateStrategy },
    Migrate     { pair: MigrationPair, strategy: MigrationStrategy },
    Drain       { rid, target_state: DrainTarget },     // scale-to-zero, cordon, traffic-shift
    Delete      { rid, strategy: DeleteStrategy },      // graceful | foreground | orphan | snapshot-then-delete
    Skip        { rid, reason },                         // unchanged, suppressed, externally-managed
    Pause       { reason: PauseReason },                 // wait for human approval, sync window, etc.
}
```

Transitions are produced by L1 from the closure diff plus per-kind rules plus user policy. They are consumed by L2 in DAG order. They are executed by L3 via the per-kind transition machine that handles their variant.

The win is that **the planner is now the place where decisions are made**, and the planner is testable, dry-runnable, and shown to the user before anything happens. The current engine makes decisions inside the reconciler (the Job hack, the prune-stateful prompt, the timeout-as-failure-classifier) — too late for the user to see them, too late for tests to cover them.

### 3.1 Why these specific variants

| Variant | Why it exists | What it replaces |
|---|---|---|
| `Apply` | The 80% case: SSA-apply a manifest, watch for readiness | The current `Create` + `Update` + `Unchanged-but-reapply` |
| `Recreate` | Immutable-field changes, kind-aware (Job, StatefulSet, Service `clusterIP`, PVC, etc.) | The hardcoded `kind == "Job"` branch in `reconcile.rs` |
| `Migrate` | Stateful transitions where data must move, not just resources | The MIGRATE phase from doc 67, lifted into the same Plan |
| `Drain` | Workload prep before deletion or recreation: scale-to-zero, cordon, shift traffic | Nothing — this is new; current engine just calls Delete |
| `Delete` | Removal, with per-kind strategy (graceful, foreground, orphan, snapshot-then-delete) | The current `DeleteParams::default()` blanket |
| `Skip` | Hash unchanged, externally-managed, lint-suppressed, or fingerprinted-as-equivalent | The current "in unchanged set" implicit skip |
| `Pause` | Gates: approval for stateful, sync windows, manual hold, freeze flags | Nothing — currently the CLI prompts and the operator just stalls |

The deliberate choice: **Drain is its own transition, not a hidden step inside Delete or Recreate.** This is what unlocks "smart prune." A Deployment removal in the new model is `Drain → Delete`. A StatefulSet recreation is `Drain → Snapshot → Delete(orphan PVCs) → Apply`. A migration is `Drain consumer → Migrate(pair) → Apply consumer`. The same Drain primitive composes into all three. (Section 6 expands.)

### 3.2 Hashing and identity

Two resources with the same content hash *are* the same store path (doc 43 §4.1). Identity-hash matching (doc 43 §9.3) lets the planner align "the postgres StatefulSet across closures" even when the content hash changes. The planner uses identity to *match*, content to *decide which transition*, and DAG position to *decide where in the wave order*.

A migration pair (doc 67 §2) is detected at planner time as a structural fact about the diff: same instance, same dep slot, both stateful, different content. That detection happens *before* the closure diff is turned into Transitions, so a pair doesn't show up as `Delete + Apply` — it shows up as `Migrate { pair, strategy }`. This is exactly what doc 67 §4.6 already proposes ("migrations happen within the normal deploy flow"), but framed as "the planner emits a different Transition type" rather than "the deploy loop has a special phase."

### 3.3 What the user sees

Because Transitions are the planner output, `kix diff` and `kix deploy --dry-run` can render them as the unit of explanation:

```
Plan for ludo@gen5:
  87 unchanged
   3 apply
        Deployment/n8n              (image bump)
        ConfigMap/n8n-config        (env change)
        Service/n8n                 (label change)
   1 recreate
        Job/n8n-migrate-v17         (immutable: spec.template.spec.containers[0].image)
                                    strategy: foreground delete, then SSA apply
   2 migrate
        immich/storage              local-path 100Gi -> zfs-tank 200Gi
                                    strategy: copy-local (rsync, ~45m), HIGH risk
        postgres/data               local-path 10Gi  -> zfs-tank 20Gi
                                    strategy: pg_dump+restore, CRITICAL risk
   2 drain+delete
        Deployment/old-worker       drain: scale-to-zero, wait pods Terminated
        ServiceAccount/old-worker   delete: foreground
   1 pause
        StatefulSet/postgres        gating: requires approval (HIGH risk migration above)
```

Compare to today's `Apply 6, Prune 3` and you can see why this is the framing we want.

---

## 4. Readiness as structured verdict, not timeout

Section 2 of `tmpdoc.md` already lays this out in detail; this RFC absorbs it as the design. Restated in this doc's vocabulary:

A transition machine for kind `K` consumes events from a watch stream and emits one of:

```
enum Verdict {
    Progressing { fingerprint, summary },     // still working, here's where we are
    Ready       { summary },                   // done, healthy
    Failed      { reason: TerminalReason, source, message }, // structured terminal failure
    Stalled     { last_change, summary },     // no progress in idle budget, escalate
}
```

`TerminalReason` is a closed enum of typed failure modes per kind: `ImagePullBackOff`, `CrashLoopBackOff`, `FailedScheduling`, `CreateContainerConfigError`, `ProgressDeadlineExceeded`, `BackoffLimitExceeded`, `PVCPendingNoProvisioner`, `ImmutableFieldConflict`, `WebhookRejected`, `QuotaExceeded`, etc. The CLI renders each as an actionable line; the operator emits each as a K8s Event with the same reason; the JSON consumer machine-parses them. **One source of truth, three renderings.**

Three independent budgets (also from `tmpdoc.md` §2):

- **`progress_idle`** — time since the fingerprint last changed. Defaults to 60-120s. Reset on every observed change. This is the *real* timeout for "is anything happening?"
- **`hard_ceiling`** — absolute upper bound, defaults to 30 min. Catches pathological cases where progress is microscopic but the rollout is dead.
- **`terminal_debounce`** — for noisy reasons (CrashLoopBackOff with restartCount<3) that need persistence to be considered terminal. Defaults to two ticks or restartCount≥3.

Wall-clock timeouts as the primary failure mode are gone. They exist only as the hard ceiling, the last-resort backstop.

The transition machine is **per-kind**. Deployment, StatefulSet, Job, DaemonSet, PVC, CRD, Pod, generic CR — each has its own machine that knows what fingerprint to compute, what events to subscribe to, and what classifier to run. This is the same fan-out that exists in `readiness.rs` today, but reorganized so the machine *owns* its watch stream and *emits* a Verdict, instead of being a function the polling loop calls. (See §10 for the trait sketch.)

### 4.1 Cancellation is non-negotiable

Every transition machine, every wave executor, every activation loop iteration takes a `CancellationToken`. The operator's reconcile loop *must* be able to cancel a 30-minute readiness wait when a newer Activation arrives. The CLI must be able to Ctrl-C cleanly. Today there is no cancel path; this is a hard prerequisite for everything else.

### 4.2 Watch-based, not poll-based

The current `readiness.rs` polls every 500ms via `get_opt`. The new model uses `kube::runtime::watcher` for both the resource itself and its dependent pods (resolved via selector). Events push into the transition machine. Polling exists only as a fallback for resources that don't expose useful watches (rare).

This is also where the operator loop wins: the operator already has informers for everything via leader-elected reflectors, and the transition machine just subscribes to the existing event stream instead of opening its own watch. CLI mode opens watches on demand.

---

## 5. Recreate: planner-side decision, not reconciler hack

This is the cleanest piece to extract from `tmpdoc.md` §1, restated in this RFC's vocabulary.

The planner decides `Recreate` when:

1. **Known immutable mutation.** A small per-kind registry maps known immutable field paths per kind: `Job.spec.template`, `StatefulSet.spec.{serviceName,selector,volumeClaimTemplates}`, `Service.spec.clusterIP`, `PersistentVolumeClaim.spec.*`, `Secret.type`, `CronJob.spec.jobTemplate.spec.template.spec.{volumes,nodeSelector}` (some), CRDs registered as immutable via `meta.recreateOn`.
2. **Identity-hash drift on tagged-immutable kinds.** Resources tagged via `meta.lifecycle = "stateful"` or kind tagged as "immutable on update" force `Recreate` even if the field-level diff doesn't catch it.

The reconciler is the *fallback safety net*: if SSA returns 422 with "field is immutable", the executor catches it as `ImmutableFieldConflict { fields }`, asks the planner for a Recreate transition for that resource, and retries. This catches the long tail (custom CRs with immutable fields, kinds not in the registry).

`RecreateStrategy` is per-kind:

| Kind | Default strategy | Why |
|---|---|---|
| `Job` | Foreground delete (kill pods), then apply | Pods must die before the new Job replaces them |
| `StatefulSet` | Orphan delete (retain PVCs), then apply | Never lose state by accident; recreate the controller, keep the data |
| `Service` (clusterIP change) | Orphan delete, then apply | Endpoints flip is the visible change; orphan keeps Endpoints from being collected |
| `PersistentVolumeClaim` | **Refuse — escalate to Migrate** | A PVC change is never just a recreate; it's a migration pair (doc 67) |
| Generic CR (lint-flagged immutable) | Foreground delete, then apply | Conservative default; user can override |

The "PVC recreate becomes Migrate" rule is the bridge to doc 67: the planner *upgrades* a Recreate transition into a Migrate transition when the affected resource is data-bearing. Same mechanism, different transition variant. The user sees the upgrade explicitly in the plan.

### 5.1 Cost flow

A Recreate transition has explicit cost flowing back to the user *in the plan*: "this will delete the old Job before creating the new one — the Job's pods will be killed." A Migrate transition has cost too: "this will scale down immich for ~45 minutes." The plan is where the user sees these costs and approves them. The reconciler never makes a cost-bearing decision the user didn't see.

---

## 6. Smart prune: drain, hand-off, snapshot

Section 1 of this RFC called out that prune is the dumbest part of the current engine. Restating the requirements coherently:

### 6.1 What "smart prune" means

A removal in the new model is **never** a one-step `Delete`. It's a sequence of transitions on the same resource, each of which can be inspected, gated, paused, and reasoned about:

```
Workload removal:    Drain → Delete
Stateful removal:    Drain → Snapshot → Delete(orphan or background, per policy)
Service removal:     TrafficShift → Drain → Delete
Operator removal:    DrainConsumers → Delete
Namespace removal:   DrainAll → DeleteContents → Delete(namespace)
```

Drain is a first-class transition (see §3). What "drain" means is per-kind:

| Kind | Drain semantics |
|---|---|
| `Deployment` | Scale to zero, wait for pods Terminated (with grace period) |
| `StatefulSet` | Scale to zero, wait for pods Terminated. Optionally take volume snapshots first. |
| `DaemonSet` | Cordon nodes? Or just delete (DaemonSet pods can't really be drained without node cordon) |
| `Job` | Skip (Jobs are run-once; either complete or not) |
| `CronJob` | Suspend, wait for active Jobs to finish |
| `Service` | Optionally shift traffic to a successor (blue-green); otherwise no-op |
| `Ingress` / `HTTPRoute` | Optionally remove from controller before backend goes away |
| `Pod` (bare) | Eviction with grace |
| Generic CR | Look for `meta.drain` hint in package; otherwise no-op |

Drain has bounded cost (a configured grace period) and reports progress like any other transition. If drain fails to complete in budget, the transition emits a `Stalled` verdict and the user sees what's hanging.

### 6.2 Per-kind delete strategy

Today: `DeleteParams::default()` which is foreground-on-finalizers and can hang forever. The new model picks per-kind:

- **Background** for most things — fire and forget, K8s will clean up
- **Foreground** when the parent must wait for children (rare)
- **Orphan** for StatefulSets (retain PVCs), Services with `clusterIP` (retain Endpoints during recreate)
- **Snapshot-then-delete** for stateful resources where the user opted into a safety net (`cluster.migration.snapshotBefore = true` from doc 67 §6.2)

The strategy is decided by the planner from per-kind defaults plus package `meta.delete` hints plus user policy. The reconciler executes whichever strategy is in the Transition.

### 6.3 Dependency-aware ordering

Pruning today walks orphans in reverse wave order *within the orphan set*. That's wrong when orphans depend on non-orphans (an orphan ConfigMap mounted by a non-orphan Pod). The new planner pulls orphans into the same DAG as the rest of the Plan and topologically orders them with everything else, so a `Drain → Delete` transition for `Deployment/old-worker` happens before the `Delete` of its `ServiceAccount/old-worker`, and the `Delete` of a `Secret/foo` is *blocked* if any non-orphan resource still mounts it (planner refuses, reports as `OrphanBlocked` in the Plan).

This is the same mechanism that doc 79's "operator-backed readiness edges" provides for additions. We use it symmetrically: an addition's edges become "wait for the controller to be Active before applying"; a removal's edges become "wait for consumers to be drained before deleting." Same DAG, opposite direction.

### 6.4 Hand-off: blue-green and traffic shift

A common case: a Service is being replaced by another Service with a different selector (or a Gateway is being swapped, or an HTTPRoute is being repointed). The naive prune deletes the old Service and the cluster has a window of broken endpoints.

The new model expresses this as a `TrafficShift` transition (a specialization of Drain) that moves clients from old to new before deleting old. For a Service swap that's an Endpoints swap; for an HTTPRoute that's a `weight` shift; for an Ingress that's a controller-specific rewrite.

This is opt-in via `meta.handoff` on the package or via policy. It's not the default for greenfield because the simpler "delete and recreate" works. But once you ask "how does this engine handle production traffic during a rename?", the answer needs to be "via this transition," not "you're on your own."

### 6.5 Stateful prune is just "Migrate to nothing"

The current `pruneStateful: prompt | auto | disabled` policy from doc 43 is a single boolean per cluster. In the new model:

- A stateful resource with a successor in the new closure → `Migrate(pair)` (doc 67, planner detects the pair).
- A stateful resource with no successor → `Drain → Snapshot → Delete(orphan)`, gated by a `Pause` transition that requires explicit approval.

The `Pause` is the planner saying "I will not execute this without you confirming." The CLI prompts; the operator marks the Activation status as `BlockedOnApproval` and waits for an annotation flip; CI can pre-approve via a flag. *Same gate, three front-ends.*

The `pruneStateful` policy degrades to a default for the gate behavior (`auto` means the planner doesn't insert a `Pause`; `prompt` means it does; `disabled` means it inserts a `Refuse` which fails the plan).

---

## 7. The Plan as a first-class object

Doc 43 §4.5 introduces "speculative activation" — dry-run as a CR. This RFC formalizes that: the **Plan** is the canonical product of the planner, and it's a first-class, serializable, persistable object that the user, the CLI, the operator, the JSON consumer, and CI all agree on.

A Plan is:

```
Plan {
    activation: ActivationRef,
    from_hash: ClosureHash,
    to_hash:   ClosureHash,
    transitions: Vec<Transition>,        // ordered by wave
    waves: Vec<WaveSpec>,                 // wave -> transition indices
    risks: Vec<Risk>,                     // structured risk findings
    gates: Vec<Gate>,                     // pauses, approvals, sync-windows
    estimated: PlanEstimate,              // time, downtime, blast radius
}
```

What this enables:

- **`kix diff` shows the Plan** — same object the deploy will execute. No second-rendering bugs.
- **`kix deploy --dry-run` is a Plan that's never executed.**
- **Speculative activation** (doc 43 §4.5) is a Plan persisted to a `dryRun: true` Activation CR.
- **CI gates on Plan content** — "fail merge if `risks` contains any `HighRisk`."
- **Operator approval flow**: the operator persists the current Plan in `status.plan` while a `Pause` gate is open, and a human flips `metadata.annotations[kix.dev/approved]: true` to release it.
- **Audit log**: every executed deploy persists its Plan in the activation history. Rollback isn't "re-apply old hash blind"; it's "execute the *inverse Plan*."

The Plan is the contract between L1 (decision-making) and L2 (execution). Tests target the Plan (planner tests are unit-testable without K8s); execution tests target the wave executor against synthetic Plans.

### 7.1 Plan is the user contract

A subtle but important consequence: **the engine never makes a decision the user didn't see in the Plan.** If a transition fails and the engine needs to fall back (SSA 422 → Recreate), it doesn't silently do the fallback — it pauses the wave, surfaces the structured failure, and the *next* deploy iteration produces a new Plan that includes the Recreate transition, which the user accepts (or which an `--auto-fallback` flag pre-accepts).

This is stricter than today's behavior, and deliberately so. The current engine has hidden decisions everywhere (the Job hack, prune ordering, SSA force-conflicts) and they're each responsible for surprising users in production. The new engine's invariant: *every cost-bearing action is in the Plan, and the user/policy approved the Plan.*

---

## 8. Status classification: the k9s frame

The `tmpdoc.md` discussion mentioned "k9s-like status classification." Here's what that means in this RFC's frame.

k9s's win is that it presents a *running cluster* as a grid of typed objects, each with a color-coded status that you can scan in a glance. The status comes from the same per-kind classifier we want for readiness: a Pod is `Running`, `CrashLoopBackOff`, `ImagePullBackOff`, `CompletedSuccessfully`, etc. The user always knows whether the thing they're looking at needs attention.

`kix deploy` should present the *deploying cluster* the same way:

```
Activation: ludo@gen5  Deploying  wave 4 of 6

Wave 4  3 transitions in flight, 5 done, 0 failed

  ✓ Apply       Deployment/n8n              ready (3/3)               2m14s
  ⟳ Apply       Deployment/immich-server    progressing (2/3 ready)   1m02s
  ⏸ Pause       Migrate immich/storage      awaiting approval         —
  ✗ Apply       Deployment/photoprism       ImagePullBackOff: registry.example.com/photoprism:v3 not found
                                            (1 of 1 pods, 4 retries)  18s

Wave 5  blocked on wave 4
Wave 6  blocked on wave 5
```

Each line is a Transition + a Verdict. The colors and symbols are decoration; the structured status underneath is what makes it possible. JSON output of the same is:

```json
{
  "activation": "ludo", "generation": 5, "phase": "Deploying", "wave": 4,
  "transitions": [
    { "rid": "Deployment/n8n", "kind": "Apply", "verdict": "Ready", "duration": "2m14s" },
    { "rid": "Deployment/immich-server", "kind": "Apply", "verdict": { "Progressing": { "ready": 2, "desired": 3 } } },
    { "rid": "immich/storage", "kind": "Migrate", "verdict": { "Paused": { "reason": "AwaitingApproval" } } },
    { "rid": "Deployment/photoprism", "kind": "Apply",
      "verdict": { "Failed": { "reason": "ImagePullBackOff", "image": "registry.example.com/photoprism:v3", "retries": 4 } } }
  ]
}
```

Same data, two consumers. The TUI is built on top of the JSON stream. Operator events are individual JSON entries reformatted as K8s Events. The classifier code is shared.

---

## 9. Operator and CLI as front-ends over the same engine

The current code splits roughly: `kix-operator/` (binary), `cli/kix/` (engine library, with a CLI binary). The library is shared. This RFC keeps that split and clarifies it:

**The engine library** (`cli/kix/`) owns:
- Closure differ
- Planner (produces `Plan`)
- Wave executor (consumes `Plan`, drives transition machines)
- Per-kind transition machines (apply, recreate, migrate, drain, delete)
- Per-kind classifiers (Verdict, fingerprint, terminal reason detection)
- Cancellation and resume primitives
- Structured event stream (the JSON above)
- Persistence interface (where to write Plans, Verdicts, Activation status)

**The CLI binary** (`kix-cli/`) is a thin wrapper that:
- Builds the closure (or accepts one)
- Calls the planner
- Renders Plans as text (for `kix diff`, `kix deploy --dry-run`)
- Renders the structured event stream as a TUI (for `kix deploy`)
- Handles interactive approval prompts (Pause transitions)
- Writes Plans and history to local state

**The operator binary** (`kix-operator/`) is a thin wrapper that:
- Watches Activation CRs (informer)
- Calls the planner on Activation create/update
- Persists Plans into `status.plan` (or a sidecar `Plan` CR)
- Subscribes to the structured event stream and translates to K8s Events
- Surfaces Pause transitions as `status.phase=BlockedOnApproval` + waits for annotation
- Handles leader election, drift ticks, GC on Activation deletion

Neither front-end has its own engine logic. This is mostly already true; the RFC's contribution is making the boundary *strict* and the structured event stream the wire format between layer 3 and the front-ends.

### 9.1 What the operator additionally needs

Doc 44 lists "operator remaining work" — OCI transport, drift detection, controller runtime. This RFC adds:

- **Cancellation plumbing.** Every reconcile that the operator starts must be cancellable when a newer generation arrives. Today's engine has no cancel; this is a hard blocker.
- **Watch reuse.** The operator already has informers for everything. Per-kind transition machines should accept an injected event stream, so the operator passes its informer cache instead of opening fresh watches.
- **Structured events as K8s Events.** Each Verdict translates to a K8s Event on the Activation CR (or on the affected resource). `kubectl describe activation prod` should show the same actionable lines the CLI shows.
- **Pause as a first-class status.** The `Activation` CR gains `status.phase = BlockedOnApproval` and `status.gate = { reason, expected_annotation }`. No new CR needed — gate state lives on the activation.

### 9.2 What the CLI additionally needs

- **Live TUI** on the structured event stream. Today the deploy CLI prints lines linearly. The new model is a redrawable status grid (like k9s) backed by the event stream. Falls back to line-based output when not a TTY or when `--no-tty`.
- **Interactive approval** for Pause transitions, with a non-interactive `--yes` and a JSON-output mode for CI.
- **Plan diffing** for `kix diff` — render two Plans side by side, or a single Plan as the "what would happen" view.

---

## 10. What stays out of scope for this RFC

To keep this landable, the following are explicitly *not* this RFC's job:

- **Implementing the per-kind transition machines.** This RFC defines the trait and the contract; the implementations (Deployment machine, StatefulSet machine, Job machine, ...) are follow-up design docs. There may be one design doc per kind family or one for all of them — that's an implementation choice.
- **The migration strategy registry.** Doc 67 owns this. This RFC consumes it via the `Migrate` transition.
- **Operator-backed ordering edges.** Doc 79 owns this. This RFC consumes it via "the planner uses the DAG, including ordering edges."
- **OCI transport, leader election, controller-runtime.** Doc 44 owns these. This RFC's plumbing changes (cancellation, structured events, watch reuse) are *prerequisites* for those becoming production-ready, but the production-readiness work itself is its own track.
- **Drift detection semantics.** Doc 28 §3.1 and `kix health` cover this. Drift is a *trigger* for the activation loop in this RFC; what counts as drift is defined elsewhere.
- **Handoff implementations** (traffic shift, blue-green). The transition exists; the per-controller implementations are follow-ups.

What this RFC commits to:

1. The Plan/Transition vocabulary (§3, §7).
2. The L1/L2/L3 layering (§2.2).
3. Verdicts replacing wall-clock timeouts (§4).
4. Recreate as a planner decision with reconciler fallback (§5).
5. Drain as a first-class transition (§6).
6. Cancellation and watch-based execution as hard requirements (§4.1, §4.2).
7. CLI and operator as thin wrappers over the engine (§9).

---

## 11. Sketch: the trait surface

Just enough code to make the contract concrete. Real names and types will shift in implementation.

```rust
// L1 — Planner

trait Planner {
    fn plan(&self, from: &Closure, to: &Closure, policy: &Policy) -> Plan;
}

// L2 — Wave executor

trait WaveExecutor {
    async fn execute(
        &self,
        plan: &Plan,
        ctx: ExecCtx,           // events sink, persistence, cancellation
    ) -> ExecResult;
}

// L3 — Per-kind transition machine

trait TransitionMachine: Send + Sync {
    fn handles(&self) -> &[KindMatcher];

    async fn execute(
        &self,
        transition: &Transition,
        ctx: TransitionCtx,     // events sink, kube client, watch source, cancel
    ) -> Verdict;
}

// L3 — Per-kind classifier (used by the apply machine and friends)

trait Classifier: Send + Sync {
    fn fingerprint(&self, snapshot: &ResourceSnapshot) -> Fingerprint;

    fn classify(
        &self,
        snapshot: &ResourceSnapshot,
        events: &[Event],
        history: &ClassifyHistory,
    ) -> Verdict;
}

// Shared structured event

struct EngineEvent {
    activation: ActivationRef,
    generation: u64,
    wave: u32,
    rid: ResourceId,
    transition_kind: TransitionKind,
    verdict: Verdict,
    timestamp: SystemTime,
}
```

Each piece is independently testable (planner against fixture closures; transition machines against fake kube clients; classifiers against fixture snapshot+event sequences).

---

## 12. Migration / compatibility

- **Existing `reconcile.rs`** is refactored into L2 + a thin compatibility shim. The wave loop becomes the new wave executor.
- **Existing `apply.rs`** becomes the body of the `Apply` transition machine.
- **Existing `readiness.rs`** classifiers become per-kind `Classifier` impls; the polling loop is deleted in favor of watch-based machines.
- **Existing `migrate.rs`** (from doc 67) becomes the body of the `Migrate` transition machine.
- **Existing `Activation` CR** schema gains `status.plan`, `status.gate`, and richer `status.waves[].transitions[]`. No breaking removal of existing fields.
- **Existing `kix diff`** becomes a Plan renderer rather than a manifest differ.
- **Closure format** is unchanged. `packageIndex.json` is unchanged. The DAG and content-hash invariants are unchanged.

The CLI's output changes shape (TUI grid instead of linear lines). The JSON output gains the structured event stream. The operator's K8s Events on Activations gain structured reasons. None of these break programmatic consumers because there are no programmatic consumers today.

---

## 13. Open questions

1. **Per-kind machine registry: pluggable or compiled-in?** First implementation is compiled-in. Pluggable (via WASM, dlopen, gRPC sidecar) is appealing for community-contributed CR machines but adds large surface. Default: compiled-in, with `meta.lifecycle` / `meta.drain` / `meta.handoff` hints on packages providing per-CR customization without needing a full machine.

2. **Where does the Plan live during a long deploy?** Options: in-memory only (CLI mode), in `Activation.status.plan` (operator mode), in a separate `Plan` CR, in the closure as a derived store path. Probably: `status.plan` for operator (lives with the activation), in-memory + local JSON for CLI. Worth deciding before implementation.

3. **Plan stability across re-evals.** If the operator computes a Plan, persists it, and the source closure hasn't changed but live state has (drift), should it recompute the Plan? Probably yes — a Plan is a function of `(from, to, live)` for the few cases where live state matters (existing PVC bindings, current replica counts). Needs a clear "Plan is stale, recompute" trigger.

4. **Approval scope.** A `Pause` gate on a single transition vs. on a wave vs. on the whole Plan. Granularity affects the UX of "I approved the migration, why is it still asking?" Probably: gates are at the Plan level by default (`approved=true` releases all gates), with optional per-transition gating for high-risk cases like multi-stage migrations.

5. **Inverse Plans for rollback.** Conceptually clean; mechanically requires that every transition has an inverse (Apply ← Apply previous, Recreate ← Recreate previous, Migrate ← reverse migration, Drain ← undrain/scale-back). Some inverses are well-defined; some (Migrate of pg_dump+restore) are not. May need a `rollbackable: bool` per transition kind, and rollback that refuses or warns when non-rollbackable transitions are in the path.

6. **Drift remediation as a Plan.** Today drift is "kix health" → re-apply the changed resource. In the new model, drift is just another trigger for `plan(from=current_intended, to=current_intended)` where the live state has diverged. The Plan's transitions should describe the drift and the user should approve a remediation Plan rather than getting a silent re-apply. Probably a v2 enhancement; v1 keeps drift remediation as today.

7. **Cost estimation accuracy.** The Plan claims an estimate (time, downtime). How accurate does it need to be? The CLI/operator should display estimates with confidence levels and refine them as transitions execute. Imperfect estimates are still useful; pretending to be perfect is harmful.

8. **What is the canonical Verdict for "the resource exists, looks fine, but isn't tagged with a kix annotation"?** I.e., adoption of unmanaged resources. Doc 68 (live cluster compatibility) touches this. Probably: a `Skip { reason: ExternallyOwned }` transition with an explicit opt-in to take ownership.

9. **Cancellation semantics.** Cancellation mid-transition: does the engine try to leave the cluster in a clean state? For Apply, probably yes (let the SSA finish, don't poll readiness). For Recreate mid-delete, can't undo. For Migrate mid-copy, can roll back to source PVC. Each transition machine needs to declare its cancellation semantics.

10. **Sync windows and freezes** (doc 43 §4.6). These are policy-level Pause gates inserted by the planner. Easy in this model; flag this as an early win.

---

## 14. Why this is the right reframe

Today we have ~6 documents covering deploy from different angles, each adding a feature: continuous reconciliation (28), activation lifecycle (43), CRD upgrades (50), unified phases (56), stateful migration (67), operator-backed edges (79). They all exist because the question "what is deploy" was answered piecemeal.

This RFC's claim is that *one* answer covers all six, and the answer is: **deploy is a kind-aware lifecycle engine that drives the cluster through typed transitions, with structured progress and structured verdicts, planned up front and executed wave by wave with cancellation and resume.** Every existing doc is then either a feature consumed by the engine (67's migration pairs become `Migrate` transitions; 79's ordering edges feed the planner's DAG; 50's content hashing feeds Recreate detection) or a productionization concern around it (43's persistence, 44's transport, 56's phasing).

The reframe isn't replacing those docs — it's giving them a shared spine. The next design docs (per-kind transition machines, the structured event stream wire format, cancellation plumbing, the Plan persistence format) all sit underneath this spine and can be written and shipped independently because the contract between layers is now explicit.

The smallest first slice that proves the model:

1. Define `Transition`, `Verdict`, `Plan`, `EngineEvent` types in the engine library. No new behavior yet.
2. Refactor `apply.rs` + `readiness.rs` into one `Apply` transition machine + a per-kind classifier registry. Verdicts replace timeouts. Watch-based.
3. Add cancellation plumbing through reconcile end to end.
4. Move the Job hack into a planner-side `Recreate` transition with the per-kind registry. Delete the hack from `reconcile.rs`.
5. Render the structured event stream in the CLI as the new deploy output (initially line-based, TUI grid as a follow-up).
6. Introduce `Drain` as a no-op transition the planner inserts before Delete for known workload kinds, with `Deployment` getting scale-to-zero semantics first.

That's a coherent first PR (or PR series) that proves the structural reframe without depending on doc 67 or doc 79 landing first. Migration, traffic shift, smart prune strategies, operator approval gates, and the TUI all become incremental additions on top of an engine that now has the right shape.

---

## 15. Next step

If accepted, this RFC spawns:

- **Design doc:** per-kind transition machine registry and the `Apply` machine implementation
- **Design doc:** structured event stream and Verdict taxonomy (the closed enum of `TerminalReason`s)
- **Design doc:** the Plan persistence format and operator approval flow
- **Design doc:** smart prune — Drain transition implementations per kind, handoff strategies
- **Design doc:** cancellation and resume semantics across the three layers

Doc 67 (stateful migration) stands as-is and is consumed via the `Migrate` transition. Doc 79 (operator-backed ordering edges) stands as-is and feeds the planner's DAG. Doc 44 (operator productionization) consumes this RFC's cancellation and structured event work as prerequisites and lands in parallel.
