# 56: Unified Operator Reconcile & Phase-Based Activation Lifecycle

**Status:** Implemented

## Summary

The operator reconcile loop has been unified into a single path that compares desired state against live cluster state. The activation lifecycle now uses a phase-based model (`Queued -> Active -> Superseded`) instead of the previous `spec.active` boolean, with `previousActivation` linking for rollback.

## Problem

The previous operator had two separate reconcile paths:

1. **New generation** — loaded old manifests from `lastAppliedSource`, ran local `detect_changes()`, applied changes wave-by-wave.
2. **Drift correction** — blindly force-applied all manifests via SSA, relying on K8s idempotency.

This caused several issues:
- Drift correction was wasteful (re-applied everything even when nothing drifted)
- The two paths had different semantics (orphan detection only worked in new-generation mode)
- `observedGeneration` and `lastAppliedSource` machinery was complex and existed solely to distinguish the two paths
- `spec.active` boolean mixed user intent with lifecycle state

## Design

### Phase-Based Lifecycle

Activations move through phases managed via `status.phase`:

```
(new CR) -> Queued -> Deploying -> Active -> Superseded
```

- **Queued** (or empty status): New activation waiting to be deployed. The CLI creates CRs without a phase; the operator treats missing phase as Queued.
- **Deploying**: Deploy in progress (wave-by-wave apply). Set by `begin_deploy()`.
- **Active**: Successfully deployed. Drift detection runs on requeue.
- **Superseded**: Replaced by a newer activation. No-op on reconcile. Finalizer removal skips resource cleanup (the Active activation owns those resources).

Phase transitions:
- CLI creates activation CR with `spec.source.path` and `spec.cluster` (no `spec.active`)
- Operator sees Queued CR -> supersedes current Active -> begins deploying
- On success -> `finalize_deploy()` sets phase to Active
- `status.previousActivation` stores the name of the superseded activation

### Multiple Queued Activations

When multiple Queued activations exist for a cluster:
1. The newest (by creation timestamp) wins
2. All older Queued activations are immediately superseded
3. The current Active activation is superseded
4. The newest Queued begins deploying

### Unified Reconcile Loop

Both new deployments and drift correction use one path:

```
1. Load desired manifests from spec.source.path
2. Filter out CRDs + Activation CRs (skip_kinds)
3. Fetch all live kix-managed resources from cluster (fetch_managed_resources)
4. detect_changes_live(desired, live) -> Apply/Skip/Orphan
5. build_wave_actions(actions, manifests) -> waved plan
6. reconcile(client, discovery, waves, orphans, ...)
```

`detect_changes_live()` compares desired manifests against live `DynamicObject`s:
- Desired manifest not found on cluster -> **Apply** (new or deleted)
- Identity-hash differs between desired and live -> **Apply** (drifted or changed)
- Identity-hash matches -> **Skip**
- Live resource not in desired set -> **Orphan**

The only difference between new deployments and drift correction is whether `activation_name` is passed to the reconcile engine:
- **New deployment** (Queued -> Active): passes name -> triggers `begin_deploy`, `record_waves`, `finalize_deploy`
- **Drift correction** (Active requeue): passes `None` -> no lifecycle changes

### Drift Detection Tiers (Future)

The `detect_changes_live()` function does hash-based comparison (fast). A future deep-diff mode could do field-level comparison via SSA dry-run. Both return the same `Vec<ChangeAction>` type, so the downstream wave planning is identical regardless of detection method. The controller can alternate between fast (every requeue) and deep (every Nth requeue) based on configuration.

## Removed Machinery

- `spec.active` boolean (replaced by `status.phase`)
- `observedGeneration` guard in the reconciler
- `lastAppliedSource` status field
- `stamp_reconcile_status()` function
- `resolve_old_manifests()` in the controller
- `is_drift_correction` branching
- Two-path reconcile logic (replaced by single `run_reconcile()`)

## Finalizer Behavior

The finalizer (`kix.dev/operator-gc`) now checks the activation's phase before cleanup:
- **Active/Deploying**: Full resource cleanup (load manifests, delete in reverse topo order)
- **Superseded/Queued**: Finalizer removed without resource cleanup (resources belong to the Active activation)

## Files Changed

- `kix/src/cluster/activation.rs` — Phase constants, `find_queued()`, `supersede_activation()`, `read_phase()`, updated `find_active()` and `list_superseded*()` to use `status.phase`, `finalize_deploy()` writes `status.previousActivation`
- `kix/src/cluster/apply.rs` — New `detect_changes_live()` function with tests
- `kix-operator/src/controller.rs` — Rewritten: phase-based dispatch, unified `run_reconcile()`, phase-aware `handle_delete()`
- `kix-operator/src/main.rs` — Updated docs
- `kix-cli/src/commands/operator.rs` — `apply_activation()` no longer sets `spec.active`, `watch_activation_progress()` watches for `status.phase == Active`
- `cli/README.md` — Updated architecture docs
