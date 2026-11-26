# kix Deploy — Implementation Plan

**Based on:** `29_deploy_architecture.md`
**Status of current code:** ~65% complete. Pipeline skeleton works end-to-end (build → stamp → waves → apply → readiness → basic GC). Tested against kind.

---

## Gap Summary

| Gap | Severity | Blocks |
|-----|----------|--------|
| Activation lifecycle (active/superseded/previous) | High | Rollback, proper GC, deploy history |
| Content-hash normalization | Medium | Drift detection, self-healing |
| `kix rollback` command | Medium | Production safety |
| Multi-cluster GC scoping | Medium | Multi-cluster deployments |
| `kix.dev/cluster` label on resources | Low | Multi-cluster scoping |
| Remove legacy `annotate.py` | Low | Reduces confusion, single stamp path |
| `graph` and `build` commands use eval path, not store graph | Low | Consistency (graph shows 0 deps) |

**Not broken (despite audit flags):**
- `managed-by` label: stamped by Nix side (`scope.nix:instanceLabels`), not CLI's job
- Deploy change detection: works correctly (compares kix-stamped hash from previous deploy vs current build hash — same store path = same file = same hash = Skip)
- CRDs + Activation: created as part of manifest set (added to `allResources` in `cluster.nix`)

---

## Phase 1: Activation Lifecycle

**Goal:** Deploy creates a proper Activation chain. Old Activations persist for rollback.

### 1.1 Activation naming: `<cluster>-<timestamp>`

Current: single Activation named `<cluster>`, updated in-place via SSA.
Target: new Activation per deploy, old ones deactivated.

**Changes:**

`cli/kix-cli/src/commands/deploy.rs`:
1. Before applying, query the cluster for the current Active Activation:
   ```
   GET activations.kix.dev with label kix.dev/cluster=<name>, spec.active=true
   ```
2. Generate new Activation name: `<cluster>-<unix-timestamp>` (e.g., `nw1-1711584000`)
3. Stamp the new Activation manifest with:
   - `kix.dev/store-path: <nix store path>` — enables local graph lookup
   - `kix.dev/previous: <old activation identity-hash>` — chain for GC
   - `kix.dev/deployed-at: <RFC3339>` — when
   - `kix.dev/git-commit: <sha>` — if in a git repo (read from `git rev-parse HEAD`)
4. Set `spec.active = true` on new Activation
5. After successful deploy, patch old Activation: `spec.active = false`

**Nix side (`lib/k8s.nix`):**
- `mkActivation` currently hardcodes `name = cluster-name`. Change to accept an optional name override so the CLI can stamp its own name. Or: the CLI modifies the Activation manifest's `metadata.name` before applying (simpler — no Nix change needed).

**CLI stamp (`kix-manifest/src/stamp.rs`):**
- Add special handling for Activation resources: inject `store-path`, `previous`, `deployed-at`, `git-commit` annotations. Detect by `kind == "Activation"`.

### 1.2 Read current Activation from cluster

New function in `kix-cluster/src/fetch.rs`:
```rust
pub async fn fetch_active_activation(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    cluster_name: &str,
) -> Option<DynamicObject>
```
Lists Activations with label `kix.dev/cluster=<name>` where `spec.active == true`.

### 1.3 Deactivate old Activation after deploy

New function in `kix-cluster/src/apply.rs`:
```rust
pub async fn deactivate_activation(
    client: &Client,
    ar: &ApiResource,
    name: &str,
) -> Result<(), ApplyError>
```
Patches `spec.active = false` via SSA.

### 1.4 `kix.dev/cluster` label

Add to stamp.rs: every resource gets `kix.dev/cluster: <cluster_name>` label. This scopes hard GC and enables multi-cluster.

**Files changed:** `deploy.rs`, `stamp.rs`, `fetch.rs`, `apply.rs`
**Estimated effort:** Medium. Mostly plumbing, no new algorithms.

---

## Phase 2: Content-Hash Normalization

**Goal:** `kix.dev/content-hash` reflects the intended state, not raw file bytes. Enables drift detection and reliable "unchanged" detection against live resources.

### 2.1 Normalization module

New file: `kix-manifest/src/normalize.rs`

```rust
pub fn normalize_for_hash(manifest: &Value) -> Value {
    strip_server_metadata(manifest)
    |> strip_status
    |> strip_kix_annotations
    |> strip_last_applied
    |> sort_keys_deep
    |> strip_nulls_deep
}

pub fn canonical_json(value: &Value) -> String {
    // Sorted keys, no trailing whitespace, deterministic numbers
    serde_json::to_string(value)  // serde_json sorts BTreeMap keys
}

pub fn content_hash(manifest: &Value) -> String {
    let normalized = normalize_for_hash(manifest);
    let canonical = canonical_json(&normalized);
    sha256_hex(&canonical)
}
```

**Strip server metadata (step 1):**
```rust
const STRIP_METADATA_KEYS: &[&str] = &[
    "uid", "resourceVersion", "creationTimestamp", "deletionTimestamp",
    "deletionGracePeriodSeconds", "generation", "managedFields",
    "selfLink", "finalizers", "ownerReferences",
];
```

**Strip kix annotations (step 3):**
```rust
const KIX_ANNOTATION_PREFIXES: &[&str] = &["kix.dev/"];
```

### 2.2 Update stamp.rs

Replace `content_hash_of(path: &Path) -> String` (raw SHA-256 of file bytes) with:
```rust
fn content_hash_of(manifest: &Value) -> String {
    normalize::content_hash(manifest)
}
```

This means the content hash is computed from the manifest Value (after JSON parse), not from raw file bytes. The normalization strips server fields so the hash is stable.

### 2.3 Update change detection

`kix-cluster/src/apply.rs` `detect_changes()`:
- Currently compares content-hash annotations directly
- With normalization, comparing annotations still works for kix-to-kix deploys
- For drift detection (future): normalize the live resource's full manifest, hash it, compare against the stamped content-hash

### 2.4 SSA field ownership (advanced, defer to later)

The architecture describes an advanced method: read `managedFields` from the live resource, extract only kix-owned fields, hash those. This is the principled solution for drift detection but is complex to implement.

**Defer this.** The normalization pipeline (steps 1-7) is sufficient for deploy change detection. SSA field ownership is only needed for drift detection, which is a reconciliation-loop feature (Phase 5+).

**Files changed:** New `normalize.rs`, updated `stamp.rs`, potentially `apply.rs`
**Estimated effort:** Medium. Well-defined transformations, thorough testing needed.

---

## Phase 3: Rollback

**Goal:** `kix rollback <cluster>` restores a previous deployment.

### 3.1 CLI command

`cli/kix-cli/src/cli.rs`:
```rust
/// Roll back to a previous deployment
Rollback(RollbackArgs),

pub struct RollbackArgs {
    pub cluster: String,
    /// Specific activation to roll back to (default: previous)
    #[arg(long)]
    pub to: Option<String>,
    /// Skip confirmation
    #[arg(short, long)]
    pub yes: bool,
}
```

### 3.2 Implementation

`cli/kix-cli/src/commands/rollback.rs`:

1. List all Activations for this cluster (label `kix.dev/cluster=<name>`)
2. If `--to` specified, find that Activation. Otherwise, use the `kix.dev/previous` chain to find the last Superseded one.
3. Read `kix.dev/store-path` annotation from the target Activation
4. Check if the store path exists locally. If not:
   - Try `nix build` to rebuild (deterministic, same inputs = same output)
   - If inputs changed, error: "Cannot rebuild old activation — inputs have changed"
5. Load the store graph from the target Activation's store path
6. Stamp annotations
7. Run the full deploy pipeline (waves, apply, readiness)
8. Update Activation states: target becomes Active, current becomes Superseded

### 3.3 Rollback list

`kix rollback --list <cluster>`:
List all Superseded Activations with their deployed-at timestamps and git commits.

**Files changed:** New `rollback.rs`, updated `cli.rs`, `main.rs`
**Estimated effort:** Medium. Reuses deploy pipeline, new is the Activation chain walking.

---

## Phase 4: GC Improvements

### 4.1 Multi-cluster hard GC scoping

`kix-cli/src/commands/gc.rs` `run_hard_async()`:
- When comparing live resources against expected set, also check `kix.dev/cluster` label
- Only GC resources belonging to the target cluster
- Resources without a `kix.dev/cluster` label: treat as belonging to any cluster (legacy compat)

### 4.2 GC reads Activation chain

Soft GC enhancement:
- Instead of reading old activation from `~/.cache/kix/activations/<cluster>.path`, read the `kix.dev/previous` chain from the Active Activation on the cluster
- Resolve the store path from the annotation
- This makes soft GC work from any machine, not just the one that deployed

Fallback chain:
1. Read `kix.dev/store-path` from Superseded Activations on cluster → local Nix store lookup
2. Fall back to `~/.cache/kix/activations/<cluster>.path` (local cache)
3. Fall back to hard GC with warning

### 4.3 GC cleans up Superseded Activations

After deleting orphaned resources:
- Delete Superseded Activations older than a configurable window (default: keep last 5)
- Or: `kix gc --purge-history` to delete all Superseded Activations

**Files changed:** `gc.rs`, `fetch.rs`
**Estimated effort:** Low-Medium. Mostly plumbing.

---

## Phase 5: Cleanup & Consistency

### 5.1 Remove legacy `annotate.py`

- Delete `pipeline/annotate.py` and `pipeline/closure.py`
- Update `flake.nix`: `mkAnnotatedManifests` should invoke the CLI (`kix build`) instead of the Python pipeline
- Or: keep `nix build .#cluster-X` as a pure Nix output (raw manifests without annotations) and document that `kix build X` is the stamped version

**Decision needed:** Is `nix build .#cluster-X` a supported output path, or is `kix build X` the only way?

If `nix build` output should also be stamped, then `mkAnnotatedManifests` needs to call the CLI. This creates a build-time dependency on the CLI binary, which is undesirable for bootstrap.

**Recommended:** Keep `nix build .#cluster-X` as raw manifests (no annotations). It's useful for debugging and third-party integrations (Argo CMP). The CLI is the authoritative stamped path. Remove `annotate.py` and update docs.

### 5.2 Align `graph` and `build` commands with store graph path

Currently `kix graph` and `kix build` use `eval_cluster_or_suggest()` (raw manifests, no store graph). They should use the same `build_cluster_activation → StoreGraph → stamp` path as deploy and diff.

**Changes:**
- `commands/graph.rs`: Replace `eval_cluster_or_suggest` with store graph path
- `commands/build.rs`: Same
- This ensures `kix graph` shows real dependencies (currently shows 0 deps)

**Files changed:** `graph.rs`, `build.rs`, potentially `inspect.rs`
**Estimated effort:** Low. Copy the pattern from deploy.rs.

### 5.3 Remove `pipeline/annotate.py` skip for Activation

Already partially done (we removed the `if kind == "Activation": continue` filter). But if we remove annotate.py entirely (5.1), this is moot.

---

## Phase Ordering & Dependencies

```
Phase 1: Activation Lifecycle
  ├── 1.1 Activation naming (no deps)
  ├── 1.2 Read current Activation from cluster (no deps)
  ├── 1.3 Deactivate old Activation (depends on 1.2)
  └── 1.4 kix.dev/cluster label (no deps)

Phase 2: Content-Hash Normalization
  ├── 2.1 Normalization module (no deps)
  ├── 2.2 Update stamp.rs (depends on 2.1)
  └── 2.3 Update change detection (depends on 2.2)

Phase 3: Rollback (depends on Phase 1)
  ├── 3.1 CLI command (no deps)
  ├── 3.2 Implementation (depends on 1.1, 1.2, 1.3)
  └── 3.3 Rollback list (depends on 1.1)

Phase 4: GC Improvements (depends on Phase 1)
  ├── 4.1 Multi-cluster scoping (depends on 1.4)
  ├── 4.2 Activation chain reading (depends on 1.1)
  └── 4.3 History cleanup (depends on 1.1)

Phase 5: Cleanup (independent, can happen anytime)
  ├── 5.1 Remove annotate.py (independent)
  ├── 5.2 Align graph/build commands (independent)
  └── 5.3 Remove annotate.py Activation skip (subsumed by 5.1)
```

**Phases 1 and 2 are independent and can be done in parallel.**
Phase 3 requires Phase 1.
Phase 4 requires Phase 1.
Phase 5 is independent cleanup.

---

## Recommended Order of Work

1. **Phase 1.4** — `kix.dev/cluster` label (tiny, unblocks multi-cluster)
2. **Phase 1.1 + 1.2 + 1.3** — Activation lifecycle (the biggest gap)
3. **Phase 2.1 + 2.2** — Content-hash normalization (unblocks drift detection)
4. **Phase 5.2** — Align graph/build with store graph (fixes `kix graph` showing 0 deps)
5. **Phase 3** — Rollback (depends on Phase 1)
6. **Phase 4** — GC improvements
7. **Phase 5.1** — Remove annotate.py

This order maximizes safety (Activation lifecycle first) then correctness (normalization) then features (rollback, GC).
