# Operator Remaining Work — Manifest Artifact, Drift Detection, Controller Runtime

**Status:** RFC
**Related:** `29_deploy_architecture.md` (deploy pipeline), `43_activation_operator.md` (operator design)

---

## 1. Context

The deploy engine is implemented (`kix-cluster` crate): local DAG diff, wave computation, SSA apply, readiness polling, activation lifecycle, multi-activation reference tracking, and wave progress persistence.

Three pieces remain before the operator can run in-cluster:

1. **Manifest artifact format** — how the operator obtains evaluated manifests without `nix build`
2. **Drift detection** — how `kix diff` and the operator's periodic reconcile detect live-state divergence
3. **Controller runtime** — the kube-rs watch loop wrapping the existing engine

This RFC designs all three as a joint effort because they share interfaces and sequencing constraints.

---

## 2. Manifest Artifact Format

### Problem

The deploy engine currently consumes manifests via `StoreGraph::from_result_dir`, which reads from a local Nix store result directory. The operator runs in-cluster without Nix. It needs the same data — `kix-packages.json` + per-resource JSON manifests — delivered as a portable artifact.

### Design: OCI Artifact

Package the evaluation result as an OCI artifact (single-layer image or OCI artifact with custom media type). This is the standard distribution mechanism for K8s-adjacent tooling (Helm charts, WASM policies, Flux OCI sources).

**Artifact contents:**
```
/kix-packages.json          # package index (PI → resource paths)
/manifests/                  # flat directory of JSON manifests
  <identity-hash>.json      # one file per resource, named by identity-hash
```

The identity-hash filename means the artifact is content-addressed — two identical resources in different activations produce the same file. This enables layer deduplication in OCI registries.

**Packaging (CI side):**
```bash
# After nix build .#cluster-<name>-activation
kix artifact pack --activation ./result --output artifact.tar
# Push to registry
oras push registry.example.com/kix/production:gen42 artifact.tar
```

`kix artifact pack` is a new CLI command. It:
1. Loads the store graph from the result directory
2. Stamps annotations
3. Writes `kix-packages.json` + individual manifest JSON files to a tar
4. Tags with the activation identity-hash

**Consumption (operator side):**
```rust
// In kix-cluster, new module: artifact.rs
pub struct ManifestArtifact {
    pub package_index: KixPackageIndex,
    pub manifests: HashMap<String, Value>,  // identity-hash → manifest JSON
}

impl ManifestArtifact {
    /// Load from an unpacked artifact directory
    pub fn from_dir(path: &Path) -> Result<Self>;

    /// Load from an OCI artifact reference (pulls from registry)
    pub async fn from_oci(reference: &str) -> Result<Self>;

    /// Convert to the same format detect_changes expects
    pub fn to_manifest_list(&self) -> Vec<Value>;
}
```

The operator's reconcile loop becomes:
1. Read `spec.source` from Activation CR
2. `ManifestArtifact::from_oci(source)` → pull the artifact
3. `detect_changes(new_artifact.to_manifest_list(), old_manifests)` → diff
4. Apply waves as normal

**Alternative considered:** Nix binary cache. The operator fetches store paths from a shared cache (cachix/attic). This requires a Nix client in the operator pod and understanding Nix store path semantics. The OCI approach is simpler — the operator never touches Nix, it just reads JSON files from a tar.

**Migration path:** The CLI continues using `StoreGraph::from_result_dir` for local deploys. `ManifestArtifact` is an alternative entry point that produces the same `Vec<Value>` the engine already consumes. No engine changes needed.

### Activation CR Source Field

```yaml
spec:
  source:
    # Option A: local store path (CLI deploy, dev)
    type: storePath
    path: /nix/store/abc123...-activation-production

    # Option B: OCI artifact (operator, CI)
    type: oci
    reference: registry.example.com/kix/production:gen42
    # Optional: pull secret reference
    pullSecretRef:
      name: registry-credentials
```

The operator reads `spec.source.type` to decide how to obtain manifests.

---

## 3. Drift Detection

### Problem

Deploy and GC use local DAG diff — they compare two known-good Nix closures. They never look at live cluster state for change detection. But drift detection ("has someone manually edited a resource since kix last applied it?") requires comparing the **intended** manifest against the **live** resource.

This is the content-hash normalization pipeline from the original doc 29 §6, deferred during the deploy redesign. It belongs in `kix diff` (the CLI command) and the operator's periodic reconcile loop.

### Design

Drift detection lives in a new `kix-manifest/src/normalize.rs` module. It's consumed by `kix diff --live` and the operator's drift loop, but never by the deploy or GC paths.

**Normalization pipeline:**

```rust
// kix-manifest/src/normalize.rs
pub fn normalize_for_comparison(manifest: &Value) -> Value {
    let mut v = manifest.clone();
    strip_server_metadata(&mut v);  // uid, resourceVersion, creationTimestamp, generation, managedFields, selfLink
    strip_status(&mut v);            // entire status subtree
    strip_kix_annotations(&mut v);   // kix.dev/* annotations (metadata about the resource)
    strip_last_applied(&mut v);      // kubectl.kubernetes.io/last-applied-configuration
    strip_null_values(&mut v);       // null → absent
    sort_keys(&mut v);               // lexicographic at all levels
    v
}

pub fn content_hash(manifest: &Value) -> String {
    let normalized = normalize_for_comparison(manifest);
    let canonical = serde_json::to_string(&normalized).unwrap();
    sha256_hex(&canonical)
}
```

**Server defaults problem:** After normalization, a Deployment applied without `strategy` still differs from the live resource which has `strategy.type: RollingUpdate` (server default). The principled solution: use SSA field ownership.

```rust
/// Extract only the fields owned by field manager "kix" from a live resource.
/// This strips server defaults, controller-added fields, and other managers' fields.
pub fn extract_kix_owned_fields(live_resource: &DynamicObject) -> Value {
    // 1. Find managedFields entry with manager == "kix"
    // 2. Parse fieldsV1 trie
    // 3. Project the live resource onto only those field paths
    // 4. Return the projection
}
```

This is the hardest part — parsing `fieldsV1` is non-trivial. The fallback is a per-kind allowlist of known server defaults to strip (less precise but functional).

**Drift detection modes (for `kix diff --live` and operator):**

| Mode | What it compares | When to use |
|------|-----------------|-------------|
| **owned-fields** (default) | Extract kix-owned fields from live, normalize, compare hash | Precise, handles server defaults correctly |
| **full-strip** (fallback) | Strip known server fields from live, normalize, compare hash | Works without managedFields parsing |
| **existence-only** | Check if kix-managed resources exist with correct identity-hash | Fast, no content comparison |

**Operator integration:**
```yaml
spec:
  policy:
    driftRemediation: auto    # auto | alert | disabled
    driftInterval: 5m         # how often to check
    driftMode: owned-fields   # owned-fields | full-strip | existence-only
```

The operator runs drift detection on a timer (not on every reconcile). Drift remediation = re-apply the intended manifest via SSA.

### Relationship to `kix diff`

`kix diff` currently compares build-to-build (two Nix evaluations) or build-to-snapshot (Nix eval vs cluster dump). The normalization pipeline enables a third mode:

```bash
kix diff <cluster> --live    # compare intended state vs live cluster state
```

This uses `normalize_for_comparison` on both sides and reports per-resource content drift. It's the CLI equivalent of what the operator does periodically.

---

## 4. Controller Runtime

### Design

A new binary crate `kix-operator` using `kube-rs` controller runtime. The operator is a single-binary that runs in-cluster.

**Crate structure:**
```
cli/
  kix-operator/
    Cargo.toml
    src/
      main.rs          # entrypoint, leader election, health probes
      controller.rs    # Activation controller (watch + reconcile)
      reconcile.rs     # reconcile logic (wraps kix-cluster engine)
```

**Dependencies:** `kube` (controller runtime), `kix-cluster` (engine), `kix-manifest` (types). Does NOT depend on `kix-eval` or Nix — the operator consumes artifacts, not Nix evaluations.

**Controller skeleton:**

```rust
// controller.rs
use kube::runtime::Controller;
use kube::Api;

pub async fn run(client: Client) {
    let activations: Api<DynamicObject> = Api::all_with(client.clone(), &activation_ar());

    Controller::new(activations, Default::default())
        .run(reconcile, error_policy, Arc::new(Context { client }))
        .for_each(|_| async {})
        .await;
}

async fn reconcile(activation: Arc<DynamicObject>, ctx: Arc<Context>) -> Result<Action> {
    let name = activation.metadata.name.as_deref().unwrap_or("");
    let source = activation.data.pointer("/spec/source");

    // 1. Resolve: obtain manifests from source
    let new_manifests = match source_type {
        "oci" => ManifestArtifact::from_oci(reference).await?.to_manifest_list(),
        "storePath" => load_from_store_path(path)?,
    };

    // 2. Diff: compare against previous activation
    let old_manifests = load_previous_manifests(&activation)?;
    let actions = detect_changes(&new_manifests, &old_manifests);

    // 3. Plan: compute waves
    let graph = ResourceGraph::from_manifests(&new_manifests)?;
    let waves = compute_waves(&graph);

    // 4. Apply: wave-by-wave with readiness
    for (wave_idx, wave) in waves.iter().enumerate() {
        // Check resume point
        if wave_idx < resume_from { continue; }

        apply_wave(&client, &discovery, &wave_actions[wave_idx], false, act_hash).await;
        record_wave(&client, &ar, name, wave_idx, ...).await;
    }

    // 5. Prune: orphans in reverse topo order

    // 6. Finalize: update activation status
    finalize_deploy(&client, &ar, cluster_name, name, old_activation).await;

    Ok(Action::requeue(Duration::from_secs(300)))
}
```

**Key difference from CLI:** The operator doesn't prompt for confirmation, doesn't format output for terminals, and runs continuously. The `policy` field on the Activation CR controls behavior (halt vs rollback vs continue, prune policies, sync windows).

### Engine extraction prerequisite

Before building the operator, the deploy orchestration logic (wave loop, readiness polling, prune phase) should be extracted from `kix-cli/src/commands/deploy.rs` into `kix-cluster` as a library function:

```rust
// kix-cluster/src/reconcile.rs
pub struct ReconcileOptions {
    pub on_error: OnError,
    pub prune: bool,
    pub activation_hash: Option<String>,
    pub dry_run: bool,
}

pub struct ReconcileResult {
    pub created: usize,
    pub configured: usize,
    pub unchanged: usize,
    pub failed: usize,
    pub pruned: usize,
}

/// Progress callback for wave completion (CLI prints, operator writes status).
pub type ProgressFn = Box<dyn Fn(WaveProgress) + Send>;

pub async fn reconcile(
    client: &Client,
    new_manifests: &[Value],
    old_manifests: &[Value],
    options: ReconcileOptions,
    on_progress: ProgressFn,
) -> Result<ReconcileResult>;
```

The CLI's `run_deploy_async` becomes a thin wrapper that calls `reconcile` with a progress callback that prints to stdout. The operator calls the same function with a callback that writes to `status.waves`.

---

## 5. Implementation Order

```
                    ┌────────────────────┐
                    │ 1. normalize.rs    │  kix-manifest
                    │    (drift engine)  │
                    └────────┬───────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
    ┌─────────▼──────┐  ┌───▼──────────┐  ┌▼───────────────┐
    │ 2. kix diff    │  │ 3. artifact  │  │ 4. reconcile   │
    │    --live      │  │    pack/pull  │  │    extraction  │
    │  (CLI command) │  │  (CLI + lib)  │  │  (kix-cluster) │
    └────────────────┘  └──────┬───────┘  └───────┬────────┘
                               │                  │
                               └────────┬─────────┘
                                        │
                               ┌────────▼────────┐
                               │ 5. kix-operator │
                               │  (controller)   │
                               └─────────────────┘
```

1. **normalize.rs** — content-hash normalization + SSA field ownership extraction. Unblocks drift detection for both CLI and operator. Can be built and tested independently.

2. **`kix diff --live`** — wire normalize.rs into the existing diff command. Validates the normalization pipeline against real clusters.

3. **artifact pack/pull** — OCI artifact format, `kix artifact pack` CLI command, `ManifestArtifact` loader in kix-cluster. Unblocks operator manifest consumption.

4. **reconcile extraction** — extract the wave loop from deploy.rs into `kix-cluster/src/reconcile.rs` with progress callbacks. Unblocks operator use of the engine.

5. **kix-operator** — controller binary. Depends on 3 and 4. The last piece.

Steps 1-2 and 3-4 can proceed in parallel.

---

## 6. Open Questions

1. **OCI registry selection** — use a generic OCI registry (GHCR, Harbor) or build a kix-specific artifact store? Generic is simpler but means we're limited to OCI semantics. A kix-specific store could optimize for content-addressed deduplication.

2. **Artifact size** — for large clusters (500+ resources), the artifact could be 10-50MB of JSON. Should we compress? Split into layers per package? The OCI spec supports multi-layer artifacts, which would enable per-package layer caching.

3. **SSA fieldsV1 parsing** — the Kubernetes `fieldsV1` format is a JSON trie that's poorly documented. There's no existing Rust library for it. Options: (a) implement from scratch, (b) shell out to `kubectl diff` for the heavy lifting, (c) use the `full-strip` fallback and defer fieldsV1 parsing.

4. **Operator RBAC** — the operator needs broad cluster access (create/update/delete across all namespaces and resource types). How to scope this safely? Per-activation RBAC? Namespace-scoped operators?

5. **Leader election** — standard K8s leader election via Lease objects. But with multi-activation, should each activation have its own leader? Or one operator instance manages all activations?

6. **Rollback UX** — `kix rollback` should update the Activation CR's `spec.source` to point to the previous activation's artifact. The operator then reconciles normally. But how does the CLI know the previous artifact reference? The `kix.dev/previous` chain gives the identity-hash, but we need the artifact reference (OCI tag or store path).
