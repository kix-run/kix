# Kix CLI

Rust CLI for kixpkgs. Evaluates Nix-defined Kubernetes clusters, diffs against live state, and deploys wave-by-wave with SSA. Users run `kix`, never raw `nix`.

## Workspace

```
kix-cli/        binary — clap CLI, command dispatch, plan display
kix-eval/        Nix FFI, store graph, eval caching
kix-manifest/    K8s types, structural diff engine, annotation stamping
kix-cluster/     apply, fetch, DAG, waves, readiness, activation lifecycle
```

`kix-cli` depends on all three. `kix-cluster` depends on `kix-manifest`. No other cross-deps.

## Deploy pipeline

```
nix build → StoreGraph → stamp annotations
  → fetch old activation from cluster (or --current-activation for local cache)
  → detect_changes (identity-hash set diff, local only)
  → compute_waves (Kahn's toposort)
  → show package-grouped plan → confirm
  → apply wave-by-wave (SSA + readiness) → prune orphans → finalize activation
```

## Where things live

### kix-cli (`kix-cli/src/`)

- `cli.rs` — all clap command/flag definitions (`DeployArgs`, `GcArgs`, `DiffArgs`, `GlobalArgs`, enums)
- `plan.rs` — shared plan renderer for deploy + gc. `PackageDiff`/`PackageChangeDiff` types, `diff_graphs()` for package-level comparison, `print_package_plan()` for namespace-grouped changes-only display
- `output.rs` — color helpers (`green`/`red`/`yellow`/`dim`/`bold` → `Cow<str>`), `is_interactive()`, `CommandResponse` trait
- `commands/deploy.rs` — deploy pipeline: resolves old activation (from cluster or `--current-activation` cache), runs `detect_changes`, displays plan, confirms, delegates to `apply_wave`, prunes orphans
- `commands/diff.rs` — three modes: build-to-build (two StoreGraphs), vs live cluster, vs snapshot directory
- `commands/gc.rs` — soft (DAG diff old vs new) and hard (full cluster scan) garbage collection

### kix-eval (`kix-eval/src/`)

- `store_graph.rs` — **central data structure.** `StoreGraph` holds the full in-memory DAG: `PackageNode` (instance_name, namespace, version, resource_paths, cross_deps), `ResourceNode` (store_path, manifest). Built from result dir's `kix-packages.json` + `nix-store -q --graph`
- `store.rs` — activation cache at `~/.cache/kix/activations/`. `save/load_activation_path()` for local cache, `resolve_activation_by_hash()` to go from cluster identity-hash → local result dir
- `eval.rs` — `KixEvaluator` wrapping a `NixBackend` trait with SQLite caching
- `build.rs` — `build_cluster_activation_with_status()` shells out to `nix build .#cluster-{name}-activation`
- `cache.rs` — SQLite cache keyed by BLAKE3 of (flake path + lock + source fingerprint + attr)
- `mock.rs` — `MockNixBackend` for tests without Nix

### kix-manifest (`kix-manifest/src/`)

- `types.rs` — `ResourceId` (kind/namespace/name), `CLUSTER_SCOPED` constant. Used everywhere
- `stamp.rs` — `stamp_annotations()` writes `kix.dev/*` annotations onto StoreGraph manifests in-place
- `diff/engine.rs` — `structural_diff(a, b)` → `Vec<Difference>` with JSON paths. Keyed-list-aware
- `diff/keyed_lists.rs` — defines which K8s arrays match by key (containers→name, ports→name, env→name, volumeMounts→mountPath, subjects→kind:name)
- `diff/display.rs` — `format_diffs()` renders differences as colored text
- `serialize.rs` — YAML/JSON output, `load_manifests_from_dir()` for snapshot loading

### kix-cluster (`kix-cluster/src/`)

- `apply.rs` — `detect_changes()` (identity-hash set diff → `ChangeAction::Apply/Skip/Orphan`), `apply_wave()` (SSA via `kube`)
- `graph.rs` — `ResourceGraph` (petgraph DAG built from `kix.dev/depends-on` annotations)
- `waves.rs` — `compute_waves()` runs Kahn's algorithm → `Vec<Vec<NodeIndex>>`
- `readiness.rs` — `wait_for_ready()` polls per-kind conditions (Deployment replicas, CRD Established, Job succeeded, etc.)
- `activation.rs` — Activation CR lifecycle: `find_active()`, `begin_deploy()`, `record_wave()`, `finalize_deploy()`, `resume_point()`
- `fetch.rs` — `make_client()`, `discover_resources()`, `fetch_managed_resources()` (parallel LIST with label selectors)

## Key patterns

**Identity-hash** is the core primitive. First 32 chars of a Nix store path. Same hash = identical content + deps. Change detection is a hash set comparison — no deep diff needed.

**StoreGraph** is the in-memory DAG built from `kix-packages.json` + Nix store references. Everything operates on StoreGraph pairs (old vs new): change detection, plan display, stamping, GC.

**Keyed-list diff.** The diff engine matches K8s arrays by natural keys (containers by `name`, ports by `name`, env by `name`, volumeMounts by `mountPath`) not by position. Without this, reordering items produces false diffs.

**Waves** via Kahn's algorithm on the `kix.dev/depends-on` DAG. Within a wave, resources are independent. Lexicographic sort within waves for determinism.

**Annotations** stamped at build time: `kix.dev/identity-hash`, `kix.dev/package`, `kix.dev/depends-on`, `kix.dev/activations`. Everything downstream reads these, never raw store paths.

**Backend abstraction.** `NixBackend` trait — `FfiNixBackend` (production, `nix-ffi` feature) and `MockNixBackend` (tests, no Nix needed).

**Error boundary.** `thiserror` in libraries, `miette` in binary.
