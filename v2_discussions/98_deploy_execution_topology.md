# 98 — Deploy Execution Topology: Diff-Before-Waves, and DAG-Streaming vs. Wave Barriers

**Status:** Draft (Brainstorm / RFC)
**Related:** `81_deploy_as_lifecycle_engine.md` (spine; this doc refines L2), `93_flavor_barrier_resource.md` (prior art: barrier as synthetic DAG node), `67_stateful_migration_orchestration.md`, `archive/79_operator_readiness_edges.md`, `archive/28_gitops_deploy.md`

---

## 1. Motivating questions

Two concrete questions about how `kix deploy` sequences work, posed against the current implementation (`cli/kix/src/cluster/waves.rs:25`, `cli/kix/src/cluster/reconcile.rs`):

1. **Does running the closure diff *before* wave computation change anything?** Today waves are computed from the graph alone, and the diff's role is to mark each resource in each wave as unchanged/changed. Would feeding the diff into wave computation produce different (smaller, fewer) waves, or are the waves structurally invariant under diff?
2. **Are waves even the right execution topology?** A slow resource in wave N blocks every resource in wave N+1, including resources that don't actually depend on it. A nix-build / nix-output-monitor–style model would start every resource as soon as its *direct* predecessors are Ready, independent subtrees would stream through in parallel, and the user would see a live per-resource status grid rather than "wave 4 of 6, waiting on Deployment/foo."

Doc 81 already reframes deploy as three layers (L1 planner / L2 wave executor / L3 per-kind transition machine) and flags that the wave executor is "cancellable, resumable, observable, event-driven." It does *not* take a position on waves-vs-DAG-streaming. This doc is the follow-up that does.

---

## 2. Current shape, in one picture

```
closure A ──┐
            ├─► differ ──► per-resource ChangeAction  (Create | Update | Unchanged | Delete)
closure B ──┘                           │
                                        ▼
graph ────────────────────────────► compute_waves ──► Vec<Vec<NodeIndex>>
                                                              │
                                                              ▼
                                          wave_executor: for each wave
                                             apply all, then poll readiness of all, then advance
```

Two properties worth noting:

- **`compute_waves` (`waves.rs:25`) is pure topological leveling.** It reads the DAG structure and nothing else. Unchanged vs. changed doesn't enter. The shape of waves is invariant under diff.
- **The wave executor does fast-path all-unchanged waves** (`reconcile.rs:332`) — if every `ChangeAction` in a wave is `Unchanged`, it increments a counter and moves on without calling the API server. So the cheapest possible per-wave cost for a no-op wave already exists today.

This is the baseline against which we evaluate both questions.

---

## 3. Question 1 — Does diff-before-waves change the waves?

### 3.1 Short answer

**Under the current `ChangeAction` vocabulary: no, waves are invariant under diff.** Waves are a function of the DAG, not of which nodes are no-ops. Re-ordering "compute diff, then compute waves" would produce byte-identical wave structure.

**Under doc 81's `Transition` vocabulary: yes, but only because the diff-to-Transition step *synthesizes new DAG nodes and edges*.** The wave-shape change is not a property of the diff itself; it is a property of the *planner's rewrite of the graph* in response to the diff.

This is the distinction worth making explicit. Let's unpack it.

### 3.2 Why waves are diff-invariant in the current model

The DAG edges express "A depends on B" — e.g., Deployment-foo depends on ServiceAccount-foo depends on Namespace-foo. Those edges exist regardless of whether A, B, or the Namespace changed this deploy. The topological level of a node is determined by its distance from the roots, which doesn't shrink just because some ancestors are unchanged.

Even if we "collapse" unchanged chains (replace a chain of all-Unchanged ancestors with a single Skip), the *dependent* of the chain still sits at the same level — it still waits (conceptually) for its parent to be Ready, and the parent is trivially Ready because it was a no-op. Waves don't shrink; they just get cheaper.

The fast-path in `reconcile.rs:332` already captures the entire runtime benefit. A wave of 50 unchanged resources costs a counter increment and an activation checkpoint write. There is no additional win from pre-pruning the graph.

### 3.3 Why waves *do* change under the Transition model

Doc 81 §3 replaces `ChangeAction` with `Transition`:

```
Apply | Recreate | Migrate | Drain | Delete | Skip | Pause
```

Most of these introduce structure the original graph doesn't have:

| Transition | Synthetic structure it adds |
|---|---|
| `Recreate` | A synthetic atomic boundary: `Drain → Delete(old) → Apply(new)` must not interleave with dependents' rollouts. This is a sub-graph the planner synthesizes for *this* deploy only. |
| `Migrate` | A migration-pair barrier: both halves of the pair must complete or revert together. Dependents on either half must wait for the barrier, not for the individual resources. Doc 67's "pair" becomes a DAG node. |
| `Drain` | New predecessor edges: consumers must drain *before* the provider they're draining from is deleted. Doc 81 §6.3's "removal edges are reversed." |
| `Pause` | A barrier node (approval gate) that dependents must wait on. |
| `Skip` | Transparent: can be collapsed, but as §3.2 shows, doesn't shrink waves anyway. |

So the correct ordering is:

```
closure A ──┐
            ├─► differ ──► resource-level diff
closure B ──┘                  │
                               ▼
  kind rules + policy ──► planner ──► Plan = Vec<Transition>  (may add nodes/edges)
                               │
                               ▼
                        compute_waves  OR  DAG stream (§4)
```

The diff is an **input to the planner**, not to wave computation. The planner may rewrite the graph (synthesize atomic boundaries, barrier nodes, reversed edges for drains). Wave computation (or stream scheduling) runs over the rewritten graph.

### 3.4 Consequence: "diff-before-waves" is really "planner-before-waves"

The phrasing of question 1 hides the interesting bit. What we actually want is:

> The planner runs *before* the executor, produces a Plan that includes any synthesized nodes/edges, and the executor consumes that Plan.

Doc 81 already proposes exactly this (§3, §7). This doc just reinforces that the wave-computation code must move from "run over the resource graph" to "run over the Plan's graph" — because the Plan's graph is not identical to the resource graph.

**Action item for the existing code path:** `compute_waves` should take the Plan, not the raw `ResourceGraph`. Today it takes `&ResourceGraph`, which is fine as long as no synthetic nodes exist. The moment Recreate/Migrate/Drain/Pause land, the signature must change.

---

## 4. Question 2 — Waves or DAG streaming?

### 4.1 The head-of-line-blocking problem

Waves have one structural weakness, independent of implementation quality: **wave barriers synchronize dependents that don't share a dependency**.

Example from a real deploy on ludo-kind:

```
wave 3: [cert-manager-webhook Deployment, n8n Deployment, grafana Deployment]
wave 4: [cert-manager Certificate for n8n, dashboards for grafana, ...]
```

`cert-manager-webhook` genuinely takes ~60s to become Ready. `n8n` takes ~8s. `grafana` takes ~5s. In the current wave model, the Certificate for n8n and the dashboards for grafana both wait 60s for the webhook — even though the dashboards have no dependency on the webhook whatsoever. The wave barrier blocks unrelated subtrees.

This is the same pathology `nix-output-monitor` solves for Nix builds: builds are a DAG, but we render them with level-based "rounds" at our peril. Nix itself uses a work-stealing scheduler — each derivation starts as soon as its direct predecessors have output paths. `nom` just renders the live state of that scheduler.

### 4.2 What DAG streaming looks like

Every transition becomes ready to execute the moment **its own direct predecessors have emitted `Verdict::Ready`** (doc 81 §4 vocabulary). The executor maintains a ready-queue:

```
ready_queue: priority queue of transitions whose predecessors are all Ready
in_flight:   set of transitions currently executing (watch streams subscribed)
blocked:     transitions waiting on at least one non-Ready predecessor
```

On every `Verdict::Ready` event, the executor walks the direct dependents of that resource, decrements their in-count, and promotes to `ready_queue` when it hits zero. Concurrency is bounded by a semaphore (today: `READINESS_CONCURRENCY`). Cancellation (doc 81 §4.1) is already expressible because each in-flight transition holds a `CancellationToken`.

This is mechanically the same as Nix's build scheduler, and it is the same event loop the operator's watch-based reconciler already wants to run.

### 4.3 What we gain

- **No cross-subtree head-of-line blocking.** The n8n Certificate fires the moment n8n is Ready, regardless of the webhook.
- **Natural match for watch-based readiness.** Doc 81 §4.2 kills the polling loop; once every transition is event-driven, there's no wave-level polling barrier to maintain. Promotion to the ready-queue is a direct consequence of a `Verdict::Ready` event.
- **Honest progress.** A live per-resource status grid (see §5) replaces "Wave 4 of 6, ?/? done." The user sees which resources are slow and which subtrees are advancing. No more guessing whether the bar has moved.
- **Better parallelism on wide clusters.** The ludo demonstrator has multiple large independent subgraphs (cert-manager, cilium, monitoring, apps). Waves serialize their completion at the deepest level of any subgraph. Streaming parallelizes them.
- **Synthetic barriers become explicit, not implicit.** When we *do* want a barrier (PlatformBarrier from doc 93, migration-pair boundary, user approval gate), it's a DAG node with its own Verdict semantics — not a fold-in-the-wave-executor special case. Doc 93 has already pioneered this direction for flavor infrastructure; DAG streaming completes the pattern.
- **Trivially resumable.** Resume state is "the set of transitions with `Verdict::Ready` persisted to the Activation." The ready-queue reconstructs itself from predecessor state. No wave index to checkpoint against.

### 4.4 What we give up / what gets harder

- **Checkpointing granularity.** Waves were a convenient "save every N resources" boundary (`accumulated_waves` in `reconcile.rs:309`). Streaming needs a different checkpoint rhythm: e.g., persist whenever a transition reaches a terminal Verdict, batched. Not hard, but not free.
- **Failure-scoping policy becomes explicit.** Waves implicitly stop the world on any failure in wave N (nothing in wave N+1 runs). Streaming must decide: "halt all subtrees? halt only dependents of the failed resource? continue independent subtrees?" The honest answer is **halt-dependents, continue-independents** (matches nom, matches Nix), but this is a new policy to state and document.
- **Determinism for testing.** Waves give a reproducible "apply sequence" for tests. Streaming introduces scheduler-order nondeterminism. Mitigated by: (a) tests assert on Plan structure and final state, not intermediate order; (b) a `--strict-waves` debug flag can force wave-mode execution for test reproducibility.
- **Rendering is different code.** Not harder, just different. Today's CLI renderer walks waves linearly. A streaming renderer needs an in-place updateable grid (ratatui, indicatif, or doc 81 §8's TUI).
- **Operator event emission.** The operator emits K8s Events at wave boundaries today. Streaming emits per-transition events. That's actually an improvement — finer-grained audit — but changes downstream consumers.

### 4.5 Waves still have a role — as a rendering axis

Even with DAG streaming for execution, the topological levels computed by `compute_waves` are a useful **display axis**: group the TUI rows by depth so the user reads a top-down dependency picture rather than a random scheduler order. This is what nom does: work-steal the scheduler, render by depth/kind grouping.

Proposed division:

| Concern | Backed by |
|---|---|
| Execution order | DAG streaming from the Plan |
| Display grouping | Topological levels (same as today's `compute_waves`, run over the Plan graph) |
| Checkpointing | Per-transition Verdict persistence, batched |
| Failure scope | Halt direct-and-transitive dependents; siblings continue (overridable) |
| Barriers | Explicit DAG nodes (PlatformBarrier, migration pair, Pause) |

### 4.6 Nix / NOM analogy, explicit

| Nix / nom | kix deploy (streaming) |
|---|---|
| Derivation | Resource / Transition |
| Input derivation | DAG predecessor |
| Build scheduler | Wave-free DAG scheduler |
| Output path realized | `Verdict::Ready` |
| nom's live view | TUI status grid (doc 81 §8) |
| Fixed-output / substitute | `Transition::Skip` (unchanged hash) |
| Build failure halts dependents | `Verdict::Failed` halts dependents, siblings continue |
| `--max-jobs` | Transition concurrency semaphore |

The analogy is tight enough that the mental model for "kix deploy" becomes "nix-build for your cluster" — a pitch that lands easily with the target user.

---

## 5. The user experience we are actually after

A single redrawable grid, grouped by topological depth, with per-transition structured Verdict:

```
Activation: ludo@gen5   Deploying   87 done · 12 in-flight · 3 pending · 0 failed

L0  ✓ Namespace/cert-manager                             (skip, unchanged)
    ✓ Namespace/monitoring                               (skip, unchanged)
L1  ✓ ServiceAccount/cert-manager                        apply      1.2s
    ✓ CRD/certificates.cert-manager.io                   apply      2.8s
L2  ⟳ Deployment/cert-manager-webhook                    apply     38s  (2/3 ready, last change 4s ago)
    ✓ Deployment/grafana                                 apply      5.1s
    ✓ Deployment/n8n                                     apply      7.9s
L3  ⟳ Certificate/n8n-tls                                apply     12s  (waiting: webhook not ready)
    ✓ ConfigMap/grafana-dashboards                       apply      0.4s
    ◇ Job/n8n-migrate-v17                                recreate   pending (waiting: Certificate/n8n-tls)
```

This is nom-in-spirit, not nom-literally: kix is driving K8s transitions, not Nix derivations, and our structured Verdict carries richer per-kind state than a build success/failure. But the visual idiom — live grid, grouped by depth, per-row structured status — is the same, and it's the idiom users already know from nom.

---

## 6. Recommendation

1. **Fold diffing into the planner, not into the wave computer.** The planner takes the diff and produces a Plan (Vec<Transition>) that may include synthetic nodes/edges (Drain, Recreate atomics, Migrate-pair barriers, Pause gates). `compute_waves` / the scheduler runs over the Plan's graph, not the raw ResourceGraph. *This is already doc 81's direction; this doc just closes the question "does diff belong in wave computation?" with: no, it belongs in the planner.*
2. **Move L2 from wave-barrier execution to DAG-streaming execution**, once doc 81's watch-based readiness model lands. Waves remain the *display grouping*, not the *execution sync primitive*. Synthetic barriers (PlatformBarrier, migration pair, Pause) become explicit DAG nodes — doc 93 has already validated this pattern for flavor infrastructure.
3. **Adopt a nom-style live grid** for `kix deploy`'s TUI output, grouped by topological depth, per-transition structured Verdict visible. Non-TTY mode emits one line per terminal Verdict event (no spinners, no wave banners).

None of these are prerequisites for each other in a hard sense, but they compose: (1) gives the scheduler a correct graph to stream over; (2) removes the wave barriers that mask head-of-line blocking; (3) exposes the streaming scheduler's live state in a form users already read fluently.

---

## 7. Open questions

1. **Failure policy default.** Halt-dependents / continue-siblings is the right default. But what's the right override? `--halt-on-first-failure` (current behavior, good for CI) vs. `--keep-going` (nom default, good for interactive)?
2. **Checkpoint granularity under streaming.** Batch all terminal Verdicts into periodic writes, or checkpoint on every Ready? Operator mode cares (API-server write pressure); CLI mode does not.
3. **Scheduler fairness vs. priority.** Do we prioritize the critical path (topological depth = 0 subgraphs first)? Or accept FIFO readiness order? Nix picks arbitrarily within `--max-jobs`; we might prefer deterministic critical-path first.
4. **Determinism for tests.** `--strict-waves` as a debug execution mode that forces wave-barrier semantics. Worth keeping, or prefer to test against Plan structure only?
5. **Operator event semantics.** Per-transition K8s Events are higher-fidelity but noisier. Aggregate on a `{activation, generation, depth}` axis? Rate-limit?
6. **Cancellation propagation policy.** When a predecessor's Verdict flips from Ready back to Progressing (drift), do we cancel in-flight dependents, or let them finish on the stale Ready signal? Probably the latter — avoid thrashing — but needs a stated rule.

---

## 8. Not in scope for this doc

- The Plan persistence format (doc 81 §7).
- The Verdict wire format and per-kind classifier specifics (doc 81 §4, §10).
- Migration pair semantics (doc 67).
- The operator vs. CLI event transport (doc 80 + doc 81 §8–9).

Those are sibling docs under the doc 81 spine; this doc only settles the execution-topology question they all assume an answer to.
