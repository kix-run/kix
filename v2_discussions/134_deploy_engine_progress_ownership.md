# 134: The deploy engine owns its own progress

**Status:** Implemented (the PR that adds this doc)
**Related:** `98_deploy_execution_topology.md`, `99_graph_streaming.md`, `81_deploy_as_lifecycle_engine.md`, kixpkgs#60, #61, #62, #63

---

## 1. Problem

On 2026-09-07 `kix deploy` sat silent for 35 minutes with every thread idle.
The proximate cause was the in-flight cap added in #60 and removed in #61. The
structural cause is older and is still in the tree: the scheduler in
`cli/kix/src/cluster/scheduler.rs` runs up to 64 apply futures inside one
`FuturesUnordered` that only advances while the scheduler task polls it, and
the scheduler task awaits other things inline. Any of those awaits parks every
apply. A timer inside a parked future never fires. Ctrl-C does nothing.

Four independent reviews of #60 (a Rust async reviewer, a Kubernetes client
prior-art reviewer, a Kix systems reviewer, an operations reviewer) agreed on
the verdict: the transport layer is the right home for retries, deadlines and
classification, the cap was the wrong mechanism, and the remaining flaw is the
scheduler's shape. Two online research passes (structured concurrency and
testing techniques) informed the shape below.

Things the scheduler task awaits today while holding parked applies:

| Site | What it awaits | Consequence |
|---|---|---|
| `scheduler.rs:433`, `:468` | Full API rediscovery after a CRD node | Every apply parks. The error is also swallowed (`if let Ok`). |
| `scheduler.rs:527`, `:542` | Activation checkpoint write | Same. Under a sick apiserver this can burn the full 60s retry budget. |
| `execute_node`, via `secrets::hydrate_secrets` | A synchronous `sops` subprocess | Blocks the runtime thread for the whole run of the process. |

Nothing owns the invariant "the run makes progress." Transport bounds one
attempt. Readiness bounds one node. Nothing bounds the run. Issue #62.

Nothing in the test suite executes `run_deploy`. It takes a concrete
`kube::Client`, so it cannot run without a cluster. The `#[ignore]`d kind test
deploys no CRDs and would not have caught this either.

## 2. Design

### 2.1 Layers and the invariant each one owns

| Layer | File | Owns |
|---|---|---|
| Transport | `cluster/client.rs` | One attempt becomes one outcome. Retry, backoff, per-attempt deadline. Holds nothing shared. |
| Classification | `cluster/errors.rs` | What a failure means. One table. |
| Sweep | `cluster/fetch.rs` | A complete view or an error. Bounds its own bursts. |
| Change detection | `cluster/apply.rs`, `manifest/lifecycle.rs` | The plan is a function of two complete views. |
| **Cluster operations seam** | `cluster/ops/` (new) | Every apiserver call the engine makes, behind one trait. Real and fake implementations. |
| **Engine** | `cluster/scheduler.rs` | Dependency order, admission, cascade on failure, every node terminal exactly once. Its task never awaits foreign I/O. |
| **Watchdog** | `cluster/watchdog.rs` (new) | The run makes progress, or the user is told what it is waiting on, or the run stops. |
| Readiness | `cluster/readiness.rs` | One node stops waiting. |
| Observers | `cluster/stream.rs` | Render only. |

### 2.2 The engine task never awaits foreign I/O

Every unit of work the engine starts is a spawned task in one
`tokio::task::JoinSet<Done>`:

```rust
enum Done {
    Node(NodeId, NodeOutcome),
    Rediscovery(Result<(), String>),
    Checkpoint(Result<(), String>),
}
```

While nodes are in flight the supervisor loop has exactly two await points,
neither of which depends on anything outside the engine:

```rust
tokio::select! {
    biased;
    _ = cancel.cancelled()    => ...,    // the caller or the watchdog said stop
    joined = tasks.join_next() => ...,   // a task finished
}
```

The watchdog is a separate spawned task with its own timer (§2.6), so it
runs even if this loop has a bug that parks it.

Because the runtime polls spawned tasks, the per-attempt deadline in the
transport fires, readiness timers fire, and cancellation is observed no matter
what the supervisor is doing. Concurrency stays at 64 in-flight nodes, counted
by the supervisor. No permits, no semaphore: a permit is a shared resource
whose release depends on someone polling the holder, and that is the shape
that failed.

A spawned task that panics comes back as a `JoinError`. The engine keeps a
map from task id to task kind, so a panicking node is a fatal engine error,
a panicking checkpoint is a best-effort failure, and a task the engine
aborted itself (on cancel) becomes a `Cancelled` verdict for its node.

On cancel the supervisor does not return at once. It stops admitting, aborts
every task, and keeps draining the set: a node that finished just before
the cancel is still counted, an aborted one becomes `Cancelled`. A cancel
that lands as the last node finishes is re-checked after the loop, so a
cancelled run never prunes or finalizes. Whatever stops a run, every node
still without a verdict gets `Cancelled` before the run returns, so the
counts add up to the plan and no renderer is left with a Pending row under
a `Stopped` footer.

Why `JoinSet` and not the alternatives: `FuturesUnordered` is what we have and
it only advances when polled. `TaskTracker` gives no results back.
`async-scoped` has an `unsafe` scope API. `moro` is an unmaintained
experiment. `JoinSet` aborts every child when dropped, so an early `return`
from the supervisor is already structurally safe.

### 2.3 CRD barrier

Today every CRD node triggers a full rediscovery, inline. The barrier keeps
the semantics (dependents of a CRD do not run until discovery knows the new
kind) and moves the wait off the supervisor:

1. A CRD-like node reaches Ready. Readiness has already waited for
   `Established=True` and probed discovery for the new kind.
2. The engine marks it terminal but does not promote its dependents yet. It
   records the node in the barrier's `awaiting` list and, if no rediscovery
   task is running, moves the list to `covered` and spawns one. If one is
   already running, the node waits in `awaiting` for the next.
3. When the rediscovery task returns `Ok`, the engine promotes the
   dependents of every `covered` node and, if `awaiting` is not empty,
   spawns the next refresh. Several CRDs finishing together share one
   rediscovery.
4. When it returns `Err`, the run stops. No new nodes are admitted, in-flight
   nodes finish, and the caller gets `DeployError::DiscoveryFailed { partial }`.
   This is #60's rule applied inside the run: a partial view never becomes
   a plan, and a stale discovery view is a partial view.

Helm, Flux, kapp and Argo CD all sequence CRDs before CRs behind a barrier and
refresh discovery once afterwards. kubectl does not, and "apply twice" is its
documented answer.

### 2.4 Checkpoints are tasks too

The Activation checkpoint write runs as a spawned `Done::Checkpoint` task, at
most one in flight, with running totals. It is best-effort: a hung one
cannot park applies, the loop ends when node work ends whatever the
checkpoint is doing, and the final checkpoint and finalize after the loop
are bounded (30s in the ops layer, 60s in the engine).

### 2.5 The cluster operations seam

`cluster/ops/mod.rs` defines `ClusterOps`, the one trait through which the
engine touches a cluster. It is `dyn`-compatible (`async_trait`) so the
engine takes `Arc<dyn ClusterOps>`:

- Per node: `hydrate`, `apply`, `recreate_in_place`, `wait_ready` (which
  covers import markers too).
- Per run: `begin`, `rediscover`, `checkpoint`,
  `record_activation_on_skipped`, `delete`, `finalize`.

Kind resolution, the discovery cache, the live Activation set and dry-run
gating all live behind the trait; the engine never sees an `ApiResource`.

`KubeOps` (`ops/kube.rs`) is the real implementation. It holds the `Client`,
the shared discovery cache, and the run's Activation identity
(`KubeOpsConfig`). It is the only file in the engine that knows `kube::Api`.
Existing functions in `apply.rs`, `readiness.rs`, `activation.rs` and
`fetch.rs` are called from it unchanged.

`ScriptedOps` (`ops/scripted.rs`, `cfg(test)` or the existing `test-util`
feature) is the fake. Its calls do not complete on their own: each scripted
behaviour is `Now(outcome)`, `After(duration, outcome)`, `Gate(latch,
outcome)` released by the test, `Hang`, or `Panic`. It records a call log with virtual timestamps and the
peak number of concurrent applies. That closes the gap that hid the deadlock:
a fake that resolves on first poll cannot show a parked future.

`hydrate` in `KubeOps` runs the `sops` subprocess on `spawn_blocking`. The
existing synchronous code path is reused unchanged; a blocking thread is not
abortable, so a cancelled run may let one in-progress decrypt finish in the
background. That is acceptable for a subprocess that reads a file.

### 2.6 Watchdog

`cluster/watchdog.rs` runs as its own spawned task. It reads a shared
`Progress` record that the engine and node tasks update: the last time
anything happened, and for each in-flight node its phase (hydrate, apply,
readiness) and when that phase began. Readiness status callbacks count as
activity, so a StatefulSet that takes ten minutes to come up does not trip
it, because it reports every two seconds.

Policy, pure and unit-tested in `watchdog::assess`:

- No activity for `warn_after` (default 30s): emit
  `DeployEvent::Stalled { idle, in_flight }` naming each node, its phase and
  how long it has been there. Repeat every `warn_after`.
- No activity for `abort_after` (default 10 minutes, `KIX_STALL_TIMEOUT`
  seconds, `0` disables): emit `Stalled` with `aborting: true`, record the
  reason, and cancel the run through the existing token. The engine then
  emits `Stopped { reason }` and returns `Cancelled { partial }`.

The interval uses `MissedTickBehavior::Delay`. The default `Burst` fires
catch-up ticks after a stall and would report spuriously.

The discovery refresh behind a CRD barrier is tracked too, under the
synthetic node `api-discovery` with phase `discovery`. Without that the
watchdog would be blind to a hung refresh once every node had finished (a
red-team finding). Everything the run awaits after the node phase (begin,
stamping, each prune delete, the final checkpoint, finalize) is bounded to
60 seconds instead, because the watchdog does not watch it.

### 2.7 One failure model

- **Retry**: transport only, on `FailureClass::is_transient()` plus
  idempotence. No retry loop anywhere else.
- **Stop the run**: anything that would make the run act on a view it does
  not have. Sweep failure, live reconstruction failure, rediscovery failure,
  node failure under `OnErrorPolicy::Stop`, a panicking task, the watchdog's
  abort bound.
- **Degrade with a visible mark**: only writes that cannot corrupt applied
  state and that the next deploy redoes. Skipped-node stamping, checkpoint,
  finalize. These emit an event (`DeployEvent::BestEffortFailed`), not a
  `tracing::warn` the user never sees.

### 2.8 Cancellation

`cluster/cancel.rs` keeps its API (`cancel`, `is_cancelled`) and gains an
awaitable `cancelled()`, backed by `tokio_util::sync::CancellationToken`.
The supervisor selects on it. On cancel it emits `Stopped`, shuts the
`JoinSet` down (aborting in-flight tasks), and returns `Cancelled { partial }`.
Readiness keeps checking the flag between polls as it does today.

### 2.9 Knobs

| Knob | Default | Where |
|---|---|---|
| In-flight nodes | 64 | `SchedulerConfig::concurrency` (was a const) |
| Stall warning | 30s | `SchedulerConfig::stall_warn_after` |
| Stall abort | 600s | `SchedulerConfig::stall_abort_after`, env `KIX_STALL_TIMEOUT` (`0` = never) |
| Checkpoint timeout | 30s | `KubeOps` |

No client-side rate limiter. kubectl runs at 50 QPS with a 300 burst and
leans on API Priority and Fairness; client-go is removing client-side
throttling. If one is ever wanted, `governor` is clock-based and cannot
deadlock; a `Semaphore` or `tower::limit` is not the answer.

## 3. Testing

Everything below runs with no cluster, under `#[tokio::test(start_paused = true)]`.
Tokio's paused clock jumps to the next timer whenever no task is runnable, so
a run that parks fails a wrapped `tokio::time::timeout` at once instead of
hanging, and a "10 minute" watchdog test takes milliseconds.

Engine tests (`scheduler.rs`, driven through `ScriptedOps`):

1. **A CRD barrier does not park running nodes.** 64 slow independent
   applies plus one CRD and one CR depending on it. Rediscovery takes 1s.
   The run completes; the CR's apply starts after rediscovery ends.
2. **Rediscovery failure stops the run.** `DiscoveryFailed { partial }`;
   the dependent is never applied; nodes already in flight finish.
3. **A hung apply is reported and then aborted.** A `Stalled` event names
   the node and phase within `warn_after`; the run returns `Cancelled`
   within `abort_after`.
4. **Readiness progress keeps the watchdog quiet.** A node whose readiness
   reports every 2s for 5 minutes then succeeds produces no `Stalled` event.
5. **Cancel terminates promptly** with every node hung.
6. **A hung checkpoint does not hold the run.** Nodes complete; the run
   returns within the checkpoint timeout.
7. **Concurrency never exceeds the cap.** 200 nodes, peak concurrent
   applies at most 64.
8. **A panicking node is fatal**, not lost.
9. **Property test** (`proptest`, upper-triangular random DAGs up to 24
   nodes, random per-node outcomes): every node terminal exactly once; the
   counts sum to the node count; no node applies before its predecessors
   are Ready; a node with a failed predecessor is Cancelled, never applied;
   the run terminates. A runtime is built per case with a paused clock.

Red-team additions (three Fable reviewers attacked the first version
before the PR opened): a hung discovery refresh is reported and aborted; a
hung stamp and a hung prune delete are bounded and reported; cancel aborts
the tasks (proved by opening the gate afterwards and seeing nothing
complete) and gives every node a verdict; a cancel during readiness never
reaches prune or finalize; admission refills a freed slot at once (65
nodes, one fast); halt-on-first-failure finishes in-flight nodes and
cancels the rest; the stall cadence is exactly 30, 60, 90, abort at 120;
the property test records events and checks exactly one terminal verdict
per node and dependency order by log position, with readiness failures and
hangs in the outcome mix.

Watchdog: `assess` is pure; tests cover quiet, warn, repeat, abort, and
`0` disables abort.

Cancel token: `cancelled()` wakes a waiter.

Transport: `unpolled_requests_never_block_another` from #61 stays.

Live gate before merge, and for any future change under `cluster/`: a
`--dry-run` deploy of a build that differs from the live one and that
applies CRDs, against stage2 with a throwaway label. A dry run of an identical
build short-circuits on "activation identical" and proves nothing.

## 4. Alternatives considered

- **Keep `FuturesUnordered`, spawn only rediscovery and checkpoint.** Fixes
  the two known sites and leaves the shape that produced them. The next
  inline await reintroduces the bug.
- **Semaphore permits owned by node tasks.** Correct with `JoinSet`, but a
  counter in the supervisor is simpler and has no release-ordering to get
  wrong.
- **Rediscovery as a synthetic graph node.** Clean in the abstract, but
  the plan is built before the engine runs and rediscovery is coalesced
  across CRDs at run time. Revisit when Stage E adds barrier nodes.
- **Deterministic simulators** (`turmoil`, `madsim`, `loom`). turmoil
  simulates networks of hosts; madsim replaces tokio and has no patched
  kube; loom explores atomics orderings and does not model the scheduler.
  None finds this class of bug; a paused clock and a gated fake do.
- **A tower `Service` seam only** (`tower-test`). Right for testing kube's
  own URL and status handling; wrong as the engine's seam because the fake
  would still auto-serve. Kept as an option for CRD-barrier tests against
  real `Established` parsing later.
- **`tokio::process` for sops.** Abortable, but requires an async rewrite
  of a tested synchronous path. `spawn_blocking` is enough for now.
- **Upgrade kube to 4.x.** Its client seam stabilised at 1.0. Out of
  scope here; tracked in ROADMAP.

## 5. Delivery

One PR, two commits:

1. Code. The `cluster/ops` seam and `ScriptedOps`; `run_deploy` rewritten
   on `JoinSet` with the CRD barrier and spawned checkpoints; the watchdog
   task; `Stalled` and `BestEffortFailed` events rendered by the line,
   pretty, JSON and operator observers; `cancelled()` on the token; the
   three callers. Behaviour identical on the happy path. Closes #62.
   Tests 1 to 9.
2. Docs: this document, `cli/README.md`, HANDBOOK, FEATURE-CATALOG,
   ROADMAP.

It supersedes #61 (its commit is the base of this branch). #63 is rebased
onto it.

## 6. Open questions

- Should the abort bound default to `2 × readiness timeout` rather than a
  fixed 10 minutes? Readiness already has an idle budget; a fixed bound is
  easier to explain.
- Rust CI. The repo runs fmt and clippy pre-commit and no tests anywhere.
  `cargo test --workspace` in a GitHub workflow is the smallest useful
  step; the kind integration test needs a CRD-bearing package in
  `clusters/test-kind.nix` before it proves anything.
- Two latent hazards of the same family, not touched here: kube's exec
  credential plugin holds an async mutex across an await inside the request
  future (affects EKS/GKE, not stage1/stage2), and `is_watch_uri` only exempts
  `watch=true` from the request deadline (log follow and exec would be cut
  at 120s if Kix ever streams them).
