# 99 — Graph streaming

**Status:** Design
**Related:** `98_deploy_execution_topology.md`

---

1. Glyph + color vocabulary

Two axes: transition kind (what we're doing) and state (where it is). nom's glyphs cover state; we add a
transition marker.

┌────────────────┬───────┬────────────┬──────────────────────────────────┐
│     State      │ Glyph │   Color    │             Meaning              │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Pending        │ ⏸     │ blue       │ predecessors not all Ready       │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Running        │ ⏵     │ yellow     │ in-flight, watching verdict      │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Ready          │ ✔     │ green      │ terminal Verdict::Ready          │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Failed         │ ⚠     │ red        │ terminal Verdict::Failed         │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Cancelled      │ ⊘     │ gray       │ parent failed, dependent skipped │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Awaiting input │ ⏯     │ cyan       │ Pause gate, waiting on operator  │
├────────────────┼───────┼────────────┼──────────────────────────────────┤
│ Drift-detected │ ↻     │ dim yellow │ was Ready, flipped back          │
└────────────────┴───────┴────────────┴──────────────────────────────────┘

┌────────────┬────────────┬────────────────────────────────────────────────────────┐
│ Transition │ Prefix tag │                         Notes                          │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Apply      │ (none)     │ default, no tag needed                                 │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Skip       │ skip       │ dim the whole row; folded aggressively                 │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Recreate   │ recreate   │ magenta tag; renders as an atomic 3-phase sub-row      │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Migrate    │ migrate    │ magenta tag; paired rows joined by a ╪ barrier glyph   │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Drain      │ drain      │ orange tag; row sits above its (soon-deleted) provider │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Delete     │ delete     │ red tag (not failure-red — strikethrough style)        │
├────────────┼────────────┼────────────────────────────────────────────────────────┤
│ Pause      │ pause      │ cyan tag; always rendered even when "uninteresting"    │
└────────────┴────────────┴────────────────────────────────────────────────────────┘

Color falls back to bold+symbol on NO_COLOR. All glyphs have ASCII fallbacks (., >, v, !, x, ?, ~) for dumb
terminals.

2. Tree layout — default: package-grouped

nom groups by derivation; we group by kix package instance, because that's the user's unit of intent.
Children of a package node are its resources, ordered by topological depth within the package. Cross-package
 edges are drawn as thin └┄► references rather than re-parenting — keeps the tree a tree.

⏵ Activation ludo@gen5                                   elapsed 46s
├─✔ cert-manager-crds                      (7 resources, skip)
├─⏵ cert-manager
│   ├─✔ Namespace, ServiceAccount, RBAC    (5, skip)
│   └─⏵ Deployment/cert-manager-webhook    ⏱ 38s  2/3 ready
├─⏸ cert-manager-issuer          └┄► cert-manager
├─✔ grafana                                (7 resources, 5.1s)
├─⏵ n8n
│   ├─✔ Deployment/n8n                     ⏱ 7.9s
│   ├─⏵ Certificate/n8n-tls      ⏱ 12s  └┄► cert-manager-issuer
│   └─⏸ recreate Job/n8n-migrate-v17       blocked: Certificate/n8n-tls
└─✔ monitoring                             (14 resources, skip)

∑ 87 ✔ · 12 ⏵ · 3 ⏸ · 0 ⚠                 critical path: cert-manager-webhook

3. --group-by-ns

Same tree, different parent layer. Packages become leaves under a namespace node; cluster-scoped resources
gather under a synthetic <cluster> group.

├─⏵ ns/cert-manager
│   ├─⏵ cert-manager              (7 resources, 1 running)
│   └─⏸ cert-manager-issuer       (1 resource, pending)
├─✔ ns/grafana                    (1 pkg, 7 resources)
├─⏵ ns/n8n
│   ├─⏵ n8n                       (3 resources, 1 running, 1 pending)
│   └─◇ recreate Job/n8n-migrate  blocked on Certificate/n8n-tls
└─✔ <cluster>                     (CRDs, ClusterRoles, …   21 resources, skip)

Implementation: one enum GroupAxis { Package, Namespace } consumed by the renderer; the scheduler is
unaffected.

4. Focus / collapse rules (from nom)

Nom's "fill a third of the terminal" rule translates to:

1. Always show: running, failed, drift-detected, pause-awaiting, and their ancestor chain up to the root.
2. Always show terminal Delete/Drain/Migrate until the end — they're high-consequence, user wants
confirmation.
3. Fold completed packages into a single ✔ <name> (N resources, Xs) line once every child hits a terminal
Ready state.
4. Fold all-skip packages into a single dim line from the start — they never expand.
5. Never fold on failure: a failed subtree stays expanded forever, even after the deploy ends.
6. No resource printed twice: if A depends on B in two packages, the resource anchors in the lowest-depth
package; others show a └┄► reference.

5. Per-transition rendering

Apply (the common case)

Single row. While running: ⏵ Deployment/foo  ⏱ Ns  <per-kind detail> where detail comes from the Verdict
(2/3 ready, rollout 0/1, syncing gen 4→5). On Ready: collapses to ✔ Deployment/foo  apply Ns.

Skip

Dim, one line: ✔ Deployment/foo  (skip, unchanged). Folded into package aggregate as soon as the parent has
other children rendered.

Recreate

Atomic 3-phase sub-row; the phases are not separate DAG nodes to the user, even though the scheduler tracks
them:

⏵ recreate Job/n8n-migrate-v17
   ├─ ✔ drain    0.2s
   ├─ ✔ delete   0.8s
   └─ ⏵ apply   ⏱ 4s  waiting on Job pod schedule

Failure at any phase: the whole recreate shows ⚠ recreate with the failing phase highlighted. This keeps the
 user's mental model "Recreate is one thing" intact.

Migrate (doc 67 pair)

Two rows joined by a barrier glyph. Both must reach Ready or both revert:

⏵ migrate
   ├─╪─ ⏵ StatefulSet/db-v1    draining  (2/3 quiesced)
   └─╪─ ⏵ StatefulSet/db-v2    applying  (1/3 ready)

If one fails, both flip to ⚠ migrate  reverting and the rows stay joined until revert completes.

Drain

Rendered above its soon-deleted provider (edges reversed per §3.3 of the doc):

⏵ drain  Deployment/frontend      (consumers of old-api)
└─⏵ delete Deployment/old-api     awaiting drain

This makes the reversed dependency obvious — the consumer's drain blocks the provider's delete.

Delete

✔ delete Deployment/old-api  1.2s — strikethrough on the resource name when renderable. Fold-resistant until
 Ready.

Pause

Full-width cyan row, always on top of its subtree even when collapsed:

⏯ pause  "confirm prod migration"                        ╳ --yes to continue
    affects 3 transitions:  migrate db, delete old-api, apply new-api

In non-TTY mode, a Pause prints its block notice once and then waits on stdin / KIX_APPROVE=1 / a signal —
never silently hangs.

Cancelled

⊘ Certificate/n8n-tls  cancelled (cert-manager-webhook failed) — always shown, grouped under the failure
that caused it.

Drift (Ready → Progressing)

Per doc 81 §4 + open question 6: keep the row visible with ↻, don't cancel in-flight dependents. Row shows:
↻ Deployment/foo  drift since 3s  was ready 42s.

6. Failure frame

Everything else freezes (or continues, per --keep-going), the failure is pinned at top:

⚠ Activation ludo@gen5                                  FAILED after 71s

⚠ cert-manager
  └─⚠ Deployment/cert-manager-webhook     apply   failed after 61s
       └─ 3 pods CrashLoopBackOff: x509: certificate signed by unknown authority
          tail -20:
            E0414 ... tls: failed to verify certificate
            ...

⊘ cert-manager-issuer              cancelled (cert-manager depfail)
⊘ n8n/Certificate/n8n-tls          cancelled (cert-manager-issuer depfail)
⊘ recreate Job/n8n-migrate-v17     cancelled

✔ 84 others completed
∑ 84 ✔ · 0 ⏵ · 0 ⏸ · 1 ⚠ · 3 ⊘

7. Non-interactive (nix-build-L style)

One prefix per transition, same glyph vocabulary, no redraw. Events:

cert-manager-webhook> apply started
grafana> ready 5.1s
n8n> ready 7.9s
n8n-tls> waiting on cert-manager-webhook (ready: cert-manager-issuer)
cert-manager-webhook> pod 1/3 ready (15s)
cert-manager-webhook> pod 2/3 ready (38s)
cert-manager-webhook> ready 61.4s
n8n-tls> ready 12.8s
n8n-migrate-v17> recreate: drain done (0.2s)
n8n-migrate-v17> recreate: delete done (0.8s)
n8n-migrate-v17> recreate: ready 4.6s

Rules:

- Emit on every terminal Verdict, every phase boundary of a compound transition, every Pause block, every
cancellation.
- Suppress heartbeats by default; -v enables periodic progress (foo> still progressing: 2/3 ready (60s)
every 30s).
- --log-format=json emits one NDJSON object per event — this is the CI/automation path, and is what the
operator mode would also emit as K8s Events.
- On failure: dump last N log lines of the failing resource (pod logs for Deployments, events for
Certificates, …), then exit non-zero. Cancelled dependents emit one line each.
- Skip transitions are silent by default (no noise for no-ops). -v prints foo> skip (unchanged).

8. Open sub-choices for you

1. Default group axis. I've assumed package. Would you rather namespace be default and --group-by-package
the flag? Arguments: package is kix-native; namespace is K8s-native and matches what kubectl users see.
2. Cross-package edges as └┄► references vs. full re-parenting. References keep the tree readable but hide
that e.g. every Certificate depends on cert-manager. A --show-refs=full expansion mode could opt into
duplication.
3. Recreate phase rows always visible, or only when running? I've drawn them always-on while running; they
could collapse to a single row with a phase pill (recreate ⟦drain·delete·▶apply⟧) to save vertical space.
4. Pause in non-TTY: block stdin, or require --approve-all / KIX_APPROVE upfront? CI wants upfront; humans
want to be asked. Probably both, with --approve-all as the escape.

> user feedback:
i love everything you said as well as every default opinion to gave
i would love the folding height to be 1/2 the screen and potentially configurable
1 agree
2 agree (potentially ideate a few different symbols) and agree with the show refs
3 horizontal
4 agree

---

## 9. Implementation plan

> **Status update (doc 99 Stages A–D + H + C.1 shipped):** The graph-streaming
> engine is live for `kix deploy`, `kix rollback`, `kix gc`, and the operator.
> `waves.rs` and `reconcile.rs` have been deleted. `DeployEvent` is the single
> observer wire format consumed by the inline TUI (`--tui`), the colored
> `StreamCliObserver`, the non-interactive `LineObserver` / `JsonObserver`, and
> the operator's composite tracing + K8s-Events observer. Stage E (Recreate /
> Migrate / Drain / Delete / Pause as first-class scheduled transitions),
> Stage F (Pause approval gates), and Stage G (in-flight drift without
> dependent cancellation) are not yet shipped.


### 9.1 Scope discipline

This work is **visuals + graph planning + scheduling + visualization**. It consumes the current `ChangeAction` vocabulary (Apply/Skip/Orphan) and the current readiness machinery as-is. The full `Transition` enum from doc 81 §3 (Recreate/Migrate/Drain/Delete/Pause as first-class scheduled operations) is **deferred** — §5's per-transition rendering is scaffolded behind an enum that today has only `Apply` and `Skip` populated, so later work fills in variants without reshaping the renderer.

Put another way: we are answering doc 98 question 2 (waves → DAG streaming) and rendering the result (§2–§7 of this doc). We are *not* answering doc 98 question 1's full form (planner that synthesizes nodes). The planner stays a pass-through; scheduling moves from wave-barrier to DAG-streaming over the existing `ResourceGraph`.

### 9.2 Stages — NOW

**Stage A — DAG-streaming executor over existing vocabulary.**
Replace the wave-barrier loop in `cli/kix/src/cluster/reconcile.rs` with a ready-queue scheduler (doc 98 §4.2): per-node state machine Pending → Running → Ready/Failed/Cancelled, promotion on predecessor Ready, concurrency bounded by existing `READINESS_CONCURRENCY` semaphore. `compute_waves` is **removed entirely** — neither execution sync nor display grouping depends on topological levels. Rendering uses the package/namespace tree (§2–§3), not depth-bands. Checkpointing rhythm shifts from per-wave to batched-on-terminal-verdict (§4.4). Failure policy default: halt-dependents, continue-siblings; `--halt-on-first-failure` preserves today's behavior for CI (open question 1).

**Stage B — Verdict + TransitionKind vocabulary (minimal).**
Introduce `Verdict { Pending, Running, Ready, Failed, Cancelled, AwaitingInput, DriftDetected }` and `TransitionKind { Apply, Skip, Recreate, Migrate, Drain, Delete, Pause }` in `kix::cluster`. **Only `Apply` and `Skip` are produced by the planner today**; the other variants exist so the renderer's match arms compile and the event stream shape is frozen. Rewire `ReconcileEvent` to carry `{node_id, kind, verdict, detail}`. Port `CliObserver`, `TuiObserver`, operator `observer.rs` as thin shims — no behavior change yet.

**Stage C — Graph-streaming renderer.**
New `GraphStreamObserver` implementing §1–§5 of this doc: tree model with package-as-default grouping axis, `--group-by-ns` toggle (§3), glyph/color vocab with ASCII/NO_COLOR fallbacks (§1), cross-package `└┄►` references with `--show-refs=full` escape (§4 rule 6, open question 2), fold rules at ½ screen default and `--fold-height=<n>` override (§4, user feedback), failure frame pinning (§6). Replaces `deploy_tui.rs`. Per-transition render paths (§5) are stubbed: Apply and Skip fully rendered; Recreate/Migrate/Drain/Delete/Pause render as a single generic row until Stage E promotes them.

**Stage D — Non-interactive + JSON streams.**
`--log-format={pretty,line,json}`. `line` is §7's nix-build-L idiom. `json` is NDJSON, one object per terminal Verdict / phase boundary / Pause / cancellation — this is the CI/automation path and the same wire format the operator will emit as K8s Events later. `-v` enables heartbeat progress events. Non-TTY detection falls back to `line` automatically.

### 9.3 Stages — LATER (deferred, each is its own milestone)

**Stage E — Transitions as first-class scheduled operations.**
The work this doc's §5 describes rendering for, but where the *scheduler* and *planner* learn to actually produce those transitions. Recreate becomes a synthesized atomic `Drain → Delete(old) → Apply(new)` sub-DAG (doc 98 §3.3). Migrate becomes a pair-barrier node (doc 67). Drain introduces reversed edges (doc 98 §3.3). Delete is promoted from implicit orphan-pruning to a first-class transition. Planner is rewritten per doc 98 §3.4 to rewrite the graph. Renderer's stubbed match arms from Stage C fill in.

**Stage F — Pause gates.**
Activation CR `approvalStatus` field, `Pause` transition as a barrier node, `--approve-all` / `KIX_APPROVE` env / stdin prompt for TTY. Non-TTY: emit block notice, wait on stdin or env (§5 Pause). Depends on Stage E's barrier-node machinery.

**Stage G — In-flight drift without cancel.**
`DriftDetected` verdict surfaces on a previously-Ready node without cancelling in-flight dependents (doc 81 §4 + open question 6 — the "let them finish on stale Ready" policy). Renders as `↻` per §5 Drift row.

**Stage H — Operator K8s Event emission.**
Wire the Stage D JSON event stream into the operator's K8s Event API. Aggregation axis and rate-limiting per doc 98 open question 5.

### 9.4 Dependency graph between stages

```
A (DAG streaming)  ──┐
                     ├─► C (renderer) ──► D (json/line) ──► H (operator events)
B (vocabulary)    ──┘                  ╲
                                        ╲──► E (transitions) ──► F (pause)
                                                             ╲──► G (drift)
```

A and B are independent and land first. C depends on both. D depends on C. E is the deep change that unlocks F and G. H is mechanical once D is stable.

### 9.5 What stays unchanged

- `kix::cluster::apply` SSA path, readiness pollers in `readiness.rs`, identity-hash change detection, Activation CR lifecycle, operator reconcile-loop prevention. `waves.rs` / `compute_waves` is deleted — `reconcile.rs`'s loop shape changes from wave-barrier to DAG-streaming over the `ResourceGraph` directly. The library's SSA and readiness halves are untouched.
