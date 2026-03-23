# Kix CLI Design

> Temporary detailed design document. Captures research findings and design rationale for the Rust CLI. Will be pruned as decisions solidify and code is written.

Decision: Kix ships as a Rust binary using Nix FFI (not shell-out). Agreed by Adam (2026-03-23).

## Table of Contents

- [Requirements](#requirements)
- [FFI Approach: nix-bindings-rust](#ffi-approach-nix-bindings-rust)
- [Command Surface](#command-surface)
- [Output Conventions](#output-conventions)
- [Error Handling](#error-handling)
- [Rust Crate Architecture](#rust-crate-architecture)
- [FFI Integration Details](#ffi-integration-details)
- [Eval Caching](#eval-caching)
- [Python Script Replacement](#python-script-replacement)
- [Preflight Check Integration](#preflight-check-integration)
- [K8s CLI Research Findings](#k8s-cli-research-findings)
- [Phased Delivery](#phased-delivery)
- [Design Decisions Log](#design-decisions-log)

---

## Requirements

- Users should not need to install Nix separately
- No daemon, no root, no `/nix/store` requirement
- Must support `builtins.toFile` (Merkle DAG), `builtins.getContext` (dependency extraction), flake evaluation
- Must work on Linux and macOS
- CLI must feel native to Kubernetes operators (not Nix users)
- Pre-flight checks (`kix check`) orchestrate external tools pulled in via Nix store paths

---

## FFI Approach: nix-bindings-rust

### Why FFI, not shell-out

The original CLI_ARCHITECTURE.md recommended "start with shell-out, plan for FFI." This has been revised to **FFI in the first pass** because:

1. devenv 2.0 has proven the approach in production (thousands of users)
2. Structured error handling — `NixError { error_type, message, traces }` with file positions, not stderr text parsing
3. Eval caching — SQLite per-attribute cache gives millisecond repeat evals
4. Single binary — no separate `nix` binary to download/manage/version-pin
5. Demand is high, and FFI is the long-term target anyway

### The crate: nix-for-rust

- **Repository:** https://github.com/nixops4/nix-bindings-rust
- **Crate:** `nix-for-rust` on crates.io (v0.2.x)
- **License:** LGPL-2.1 (fine for dynamic linking)
- **C libraries linked:** `libnixexprc`, `libnixstorec`, `libnixutilc`, `libnixflakec`
- **Build:** pkg-config finds C headers/libraries. Nix flake provides them as buildInputs.
- **Runtime:** Libraries bundled via rpath (patchelf on Linux, install_name_tool on macOS)

### What devenv 2.0 proved

- Zero `Command::new("nix")` calls — entire codebase is FFI
- Single `EvalState` created once, reused across all operations in a session
- SQLite eval cache: subsequent runs in milliseconds for unchanged inputs
- Carries small patches against Nix C API (described as "fully upstreamable")
- Structured errors caught at FFI level, reformatted for devenv's TUI
- Works on macOS and Linux

### Threading constraints

- **Boehm GC:** Every thread touching Nix values must register with the GC via `gc_register_my_thread()`. The crate handles main thread automatically.
- **EvalState:** NOT thread-safe. Single eval thread only. Wrap in `Arc<Mutex<>>` if needed, but prefer single-thread eval with async I/O on separate threads.
- **Value lifetimes:** GC-managed. Rust wrappers prevent use-after-EvalState-drop, but be careful holding references across eval calls.

### macOS caveat

Store paths must not traverse symlinks. `/tmp` → `/private/tmp` on macOS causes Nix store errors. The CLI must resolve symlinks before passing paths to Nix.

### Alternatives considered

| Approach | Status | Why not |
|----------|--------|---------|
| Shell out to `nix eval` | Works today | Process overhead, no caching, no structured errors |
| Tvix/Snix | No flake support | 1-2 years from viability. `builtins.toFile` not working. GPL-3.0. |
| Nix daemon protocol | Requires daemon | Contradicts "no daemon" requirement |

---

## Command Surface

### Core Commands (Golden Path)

```
kix build <cluster>          # Render manifests to stdout (YAML)
kix diff <cluster>           # Colored diff against live cluster
kix check <cluster>          # Validate: eval + schema + policy + security
kix deploy <cluster>         # Wave-based deployment with confirmation
kix status <cluster>         # Show deployed resource health
kix list                     # List available clusters in this flake
```

`apply` is an alias for `deploy`.

### Extended Commands

```
kix graph <cluster>          # Dependency graph visualization
kix inspect <cluster>        # Deep-dive: DI deps, parts, out, resources
kix rollback <cluster>       # Revert to previous content-hash state
kix destroy <cluster>        # Tear down managed resources
```

### Why these verbs

| Verb | Rationale | Alternatives rejected |
|------|-----------|----------------------|
| `build` | Universal: timoni, kustomize, cdk8s all use it | `template` (Helm-specific), `synth` (cdk8s-specific) |
| `diff` | Built-in, not a plugin (Helm's mistake) | — |
| `check` | Broader than `lint` — covers schema + policy + cross-resource | `lint`, `validate` |
| `deploy` | Signals wave-based graph-aware deployment | `apply` (kept as alias), `sync` (ArgoCD-specific) |
| `list` | Universal across all tools | `ls` |
| `graph` | Unique to kix — no K8s tool has this | — |
| `inspect` | Deeper than `status` — shows internals | `describe` (kubectl term but different semantics) |

### The cluster is the unit of operation

Unlike Helm (release-centric) or kubectl (resource-centric), kix evaluates entire cluster definitions. The cluster name is always the primary argument. No instance-level filtering — the whole cluster is evaluated and operated on as a unit.

This matches kix's evaluation model: `buildCluster` runs a nested fixpoint across all instances with DI resolution. You can't evaluate one instance without the whole cluster.

### Universal Flags

```
-o, --output yaml|json|table    # Output format (default varies by command)
--context <kube-context>        # Kubeconfig context for cluster operations
--dry-run                       # Preview mode (on deploy)
--diff                          # Show diff during deploy
--wait / --timeout <duration>   # Wait for readiness
--yes, -y                       # Skip confirmation prompts
--quiet, -q                     # Suppress non-essential output
--verbose, -v                   # Show Nix eval details, timing
```

---

## Output Conventions

| Command | Default output | Alternatives |
|---------|---------------|--------------|
| `build` | Multi-doc YAML to stdout (`---` separated) | `-o json`: JSON array |
| `diff` | Colored unified diff (red/green) | `-o json`: structured diff |
| `check` | Summary table: tool, pass/fail, details | `-o json`: machine-readable |
| `deploy` | Per-resource action lines (created/configured/unchanged) | `-o json` |
| `status` | Table: NAME, NAMESPACE, KIND, READY, STATUS | `-o yaml`, `-o json` |
| `list` | Table: NAME, NAMESPACES, INSTANCES | `-o yaml`, `-o json` |
| `graph` | Terminal tree view | `--output dot` for Graphviz, `-o json` |

### Exit codes

- **0** — success
- **1** — error (eval failure, cluster unreachable, validation failure)
- **2** — diff exists (for CI: `kix diff nw1 || echo "drift detected"`)
- **3** — usage error (bad flags, unknown command)

---

## Error Handling

### Strategy

Intercept `NixError` at the FFI level. The C API provides structured errors with:
- Error type (EvalError, TypeError, AssertionError)
- Error message
- Stack traces with file:line:col positions

### Translation rules

1. **Strip `/nix/store` frames** — internal to Nix, meaningless to users. Show only frames in user code (packages/, clusters/, lib/).
2. **Rewrite file paths** — show relative to project root, not absolute store paths.
3. **Suggest fixes** — for "attribute missing" errors, compute edit-distance against valid attribute names and suggest the closest match.
4. **Scope to resource** — when possible, prefix errors with the K8s resource context: `Error in coredns (kube-system): attribute 'replicas' missing. Did you mean 'replicaCount'?`
5. **Distinguish phases** — make it clear whether the error is in eval (Nix), schema validation (kubeconform), or deployment (K8s API).

### Example transformation

**Raw Nix error:**
```
error: attribute 'replcias' missing
  at /nix/store/abc...-source/packages/coredns/default.nix:42:5
  at /nix/store/abc...-source/lib/eval.nix:598:12
```

**kix error:**
```
error: unknown attribute 'replcias' in packages/coredns/default.nix:42
  Did you mean 'replicas'?
```

---

## Rust Crate Architecture

```
cli/
  Cargo.toml                    # Workspace root
  kix-cli/
    Cargo.toml
    src/
      main.rs                   # Entry, clap derive, command dispatch
      commands/
        mod.rs
        build.rs
        diff.rs
        check.rs
        deploy.rs
        status.rs
        list.rs
        graph.rs
        inspect.rs
      output.rs                 # Shared output formatting (table, yaml, json)
  kix-eval/
    Cargo.toml
    src/
      lib.rs
      store.rs                  # Store::open, path management
      eval.rs                   # EvalState, flake attribute evaluation
      value.rs                  # Nix Value → serde_json::Value conversion
      cache.rs                  # SQLite eval cache
      error.rs                  # NixError → KixError mapping
  kix-manifest/
    Cargo.toml
    src/
      lib.rs
      types.rs                  # K8s resource structs (generic, serde-driven)
      serialize.rs              # JSON attrset → YAML manifest
      diff.rs                   # Structural manifest comparison
      validate.rs               # Preflight tool orchestration
  kix-cluster/
    Cargo.toml
    src/
      lib.rs
      dump.rs                   # Live cluster state normalization
      deploy.rs                 # Wave-based deployment engine
      status.rs                 # Resource health checking
      graph.rs                  # DAG traversal and visualization
```

### Key dependencies

```toml
[workspace.dependencies]
clap = { version = "4", features = ["derive"] }
nix-for-rust = "0.2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
serde_yaml = "0.9"
rusqlite = { version = "0.31", features = ["bundled"] }
kube = { version = "0.93", features = ["runtime", "client"] }
similar = "2"                  # Diff algorithm
comfy-table = "7"              # Table formatting
console = "0.15"               # Colors, terminal detection
indicatif = "0.17"             # Progress bars/spinners
tokio = { version = "1", features = ["full"] }
tracing = "0.1"                # Structured logging
```

---

## FFI Integration Details

### Core types (kix-eval)

```rust
pub struct KixEvaluator {
    store: Store,
    eval_state: EvalState,
    cache: SqliteCache,
}

impl KixEvaluator {
    /// Open evaluator with local store (no daemon, no root)
    pub fn new(cache_dir: &Path) -> Result<Self>;

    /// Evaluate a cluster, return structured output
    pub fn eval_cluster(
        &self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput>;

    /// List available clusters
    pub fn list_clusters(&self, flake_path: &Path) -> Result<Vec<String>>;
}

pub struct ClusterOutput {
    pub name: String,
    pub raw_manifests: Vec<serde_json::Value>,
    pub instances: HashMap<String, HashMap<String, InstanceInfo>>,
    pub activation: serde_json::Value,
}
```

### How eval works

The evaluator calls into the flake to get cluster output:

```rust
// Pseudocode
let expr = format!(
    r#"
    let
      flake = builtins.getFlake "{}";
      pkgs = import flake.inputs.nixpkgs {{}};
      cluster = flake.lib.forPkgs {{ inherit pkgs; lib = pkgs.lib; }};
    in cluster.mkAnnotatedManifests (cluster.packages.cluster-{})
    "#,
    flake_path, cluster_name
);
let value = self.eval_state.eval_from_string(&expr, "<kix>")?;
```

Or more directly, evaluate the flake output attribute:
```rust
let value = self.eval_state.eval_from_string(
    &format!(r#"(builtins.getFlake "{}").packages.{}.cluster-{}"#,
        flake_path, system, cluster_name),
    "<kix>"
)?;
```

The result is a derivation whose output is the manifest directory. For `build`, we need the `rawManifests` attribute (list of attrsets) to serialize in Rust rather than going through the Nix store.

### Store layout

```
~/.cache/kix/
  eval-store/          # Nix eval store (~14MB for kixpkgs)
  store/               # Local Nix store for builtins.toFile (~8MB)
  eval-cache.db        # SQLite cache
```

---

## Eval Caching

### Cache key

```
SHA256(canonical_flake_path + lockfile_contents + attr_path)
```

### Cache invalidation

- Any source file change → lockfile doesn't change, but flake input hash does → cache miss
- `flake.lock` change → all cache entries invalidated
- Manual: `kix cache clear` (future command)

### Cache storage

SQLite table:
```sql
CREATE TABLE eval_cache (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,      -- JSON serialization of eval result
    created_at INTEGER,
    accessed_at INTEGER
);
```

### Expected performance

- First eval: same as `nix eval` (seconds for large clusters)
- Repeat eval (unchanged): milliseconds (SQLite lookup + JSON deserialize)

---

## Python Script Replacement

### kix-dump.py → kix-cluster/dump.rs

**What it does:**
- Connects to K8s cluster via kubeconfig
- Fetches resources (modes: --match-kix, --managed, --namespaces, --all)
- Strips server-side fields: uid, resourceVersion, managedFields, status, creationTimestamp
- Strips Secret data (keeps metadata + type only)
- Filters 60+ ephemeral types (pods, replicasets, events, jobs, endpoints, etc.)
- Outputs normalized YAML files: `{ns}--{name}-{kind}.yaml`

**Rust approach:**
- Use `kube` crate for cluster connection
- Same normalization logic, same output format
- Integrated into `kix diff` (no separate dump step)

### kix-diff.py → kix-manifest/diff.rs

**What it does:**
- Compares two directories of YAML files (kix output vs cluster dump)
- Groups: identical, modified, kix-only, cluster-only
- Detects probable renames/moves (fuzzy matching + structural similarity)
- For modified resources: JSON-path-level diffs showing exact field differences
- Markdown output (designed for human + LLM consumption)

**Rust approach:**
- Use `similar` crate for diff algorithm
- JSON-path field comparison using serde_json traversal
- Colored terminal output (not markdown — terminal is the primary interface)
- `--output json` for machine-readable structured diff

### pipeline/annotate.py → computed during eval

**What it does:**
- Reads Nix store DAG via exportReferencesGraph
- Adds annotations: `kix.dev/identity-hash`, `kix.dev/content-hash`, `kix.dev/depends-on`

**Rust approach:**
- These annotations are already computed during Nix evaluation
- The CLI just needs to preserve them when serializing to YAML
- No separate annotation step needed

### pipeline/graph.py → kix-cluster/graph.rs

**What it does:**
- Produces deployment graph from manifests + closure DAG
- Visualization output

**Rust approach:**
- Parse `depends-on` annotations from manifests
- Build DAG in memory
- Terminal tree view (default) or DOT format (`--output dot`)
- Same DAG powers wave-based deployment ordering

---

## Preflight Check Integration

`kix check` chains multiple validation tools:

```
kix check <cluster>
  1. Nix eval — cross-resource validation (runs during eval, free)
  2. kubeconform — K8s schema validation including CRDs
  3. pluto — deprecated API detection
  4. kyverno CLI — org-specific policies
  5. trivy config — security misconfigs
  6. polaris/kube-score — best practice lint
```

### Tool management

Tools 2-6 are Nix store paths. The CLI fetches them on first run (or bundles them). The user never installs them manually.

Phase 1 includes kubeconform only. Others added in Phase 5.

---

## K8s CLI Research Findings

### Universal patterns across helm/kubectl/argocd/flux/timoni/pulumi

**The golden path workflow** (present in every tool studied):
1. Render/build → inspect what would be produced
2. Diff/preview → see what would change
3. Apply/deploy → make the change
4. Status → verify it worked

**Universal flags:**
- `-o yaml|json|table` — output format
- `--dry-run` — preview mode
- `--context` — kubeconfig context
- `--wait` / `--timeout` — readiness polling
- `--yes` / `-y` — skip confirmation

**Output conventions:**
- Rendered manifests: multi-doc YAML to stdout
- Status/list: table format by default
- Diff: colored unified diff, exit code for CI
- Deploy: per-resource action lines (created/configured/unchanged)

**What operators find surprising (avoid):**
- Requiring a plugin for diff (Helm's mistake)
- No `--dry-run` on the deploy verb
- Writing to files by default instead of stdout
- Interactive prompts without `--yes` escape
- Custom output formats instead of standard `-o yaml|json`
- Nix terminology in user-facing output

### How kix differs from existing tools

| Aspect | Existing tools | kix |
|--------|---------------|-----|
| Unit of operation | Release (Helm), resource (kubectl), app (ArgoCD) | Cluster |
| Dependency tracking | Manual or absent | Automatic via content-addressing |
| Deployment ordering | Manual or basic (Helm hooks) | Wave-based from DAG |
| Drift detection | Label-based (ArgoCD/Flux) | Content-hash based |
| Validation | Per-tool | 6-tool chain in one command |
| Graph visibility | None | First-class `kix graph` |

---

## Phased Delivery

### Phase 1: Build + List + Check (MVP)

**Goal:** Replace `nix build .#cluster-X` with `kix build X`

- Scaffold Rust workspace
- FFI: open local store, eval flake attribute, get JSON
- `kix list` — eval `builtins.attrNames` on cluster packages
- `kix build <cluster>` — eval cluster, serialize rawManifests to YAML stdout
- `kix check <cluster>` — eval + invoke kubeconform on output
- Error interception: catch NixError, strip store paths, show user-code traces
- SQLite eval cache
- Nix flake packaging (binary + bundled C libs)

**Verification:**
```bash
kix list                     # → example, nw1, full, minimal
kix build example            # → multi-doc YAML to stdout
kix build example -o json    # → JSON array
kix check example            # → pass/fail table
kix build nonexistent        # → friendly error, no nix stack trace
```

### Phase 2: Diff

**Goal:** Replace the two Python scripts with `kix diff`

- Port kix-dump.py normalization to Rust (kube crate)
- Port kix-diff.py comparison to Rust (similar crate)
- Colored unified diff output
- Exit code 2 when diff exists
- `--context` flag for kubeconfig context

### Phase 3: Graph + Inspect

**Goal:** Expose kix's unique dependency capabilities

- `kix graph <cluster>` — terminal tree + DOT export
- `kix inspect <cluster>` — DI deps, parts, out, resource list
- Port annotation logic

### Phase 4: Deploy + Status

**Goal:** Deploy from the CLI

- `kix deploy <cluster>` — wave-based from DAG
- Interactive confirmation, `--yes` to skip
- Per-resource status lines
- `--dry-run` server-side dry-run
- `kix status <cluster>` — health table

### Phase 5: Extended

- `kix rollback`, `kix destroy`
- Additional preflight tools (pluto, kyverno, trivy)
- Shell completions (bash, zsh, fish)
- `kix init` — scaffold new project

---

## Research Findings (Deep Dive)

### FFI: nix-bindings-rust Actual API

The `nix-bindings-rust` workspace contains 12 crates (6 `-sys` bindgen + 6 safe wrappers). The crates we need:

- `nix-bindings-expr` — EvalState, Value navigation, PrimOp, GC registration
- `nix-bindings-store` — Store::open, StorePath, build/realise
- `nix-bindings-flake` — FlakeReference, LockedFlake, FlakeSettings
- `nix-bindings-fetchers` — FetchersSettings
- `nix-bindings-util` — settings::set/get, Context

**Initialization sequence** (from devenv's actual code):
```rust
// 1. Settings BEFORE store
settings::set("experimental-features", "flakes nix-command")?;
settings::set("eval-cache", "false")?;

// 2. GC init (Once + thread_local)
static NIX_INIT: Once = Once::new();
NIX_INIT.call_once(|| { nix_bindings_expr::eval_state::init().unwrap(); });
// GC registration with thread_local RefCell<Option<ThreadRegistrationGuard>>

// 3. Store
let store = Store::open(store_uri.as_deref(), [])?;

// 4. EvalState with flake support
let eval_state = EvalStateBuilder::new(store.clone())?
    .flakes(&flake_settings)?
    .build()?;
```

**Flake evaluation** (the complete path for kix):
```rust
let flags = FlakeReferenceParseFlags::new(&flake_settings)?;
flags.set_base_directory(".")?;
let (flake_ref, fragment) = FlakeReference::parse_with_fragment(
    &fetchers_settings, &flake_settings, &flags,
    "path:.#packages.aarch64-darwin.cluster-nw1",
)?;
let lock_flags = FlakeLockFlags::new(&flake_settings)?;
let locked = LockedFlake::lock(
    &fetchers_settings, &flake_settings, &eval_state, &lock_flags, &flake_ref,
)?;
let outputs = locked.outputs(&flake_settings, &mut eval_state)?;
// Then navigate: eval_state.require_attrs_select(&outputs, &fragment)?
```

**Value navigation API**:
```rust
eval_state.require_attrs_select(&v, "name")?        // errors if missing
eval_state.require_attrs_select_opt(&v, "name")?     // None if missing
eval_state.require_attrs_names(&v)?                   // Vec<String>, sorted
eval_state.require_list_strict::<Vec<Value>>(&v)?     // force + collect
eval_state.require_string(&v)?                        // String
eval_state.require_int(&v)?                           // i64
eval_state.require_bool(&v)?                          // bool
eval_state.force(&v)?                                 // force to WHNF
```

**No `value_to_json`** in safe wrappers. Options:
1. `eval_from_string("builtins.toJSON expr", ".")` → get JSON string via Nix
2. Manual tree walk → build `serde_json::Value`

**Error handling**: All FFI returns `anyhow::Result`. devenv converts to `miette` via:
```rust
trait AnyhowToMiette<T> {
    fn to_miette(self) -> miette::Result<T>;
}
impl<T> AnyhowToMiette<T> for anyhow::Result<T> {
    fn to_miette(self) -> miette::Result<T> {
        self.map_err(|e| miette::miette!("{e:#}"))
    }
}
```

### devenv FFI Patterns (Production Reference)

Key patterns from devenv 2.0's actual source:

- **Nix fork**: `github:cachix/nix/devenv-2.32` (Cachix Nix fork exposing C API)
- **Build tool**: `Crane` (per-crate granularity), but **Crane recommended for kix** (simpler)
- **bindgen**: `rustPlatform.bindgenHook` handles LIBCLANG_PATH
- **Eval cache**: BLAKE3-keyed SQLite with file input tracking. `EvalInputCollector` captures all file read/env access ops during evaluation, stores as `Input` descriptors. On cache lookup, re-checks all linked file inputs (content hash + mtime).
- **Custom primops**: Injects Rust functions into Nix eval via `PrimOp::new()`
- **Send/Sync safety**: `unsafe impl Send + Sync` with careful field ordering for C++ destructor order on drop: `caching_eval_state → eval_state → store → settings → activity_logger → _gc_registration`
- **Almost zero shell-outs**: Only `Command::new` is for `cachix` daemon. All Nix ops are FFI.

### kube-rs Patterns

**Version**: `kube` 3.1.0, `k8s-openapi` 0.27.0

**Client with context selection**:
```rust
let kubeconfig = Kubeconfig::read()?;
let options = KubeConfigOptions { context: Some("nw1-prod".into()), .. };
let config = Config::from_custom_kubeconfig(kubeconfig, &options).await?;
let client = Client::try_from(config)?;
```

**Dynamic resource discovery** (2 API calls via aggregated discovery):
```rust
let discovery = Discovery::new(client.clone()).run_aggregated().await?;
for group in discovery.groups() {
    for (ar, caps) in group.recommended_resources() {
        let api: Api<DynamicObject> = if caps.scope == Scope::Namespaced {
            Api::namespaced_with(client.clone(), ns, &ar)
        } else {
            Api::all_with(client.clone(), &ar)
        };
    }
}
```

**Server-side apply** (for `kix deploy`):
```rust
let pp = PatchParams::apply("kix").force();  // field manager = "kix"
let result = api.patch(name, &pp, &Patch::Apply(manifest_json)).await?;
// Add .dry_run() for preview mode
```

**Readiness conditions** (built-in):
- `conditions::is_deployment_completed()`
- `conditions::is_pod_running()`
- `conditions::is_job_completed()`
- `conditions::is_crd_established()`
- Generic CR: check `.status.conditions` for `type: "Ready", status: "True"`

**Parallel resource fetching** via `JoinSet`:
```rust
let mut set = JoinSet::new();
for (ar, scope, ns) in resources {
    let client = client.clone();
    set.spawn(async move { api.list(&lp).await });
}
while let Some(result) = set.join_next().await { ... }
```

### Cluster State Fetching

**No persistent cache needed.** Parallel LIST with label selectors handles 300 resources in 200ms-2s.

- **`kix diff`**: fetch live → diff in memory → show results
- **`kix deploy`**: fetch live → compute changes → apply
- **`kix snapshot save ./dir`**: explicit dump for CI/offline use (replaces kix-dump.py)
- **Content-hash shortcut**: `kix.dev/content-hash` on live resources → skip unchanged in deploy

### Diff Engine Details

**Custom structural differ** — no existing crate handles keyed-list matching + ignore patterns.

**Normalization pipeline** (from actual Python analysis):

Cluster-side: `strip_server_fields → strip_secret_data → strip_labels_and_annotations(cluster=true) → strip_k8s_defaults → strip_empty_fields → normalize_configmap_data → normalize_paths → sort_arrays`

Kix-side: `strip_secret_data → strip_labels_and_annotations(cluster=false) → strip_k8s_defaults → strip_empty_fields → normalize_configmap_data → normalize_paths → sort_arrays`

**Server fields stripped**: uid, resourceVersion, creationTimestamp, generation, selfLink, managedFields, finalizers, status (entire key)

**K8s defaults stripped per kind**:
- Deployment/SS/DS: progressDeadlineSeconds, revisionHistoryLimit, default RollingUpdate strategy (25%/25%)
- Namespace: spec.finalizers
- CRD: spec.conversion if `{"strategy": "None"}`
- PVC: volumeMode if "Filesystem", volumeName
- Webhooks: caBundle, reinvocationPolicy, timeoutSeconds, default scope/port
- Pod specs: dnsPolicy, restartPolicy, schedulerName, terminationGracePeriodSeconds, imagePullPolicy, probe defaults

**Keyed list matching**:
- containers/initContainers: by `name`
- ports: by `name` or fallback `"{containerPort}:{protocol}"`
- volumes: by `name`
- volumeMounts: by `mountPath`
- env: by `name`
- hostAliases: by `ip`
- subjects: by `"{kind}:{name}"`

**Rename detection**: `strsim` normalized Levenshtein ≥ 0.6, mutual best-match, ≤ 5 non-name structural diffs.

**75 resource types** in SKIP_RESOURCES (ephemeral/runtime). Full list documented in Python analysis.

### Deploy Engine Details

**Wave computation**: Kahn's algorithm (level-based topological sort).

**Kind priority tiebreaker within waves**:
```
0: Namespace
1: NetworkPolicy, ResourceQuota, LimitRange
2: CustomResourceDefinition
3: ServiceAccount
4: PersistentVolumeClaim, PersistentVolume
5: ConfigMap, Secret
6: ClusterRole, ClusterRoleBinding, Role, RoleBinding
7: Service
8: DaemonSet, Deployment, StatefulSet
9: Job, CronJob
10: Ingress, IngressRoute
99: Everything else
```

**Change detection**: Compare `kix.dev/content-hash` annotation on live resource vs generated manifest. Hash match → skip. Hash differs or resource doesn't exist → apply.

**Pruning**: Warn-only by default. `--prune` deletes in reverse wave order. Never auto-prune Namespaces.

**Readiness checks with `observedGeneration` guard**:
- Deployment/SS: `readyReplicas == spec.replicas && updatedReplicas == spec.replicas && observedGeneration >= generation`
- DaemonSet: `numberReady == desiredNumberScheduled && updatedNumberScheduled == desiredNumberScheduled`
- Job: `succeeded >= 1`
- PVC: `phase == "Bound"`
- CRD: conditions contains `Established=True`
- ConfigMap/Secret/SA: immediate (existence = ready)
- Generic CR: check conditions for `Ready=True` or `Available=True`

**Failure modes**: `--on-error stop` (default) stops at failing wave. `--on-error continue` logs and proceeds. Resumability via idempotent content-hash detection.

**Self-describing manifests**: `kix.dev/depends-on` annotations contain identity hashes → CLI reconstructs DAG from manifests alone, no Nix store needed at deploy time.

### Nix Flake Packaging

**Build tool**: Crane (per-crate caching, scales to multiple future binaries). Overhead is running `Crane generate` after Cargo.lock changes.

**flake.nix integration** (concrete example):
```nix
inputs.crane.url = "github:ipetkov/crane";
inputs.nix.url = "github:NixOS/nix/2.28.0";

# In perSystem:
let
  craneLib = crane.mkLib pkgs;
  nixLibs = [
    nixPkg.libs.nix-expr-c
    nixPkg.libs.nix-store-c
    nixPkg.libs.nix-util-c
    nixPkg.libs.nix-flake-c
  ];
  commonArgs = {
    src = craneLib.cleanCargoSource ./cli;
    buildInputs = nixLibs ++ lib.optional stdenv.isLinux dbus;
    nativeBuildInputs = [ pkg-config rustPlatform.bindgenHook ];
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
  kix = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });
in { packages.kix = kix; apps.kix = { type = "app"; program = "${kix}/bin/kix"; }; }
```

**pkg-config names**: `nix-util-c`, `nix-store-c`, `nix-expr-c`, `nix-flake-c`, `nix-fetchers-c`, `bdw-gc`

**Binary size**: ~50-80MB (Nix C libs are substantial, dynamically linked)

**Distribution**: `nix profile install github:kixpkgs/kixpkgs#kix` + Cachix binary cache

**CI**: GitHub Actions matrix (x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin) + `cachix/install-nix-action` + `cachix/cachix-action`

### Rust CLI Patterns

**Error handling architecture**:
- `thiserror` in library crates (`kix-eval`, `kix-manifest`, `kix-cluster`)
- `miette` at the CLI boundary (`kix-cli`) — source spans, suggestions, colored diagnostics
- `miette` is perfect for Nix eval errors: can show source code snippets with labeled spans

**Output handling**:
- `owo-colors` for coloring (zero-alloc, NO_COLOR-aware)
- `comfy-table` for tables (Unicode-aware, dynamic column resize)
- `similar` for unified text diffs
- `indicatif` for spinners/progress (auto-disables on non-TTY)
- Color control via `OnceLock<bool>` checking NO_COLOR, TERM=dumb, and TTY detection

**Testing**:
- `assert_cmd` for CLI integration tests
- `insta` for snapshot testing (pairs with existing golden-file approach)
- Trait-based mocking for Nix eval boundary (not `mockall`)

**serde_yml** (not `serde_yaml`): active community fork, `serde_yaml` is unmaintained since 2023.

---

## Design Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-23 | FFI in first pass, not shell-out | Demand is high, devenv proved it, structured errors + caching are must-haves |
| 2026-03-23 | `deploy` as primary verb, `apply` as alias | Signals wave-based deployment, differentiates from plain kubectl apply |
| 2026-03-23 | No config file | flake.nix is the source of truth. No `kix.yaml`. |
| 2026-03-23 | No instance-level filtering | Cluster is the unit of operation. Instance filtering would be an anti-pattern. |
| 2026-03-23 | K8s users are primary audience | Nix is implementation detail. Never expose Nix terminology in user-facing output. |
| 2026-03-23 | No persistent cluster cache | Live-fetch via parallel LIST is fast enough (200ms-2s). Explicit snapshot for CI. |
| 2026-03-23 | Custom structural differ | No crate handles keyed-list matching + ignore patterns. ~200 lines of Rust. Own module/crate, thoroughly unit tested. |
| 2026-03-23 | Crane for Nix packaging | Per-crate caching scales to multiple binaries (future: kix-operator, kix-lsp). Overhead is just `Crane generate` after lockfile changes. |
| 2026-03-23 | nix-bindings-rust (cachix fork) | Same as devenv, has flake API, proven in production. **TODO: migrate to mainline `nixops4/nix-bindings-rust` when flake API is upstream and published on crates.io. Follow devenv's lead.** |
| 2026-03-23 | miette for CLI errors | Source spans + suggestions perfect for Nix eval errors. thiserror in libs. |
| 2026-03-23 | serde_yml not serde_yaml | serde_yaml unmaintained since 2023. serde_yml is the active fork. |
| 2026-03-16 | Rust binary (agreed Adam + Luca) | Users interact with `kix`, not raw `nix` |

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-23 | FFI in first pass, not shell-out | Demand is high, devenv proved it, structured errors + caching are must-haves |
| 2026-03-23 | `deploy` as primary verb, `apply` as alias | Signals wave-based deployment, differentiates from plain kubectl apply |
| 2026-03-23 | No config file | flake.nix is the source of truth. No `kix.yaml`. |
| 2026-03-23 | No instance-level filtering | Cluster is the unit of operation. Instance filtering would be an anti-pattern. |
| 2026-03-23 | K8s users are primary audience | Nix is implementation detail. Never expose Nix terminology in user-facing output. |
| 2026-03-16 | Rust binary (agreed Adam + Luca) | Users interact with `kix`, not raw `nix` |
