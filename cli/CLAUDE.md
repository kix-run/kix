# Kix CLI

Rust binary that wraps kixpkgs via Nix FFI. Users interact with `kix`, never raw `nix`.

## Architecture

**FFI-first** (not shell-out). Links against Nix C libraries via `nix-bindings-rust` crates (same as devenv 2.0). The crates are from `github:cachix/nix-bindings-rust` (branch `for-upstream`).

**Workspace layout:**
- `kix-cli/` — binary crate, clap CLI, command dispatch
- `kix-eval/` — Nix FFI wrapper: store, eval, cache, error translation
- `kix-manifest/` — K8s manifest types, YAML serialization, diff engine
- `kix-cluster/` — cluster operations: dump, deploy, status, graph

**Store:** `~/.cache/kix/{eval-store,store,eval-cache.db}` — no daemon, no `/nix/store`, no root.

**Eval cache:** SQLite keyed by BLAKE3 hash of `(nix_args + attr_name)`. Tracks file inputs with content hashes + mtimes for invalidation. Subsequent evals of unchanged clusters return in milliseconds.

## Commands

```
kix build <cluster>       # Render manifests to stdout (YAML)
kix diff <cluster>        # Colored diff against live cluster
kix check <cluster>       # Validate: eval + schema + policy
kix deploy <cluster>      # Wave-based deployment with confirmation (alias: apply)
kix status <cluster>      # Resource health table
kix list                  # Available clusters in this flake
kix graph <cluster>       # Dependency DAG visualization
kix inspect <cluster>     # Deep-dive: DI deps, parts, out
```

No instance-level filtering. The cluster is the unit of operation.

## Key Design Decisions

1. **`deploy` not `apply`** as primary verb (`apply` is an alias). Signals wave-based graph-aware deployment.
2. **No config file.** `flake.nix` is the sole source of truth.
3. **K8s users are the primary audience.** Never expose Nix terminology (`derivation`, `store path`, `eval`) in user-facing output.
4. **No persistent cluster cache.** Live-fetch resources via parallel LIST calls with label selectors. Explicit `kix snapshot` for CI/offline use.
5. **Exit codes:** 0 = success, 1 = error, 2 = diff exists (CI-friendly), 3 = usage error.

## Universal Flags

```
-o, --output yaml|json|table    # Default varies by command
--context <kube-context>        # Kubeconfig context
--dry-run                       # Preview mode (on deploy)
--diff                          # Show diff during deploy
--wait / --timeout <duration>   # Wait for readiness
--yes, -y                       # Skip confirmation
--quiet, -q                     # Suppress non-essential output
--verbose, -v                   # Show eval timing, Nix details
```

## FFI Details

### Crates
Use `nix-bindings-{expr,store,flake,util,fetchers}` from `github:cachix/nix-bindings-rust` (branch `for-upstream`). NOT the `nix-for-rust` crate on crates.io (same project, but the cachix fork has the flake API).

**TODO: Migrate to mainline `nixops4/nix-bindings-rust` when feasible.** Criteria to check before switching:
1. Flake API (`FlakeReference`, `LockedFlake`, `FlakeSettings`) available in mainline crate
2. Published on crates.io with the flake feature
3. Nix version compatibility ≥ 2.28 (our pinned version)
4. No regressions in APIs we use: `EvalStateBuilder.flakes()`, `Store::open`, value navigation
5. devenv has migrated (they are the upstream consumer — follow their lead)
Periodically check `github:nixops4/nix-bindings-rust` for upstream progress.

### Initialization sequence
```
1. nix_bindings_util::settings::set("experimental-features", "flakes")
2. nix_bindings_expr::eval_state::init()  // via std::sync::Once
3. gc_register_my_thread()  // RAII guard in thread_local storage
4. Store::open(url, params)
5. EvalStateBuilder::new(store).flakes(&flake_settings).build()
```

### Flake evaluation path
```
FlakeReference::parse_with_fragment(fetch_settings, flake_settings, flags, "path:.#cluster-nw1")
  → (flake_ref, fragment)
LockedFlake::lock(fetch_settings, flake_settings, eval_state, lock_flags, flake_ref)
  → locked_flake
locked_flake.outputs(flake_settings, eval_state)
  → Value (the flake outputs attrset)
eval_state.require_attrs_select(&outputs, &fragment)
  → Value (the cluster)
```

### Value navigation
- `eval_state.require_attrs_select(&v, "attr")` / `require_attrs_select_opt`
- `eval_state.require_list_strict::<Vec<Value>>(&v)`
- `eval_state.require_string(&v)`, `require_int(&v)`, `require_bool(&v)`
- No direct `value_to_json` — use `eval_from_string("builtins.toJSON expr", ".")` or walk manually

### Threading
- EvalState is NOT thread-safe. Single eval thread.
- Boehm GC requires thread registration: `gc_register_my_thread()` returns RAII guard.
- Store thread_local pattern: `thread_local! { static GC_REG: RefCell<Option<ThreadRegistrationGuard>> }`
- Nix init via `std::sync::Once`.

### Error handling
- FFI returns `anyhow::Result`. Convert to `miette::Result` at CLI boundary via `.to_miette()` trait.
- Enrich errors by combining FFI exception with captured Nix log bridge errors.
- `thiserror` in library crates, `miette` in binary crate.

### macOS caveat
Store paths must not traverse symlinks (`/tmp` → `/private/tmp`). Resolve before passing to Nix.

## Crate Stack

| Purpose | Crate | Notes |
|---------|-------|-------|
| CLI framework | `clap` 4.5+ derive | `#[command(alias = "apply")]` for deploy |
| Shell completions | `clap_complete` 4.5+ | bash, zsh, fish |
| Errors (lib) | `thiserror` 2.x | Typed errors |
| Errors (CLI) | `miette` 7.x | Rich diagnostics with source spans |
| Tables | `comfy-table` 7.x | Unicode-aware |
| Colors | `owo-colors` 4.x | Zero-alloc, NO_COLOR support |
| YAML | `serde_yml` 0.0.12+ | Active fork of unmaintained serde_yaml |
| JSON | `serde_json` 1.x | |
| Diff display | `similar` 2.x | Multi-line unified diffs |
| String similarity | `strsim` 0.11 | Rename detection |
| Parallel diff | `rayon` 1.x | Parallel resource comparison |
| Progress | `indicatif` 0.17+ | Auto-disables on non-TTY |
| K8s client | `kube` 3.1+ | DynamicObject, SSA, discovery |
| K8s types | `k8s-openapi` 0.27+ | Only for readiness conditions |
| DAG | `petgraph` | Wave computation via Kahn's algorithm |
| SQLite | `rusqlite` 0.31+ bundled | Eval cache |
| Testing | `assert_cmd` 2.x | CLI integration |
| Snapshots | `insta` 1.x | Snapshot testing |
| Ordered maps | `indexmap` 2.x | Keyed list matching in diff |
| Dir paths | `directories` | XDG-compliant ~/.cache/kix |

## Diff Engine

Custom structural differ on `serde_json::Value` — its own well-isolated module (or crate) with thorough unit tests. No existing crate handles keyed-list matching + ignore patterns.

- **Keyed lists**: containers/initContainers by `name`, ports by `name` or `containerPort:protocol`, env by `name`, volumes by `name`, volumeMounts by `mountPath`, subjects by `kind:name`
- **Normalization pipeline**: `fn(Value) -> Value` steps, different for kix-side vs cluster-side
- **75 resource types skipped** during cluster dump (ephemeral/runtime resources)
- **Content-hash early exit**: skip deep diff when hashes match (most resources unchanged)
- **Rename detection**: `strsim` normalized Levenshtein, mutual best-match, structural similarity filter

## Deploy Engine

- **Kahn's algorithm** for level-based topological sort → deployment waves
- **Kind priority tiebreaker** within waves: Namespace → CRD → SA → ConfigMap → Role → Service → Deployment → Job → Ingress
- **Content-hash change detection**: compare `kix.dev/content-hash` on live vs generated
- **SSA**: `kube::api::Patch::Apply` with `PatchParams::apply("kix").force()`
- **Readiness**: per-kind checks with `observedGeneration` guard for workloads
- **Failure modes**: `--on-error stop|continue` (default: stop)
- **Pruning**: warn by default, `--prune` to delete (reverse wave order), never auto-prune Namespaces

## Nix Flake Packaging

- **Build tool**: Crane (incremental: deps cached separately, simpler setup, widely adopted)
- **Nix input**: `github:NixOS/nix/2.28.0` (or cachix fork)
- **Binary**: ~50-80MB, dynamically linked against Nix C libs
- **Distribution**: `nix profile install github:kixpkgs/kixpkgs#kix` + Cachix binary cache
- **CI**: GitHub Actions + `cachix/install-nix-action` + `cachix/cachix-action`
- **Not self-contained**: requires Nix libs at runtime (rpath-linked)

## What Gets Replaced

| Current | Replaced by |
|---------|-------------|
| `nix build .#cluster-X` | `kix build X` |
| `scripts/kix-dump.py` | `kix-cluster/dump.rs` |
| `scripts/kix-diff.py` | `kix-manifest/diff.rs` |
| `pipeline/annotate.py` | Computed during eval |
| `pipeline/graph.py` | `kix-cluster/graph.rs` |

## Phased Delivery

1. **Phase 1:** `build`, `list`, `check` — FFI eval, YAML output, kubeconform
2. **Phase 2:** `diff` — live cluster fetch, structural diff, colored output
3. **Phase 3:** `graph`, `inspect` — DAG visualization, instance introspection
4. **Phase 4:** `deploy`, `status` — wave-based SSA, readiness polling
5. **Phase 5:** `rollback`, `destroy`, shell completions, additional preflight tools
