# Thin Operator — Production Readiness Plan

**Status:** Plan
**Related:** `44_operator_remaining_work.md`, `45_multi_team_and_operator_models.md`
**Goal:** A self-contained, deployable, observable kix operator that works without Nix on the host.

---

## 1. Current State

The operator engine is **functionally complete**:

- Controller loop (watch Activation CRs, reconcile, error backoff) ✓
- Wave-based deploy (Kahn's toposort, parallel SSA apply, readiness polling) ✓
- Activation lifecycle (Active/Superseded/Deploying, resume-after-crash, wave progress) ✓
- Finalizer-based GC (reverse topo delete on Activation removal) ✓
- Change detection (identity-hash DAG diff, no cluster queries) ✓
- Observer pattern (structured tracing for all events) ✓
- Integration test (e2e with kind cluster) ✓

**What's missing is everything around the engine** — the operator can reconcile, but it can't be deployed as a standalone service, it has a hard dependency on the local Nix store, and it lacks the operational features needed for production use.

---

## 2. Design Decisions (Made)

### D1: OCI artifacts as the manifest transport

The operator pulls pre-evaluated manifests from an OCI registry. No Nix store, no `nix-store` binary, no store path resolution in the operator pod.

**Why:** Cleanest separation of concerns. CI evaluates (has Nix), operator applies (has cluster access). Standard infrastructure (any OCI registry works). The operator image stays small and has no Nix dependencies.

**Artifact format:**
```
<oci-artifact>/
  kix-packages.json           # package index (existing format)
  kix-graph.json               # pre-resolved dependency graph (NEW)
  manifests/
    <identity-hash>.json       # one file per resource
```

`kix-graph.json` replaces the `nix-store -q --graph` call. It's baked into the artifact during `kix artifact push` by reading the store graph that `exportReferencesGraph` already produces during `nix build`.

### D2: Activation CR as the only interface

The operator watches Activation CRs. Period. No git watching, no webhook handling, no Nix evaluation. Something else (CI, a human, kix-cloud) creates the Activation CR. The operator applies what it says.

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: prod-a1b2c3d4
  labels:
    kix.dev/cluster: prod
spec:
  cluster: prod
  active: true
  source:
    type: oci                    # oci | inline
    oci:
      reference: ghcr.io/myorg/kix/prod:gen42
      pullSecretRef:             # optional
        name: registry-creds
        namespace: kix-system
```

### D3: Keep `storePath` source for local dev

For `kix deploy` and local development, `spec.source.type: storePath` continues to work. The operator running out-of-cluster on a dev machine with Nix installed can still use store paths directly. But the in-cluster operator only supports `oci` (and `inline` as a cheap fallback).

### D4: Status-driven observability

The operator writes all state to the Activation CR's status. No separate status endpoint, no custom metrics initially. The CR is the single source of truth for what's deployed.

```yaml
status:
  phase: Active              # Deploying | Active | Superseded | Failed
  lastReconcile: "2026-03-28T14:30:00Z"
  message: "Deployed successfully in 3 waves"
  waves:
    - index: 0
      status: Complete
      resources: 12
      applied: 8
      skipped: 4
    - index: 1
      status: Complete
      resources: 5
      applied: 5
  summary:
    created: 10
    configured: 3
    unchanged: 4
    pruned: 2
    failed: 0
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2026-03-28T14:30:00Z"
      message: "All waves applied successfully"
    - type: Progressing
      status: "False"
```

---

## 3. What Needs to Be Built

### Work Package 1: Artifact Format + CLI Commands

**New code.** The bridge between Nix evaluation and the operator.

#### 1a. `kix-graph.json` generation

During `nix build .#cluster-<name>-activation`, the pipeline already runs `exportReferencesGraph` to capture Nix store references. Extend the annotation pipeline (`pipeline/annotate.py` or the Nix derivation) to write a `kix-graph.json` file alongside `kix-packages.json`.

**Format:**
```json
{
  "nodes": {
    "/nix/store/abc...-deployment.json": {
      "identity_hash": "abc123...",
      "package": "immich",
      "namespace": "immich",
      "kind": "Deployment",
      "name": "immich-server"
    }
  },
  "edges": [
    { "from": "/nix/store/abc...-deployment.json", "to": "/nix/store/def...-configmap.json" }
  ]
}
```

This is the reference graph that `StoreGraph` currently computes from `nix-store -q --graph`. Pre-computing it removes the operator's only Nix store dependency.

**Test:** Build a cluster activation, verify `kix-graph.json` is present and parseable, verify it matches what `nix-store -q --graph` would produce.

#### 1b. `kix artifact push` CLI command

New CLI subcommand. Takes a local activation result directory, packages it as an OCI artifact, pushes to a registry.

```bash
kix artifact push \
  --activation ./result \
  --reference ghcr.io/myorg/kix/prod:gen42
```

**Implementation:**
1. Load StoreGraph from result dir
2. Stamp annotations
3. Write `kix-packages.json`, `kix-graph.json`, and individual manifest JSONs to a tarball
4. Push as OCI artifact using the `oci-distribution` crate (or shell out to `oras` initially)

**OCI media types:**
- Layer: `application/vnd.kix.activation.v1.tar+gzip`
- Config: `application/vnd.kix.activation.config.v1+json`

**Decision: oras vs native Rust.** Start by shelling out to `oras` CLI — it's widely available and handles auth, TLS, registry quirks. Replace with `oci-distribution` crate later if the external dependency is a problem.

**Test:** Push to a local registry (e.g. `registry:2` in Docker), pull back, verify contents match.

#### 1c. `kix artifact pull` (library function)

In `kix-lib`, a function that pulls an OCI artifact and returns the parsed manifest set.

```rust
// kix/src/eval/artifact.rs
pub struct ManifestArtifact {
    pub package_index: KixPackageIndex,
    pub graph: PrecomputedGraph,         // parsed kix-graph.json
    pub manifests: Vec<Value>,
}

impl ManifestArtifact {
    /// Pull from OCI registry, unpack, parse.
    pub async fn from_oci(
        reference: &str,
        pull_secret: Option<&str>,
    ) -> Result<Self, ArtifactError>;

    /// Load from a local directory (for testing / fallback).
    pub fn from_dir(path: &Path) -> Result<Self, ArtifactError>;
}
```

**Auth:** Support `imagePullSecrets` (read the Secret from the cluster, extract `.dockerconfigjson`, pass to the OCI client). Also support ambient auth (workload identity, EC2 instance role) for managed registries.

**Test:** Pull from local registry, verify manifests match what was pushed.

#### 1d. `PrecomputedGraph` — replace `nix-store -q --graph`

A new struct that reads `kix-graph.json` and produces the same `ResourceGraph` that the current code builds from the Nix store graph. The operator uses this instead of `StoreGraph`.

```rust
// kix/src/eval/artifact.rs (or graph_precomputed.rs)
pub struct PrecomputedGraph {
    pub resources: Vec<PrecomputedNode>,
    pub edges: Vec<(String, String)>,  // identity_hash → identity_hash
}

impl PrecomputedGraph {
    pub fn to_resource_graph(&self) -> Result<ResourceGraph, GraphError>;
}
```

**Test:** Build the same graph from both `StoreGraph` (Nix-based) and `PrecomputedGraph` (JSON-based), verify they produce identical wave plans.

---

### Work Package 2: Operator OCI Integration

**Modify existing code.** Wire the artifact loader into the controller.

#### 2a. Controller source resolution

Modify `controller.rs` to handle multiple source types:

```rust
// Replace current source_path() with:
enum ActivationSource {
    StorePath(PathBuf),
    Oci { reference: String, pull_secret: Option<PullSecretRef> },
}

fn resolve_source(activation: &DynamicObject) -> Result<ActivationSource, OperatorError> {
    match activation.data.pointer("/spec/source/type").and_then(|v| v.as_str()) {
        Some("oci") => { /* read spec.source.oci.reference, pullSecretRef */ }
        Some("storePath") | None => { /* existing behavior */ }
        other => Err(OperatorError::UnknownSourceType(other))
    }
}
```

In `reconcile_activation`, replace `load_and_stamp(&path)` with:
```rust
let artifact = match resolve_source(&activation)? {
    ActivationSource::StorePath(p) => ManifestArtifact::from_store_path(&p)?,
    ActivationSource::Oci { reference, pull_secret } => {
        ManifestArtifact::from_oci(&reference, pull_secret.as_ref()).await?
    }
};
let new_manifests = artifact.manifests;
```

#### 2b. Artifact caching

The operator shouldn't re-pull the same OCI artifact every 5 minutes on requeue. Add a local cache keyed by artifact digest.

```rust
// Simple on-disk cache
pub struct ArtifactCache {
    cache_dir: PathBuf,  // /var/cache/kix/artifacts/
}

impl ArtifactCache {
    pub async fn get_or_pull(&self, reference: &str, ...) -> Result<ManifestArtifact>;
}
```

Cache invalidation: the OCI reference includes a tag or digest. If the Activation CR's `spec.source.oci.reference` changes, the cache misses and pulls the new artifact.

#### 2c. Old activation manifests from artifact (not store path)

Currently `resolve_old_manifests()` calls `resolve_activation_by_hash()` which looks up a local Nix store path. In-cluster, there is no local store.

**Fix:** When the operator deploys successfully, cache the artifact locally (WP 2b). On next reconcile, load the old manifests from cache instead of from the Nix store.

Also store the previous artifact reference on the Activation CR:
```yaml
status:
  artifactDigest: sha256:abc123...    # what was last deployed
```

On reconcile, if the current artifact digest matches `status.artifactDigest`, skip (no changes). If different, pull new artifact, load old from cache, diff, deploy.

---

### Work Package 3: Container Image + Deployment Manifests

**New code.** Make the operator deployable.

#### 3a. Dockerfile

```dockerfile
FROM rust:1-slim AS builder
WORKDIR /src
COPY . .
RUN cargo build --release -p kix-operator

FROM gcr.io/distroless/cc-debian12
COPY --from=builder /src/target/release/kix-operator /kix-operator
# Include oras CLI for OCI pulls (or use native Rust client)
ENTRYPOINT ["/kix-operator"]
```

Target: <50MB image. No Nix, no shell, distroless base.

#### 3b. Deployment manifests as a kix package

The operator itself should be a kix package (`packages/kix-operator/`). It deploys into `kix-system` namespace.

**Resources:**
- Namespace: `kix-system`
- Deployment: `kix-operator` (1 replica, resource limits, liveness/readiness probes)
- ServiceAccount: `kix-operator`
- ClusterRole: broad read/write (see 3c)
- ClusterRoleBinding
- CRDs: Activation, PackageInstance (applied as wave 0, before the operator starts reconciling)

**Chicken-and-egg:** The operator can't deploy itself. First deploy uses `kix deploy` (CLI). After that, the operator manages its own upgrades (it watches its own Activation CR).

#### 3c. RBAC

The operator needs broad access because it applies arbitrary resource types:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kix-operator
rules:
  # Watch activations
  - apiGroups: ["kix.dev"]
    resources: ["activations", "activations/status", "packageinstances"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Apply any resource (SSA)
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  # API discovery
  - nonResourceURLs: ["/api", "/api/*", "/apis", "/apis/*"]
    verbs: ["get"]
```

This is intentionally broad. The operator is a cluster admin tool — scoping it down would require knowing in advance which resource types packages produce, which defeats the purpose. Document this clearly.

#### 3d. Health probes

Add HTTP health endpoints to `main.rs`:

```rust
// Liveness: is the process alive?
GET /healthz → 200

// Readiness: is the controller running and connected to the API server?
GET /readyz → 200 (if controller is running) | 503 (if not)
```

Use `axum` or `hyper` minimal server on a separate port (e.g. 8080).

---

### Work Package 4: Operational Hardening

**Modify existing code.** Make the operator reliable.

#### 4a. Leader election

Only one operator instance should reconcile at a time. Use kube-rs built-in leader election via Lease objects:

```rust
use kube::runtime::controller::Controller;

// In main.rs, before Controller::new_with:
let leader = kube::runtime::leader::LeaderElection::new(
    client.clone(),
    "kix-operator",
    "kix-system",
);
```

This prevents split-brain when running multiple replicas (e.g. during rolling updates).

#### 4b. Reconcile concurrency limits

The current controller processes activations with default concurrency. For production:
- Limit concurrent reconciles (e.g. 2-3 at a time)
- Add per-activation rate limiting to prevent reconcile storms

```rust
Controller::new_with(activations, watcher::Config::default(), ar.clone())
    .concurrency(2)
    .run(...)
```

#### 4c. Graceful shutdown

Handle SIGTERM properly — finish the current wave, record progress, exit. Don't start a new wave after receiving the signal.

```rust
let shutdown = tokio::signal::ctrl_c();
tokio::select! {
    _ = controller_future => {},
    _ = shutdown => {
        tracing::info!("Shutdown signal received, finishing current operations");
        // The reconcile engine already records wave progress,
        // so the next instance will resume from the right point.
    }
}
```

#### 4d. Metrics (Prometheus)

Expose standard controller metrics:

```
# Counter: reconciliations by result
kix_reconcile_total{cluster, result=success|error}

# Histogram: reconcile duration
kix_reconcile_duration_seconds{cluster}

# Gauge: active activations
kix_activations_active{cluster}

# Counter: resources applied
kix_resources_applied_total{cluster, action=created|configured|unchanged|pruned|failed}

# Counter: waves completed
kix_waves_completed_total{cluster}

# Gauge: current wave being applied (0 = idle)
kix_current_wave{cluster, activation}
```

Expose on `:9090/metrics`. Add a ServiceMonitor to the kix-operator package for auto-scraping.

#### 4e. Event recording

Write Kubernetes Events on the Activation CR for visibility in `kubectl describe`:

```
Events:
  Type    Reason              Message
  ----    ------              -------
  Normal  ReconcileStarted    Reconciling activation prod-a1b2c3d4 (12 resources, 3 waves)
  Normal  WaveComplete        Wave 0 complete: 5 applied, 2 skipped
  Normal  WaveComplete        Wave 1 complete: 3 applied, 0 skipped
  Normal  DeployComplete      Deployment complete: 8 applied, 2 unchanged, 1 pruned
  Warning ReadinessTimeout    Deployment immich/immich-server not ready after 300s
```

Use `kube::runtime::events::Recorder`.

---

### Work Package 5: CI Integration

**New code.** The glue between git and the operator.

#### 5a. GitHub Actions workflow

A reusable workflow that teams call from their repos:

```yaml
# .github/workflows/kix-deploy.yml
name: kix deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v30
      - name: Build activation
        run: nix build .#cluster-prod-activation --extra-experimental-features pipe-operators
      - name: Push artifact
        run: kix artifact push --activation ./result --reference ghcr.io/${{ github.repository }}/kix/prod:${{ github.sha }}
      - name: Update Activation CR
        run: |
          kubectl patch activation prod \
            --type merge \
            -p '{"spec":{"source":{"type":"oci","oci":{"reference":"ghcr.io/${{ github.repository }}/kix/prod:${{ github.sha }}"}}}}'
```

#### 5b. PR preview (blast radius)

On PR, build but don't deploy. Show what would change:

```yaml
# On PR: build, diff, comment
- name: Build activation
  run: nix build .#cluster-prod-activation --extra-experimental-features pipe-operators
- name: Diff against current
  run: kix diff --activation ./result --current-activation --format markdown > diff.md
- name: Comment on PR
  uses: actions/github-script@v7
  with:
    script: |
      const diff = fs.readFileSync('diff.md', 'utf8');
      github.rest.issues.createComment({
        issue_number: context.issue.number,
        body: `## kix deployment preview\n\n${diff}`
      });
```

This is the "smart CI" from doc 45 — the thin brain that validates before the thin operator applies.

---

## 4. What We're NOT Building (Scope Boundaries)

- **No Nix evaluation in-cluster.** The operator consumes artifacts, not flakes.
- **No drift remediation.** The operator applies on Activation CR change and requeues periodically (which re-applies if hashes differ). Active drift detection (comparing live state to intended state) is deferred to the fat brain / kix-cloud.
- **No multi-activation conflict resolution.** If two Activations try to create the same resource, last-write-wins (SSA). Conflict detection is a coordinator concern.
- **No dashboard / web UI.** The Activation CR status is the interface. Dashboards come with kix-cloud.
- **No rollback command.** Rollback = create a new Activation CR pointing to the old artifact. This can be done with `kubectl` or a future `kix rollback` CLI command.
- **No deploy windows / approval gates.** The operator applies immediately when it sees an active Activation. Gating is a CI or coordinator concern.

---

## 5. Implementation Order

```
WP1a  kix-graph.json generation          ░░░░░░░
WP1b  kix artifact push                  ░░░░░░░░░░
WP1c  artifact pull (library)                  ░░░░░░░░
WP1d  PrecomputedGraph                         ░░░░░░
                                                    │
WP2a  controller source resolution                  ░░░░
WP2b  artifact caching                              ░░░░░░
WP2c  old manifests from cache                       ░░░░
                                                         │
WP3a  Dockerfile                                         ░░░
WP3b  kix package for operator                           ░░░░░░
WP3c  RBAC                                               ░░░
WP3d  health probes                                      ░░░
                                                              │
WP4a  leader election                                         ░░░
WP4b  concurrency limits                                      ░░
WP4c  graceful shutdown                                       ░░░
WP4d  metrics                                                 ░░░░░
WP4e  event recording                                         ░░░
                                                                   │
WP5a  GitHub Actions workflow                                      ░░░░
WP5b  PR preview                                                   ░░░░░░
```

**Critical path:** WP1 → WP2 → WP3. Everything else can be parallelized.

**Milestone 1 — "It deploys from OCI":** WP1 + WP2. The operator can be run out-of-cluster, pulling manifests from a registry instead of the Nix store. Validates the artifact format end-to-end.

**Milestone 2 — "It runs in-cluster":** WP3. Dockerfile, RBAC, health probes. The operator runs as a pod in the cluster it manages.

**Milestone 3 — "It's production-ready":** WP4. Leader election, metrics, events, graceful shutdown. The operator can be trusted with real workloads.

**Milestone 4 — "Teams can use it":** WP5. CI integration, PR previews. The full workflow from git push to deployed resources.

---

## 6. Testing Strategy

| Test | What it validates | When to run |
|------|------------------|-------------|
| Unit: `PrecomputedGraph` matches `StoreGraph` | Artifact format is correct | Every build |
| Unit: artifact round-trip (pack → pull → compare) | OCI packaging is lossless | Every build |
| Integration: operator + kind + OCI registry | Full reconcile from OCI artifact | CI (slow, ~3min) |
| Integration: leader election failover | Only one instance reconciles | CI (slow) |
| Integration: resume after crash | Wave progress persisted, resumes correctly | CI (slow) |
| E2E: git push → CI → artifact → operator → deployed | Full workflow | Manual / nightly |

The existing `operator_integration_test.rs` should be extended to test OCI-based reconciliation alongside the current store-path-based test.
