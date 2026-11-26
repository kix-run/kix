# 68: mkImport — Production Readiness

**Status:** Draft
**Related:** `65_passthrough_instances.md`, `29_compiler-design.md`, `63a_storage_as_cluster_concern.md`, `64_mvp_implementation_approach.md`

---

## Context

`mkImport` exists and works for the happy path: simple packages whose `out` is self-contained (valkey, stackgres-cluster) and raw imports with manual `out` (S3 endpoints in nw1). But it's not production-ready. This doc covers the concrete work needed to make imports trustworthy and visible.

**Out of scope:** passthrough instances (doc 65) are a different feature that extends beyond imports. This doc is strictly about making the existing import concept solid.

### What mkImport is

An import says: *"this resource exists in the cluster and is not my problem."* It participates in DI (provides `out` values so consumers can resolve against it) but produces no managed resources — only a marker PackageInstance CR.

Two modes:
- **Raw:** `mkImport { out = { endpoint = "..."; }; }` — manual values, no package involvement
- **`from`-assisted:** `mkImport { from = packages.valkey; }` — derives `out` by lazily evaluating the package build with import-mode scope (lightweight `mkImportResource`, no store paths)
- **Mixed:** both `from` and `out` — derived values with manual overrides on top

### What's missing

1. **Error clarity** — `from` passes proxy deps that throw on access; if a package's `out` touches a dep, the error is now actionable (implemented). But the broader UX of "why did my import fail" needs attention.
2. **Deploy-time validation** — no verification that the imported resource actually exists in the cluster.
3. **CLI awareness** — `kix list`, `kix health`, `kix deploy` don't distinguish imports from managed instances.

---

## 1. Proxy Deps for `from` Imports (Done)

**Problem:** When `from` is used, all dependency args were passed as `null`. If the package's `out` computation accessed a dep (e.g. `postgres.out.fqdn`), Nix threw an unhelpful "attribute 'out' missing from null" error buried in the trace.

**Solution:** Replace `null` deps with lazy `builtins.throw` proxies that produce actionable error messages:

```
Import instance 'valkey': package accessed dependency 'postgres', but imports
run without dependency resolution. Either use a raw 'out' override
(mkImport { out = { ... }; }) or use a mixed import
(mkImport { from = ...; out = { fieldThatNeedsDep = "value"; }; }).
```

This is already implemented in `lib/eval/import.nix`. The proxy is lazy — it never fires unless the code path actually touches the dep, which preserves the core laziness property of `from` imports.

---

## 2. Deploy-Time Validation

### 2.1 The Problem

An import claims a resource exists externally. Nothing verifies this. If you typo a namespace or the external resource gets deleted, `kix deploy` happily applies the marker CR and the consumer (e.g. immich) starts with broken connections.

### 2.2 What the Marker CR Carries Today

```yaml
metadata:
  annotations:
    kix.dev/mode: import
    kix.dev/import-name: valkey        # resource name
    kix.dev/import-fqdn: valkey.cache.svc.cluster.local
  namespace: cache                     # expected namespace
```

### 2.3 Adding Optional Resource Hints

Extend `mkImport` to accept optional `apiVersion` and `kind` hints:

```nix
kix.mkImport {
  from = packages.valkey;
  # Optional: tell the CLI what to look for
  apiVersion = "apps/v1";
  kind = "StatefulSet";
}
```

Or for raw imports:

```nix
kix.mkImport {
  out = { endpoint = "https://s3.example.com"; };
  # No kind/apiVersion — CLI skips resource check, only verifies namespace
}
```

These get serialized into the marker CR annotations:

```yaml
kix.dev/import-apiversion: apps/v1    # optional
kix.dev/import-kind: StatefulSet      # optional
```

### 2.4 CLI Validation Behavior

During `kix deploy`, before applying each wave:

1. **Collect all import markers** from the manifest set
2. For each import:
   - If `kind` + `apiVersion` are present → `kubectl get <kind>.<apiVersion> <name> -n <namespace>`. Fail with a clear error if not found.
   - If only namespace is present → verify the namespace exists. Warn (not fail) that the import can't be fully verified.
3. **Fail-fast by default** — if any verified import is missing, abort before applying the wave. Flag `--skip-import-checks` to override.

This runs once at the start of deploy, not per-wave — imports are pre-existing resources, their existence doesn't depend on wave ordering.

### 2.5 `from`-Assisted Hint Derivation

When `from` is used, the marker CR already knows the root resource's kind and apiVersion (from `mkImportResource`). We can auto-populate the hints:

```nix
# In evaluateImportInstance, extend marker annotations:
// lib.optionalAttrs (rootRes ? kind && rootRes.kind != "") {
  "kix.dev/import-kind" = rootRes.kind;
}
// lib.optionalAttrs (rootRes ? apiVersion && rootRes.apiVersion != "") {
  "kix.dev/import-apiversion" = rootRes.apiVersion;
}
```

This means `from`-based imports get validation for free — the package already declares what resource it creates, so the import knows what to look for.

Raw imports without `kind`/`apiVersion` get namespace-level validation only, which is the right default — if you're manually specifying `out`, you're taking responsibility.

---

## 3. CLI Awareness

### 3.1 `kix list`

Show import instances with an `(import)` marker:

```
NAMESPACE    INSTANCE         PACKAGE              STATUS
cache        valkey           valkey (import)      external
database     postgres         stackgres (import)   external
storage      hetzner-s3       — (import)           external
immich       immich           immich               ready
```

**Implementation:** The manifest set already contains the marker PackageInstance CRs with `kix.dev/mode: import`. Parse this annotation in the list command.

### 3.2 `kix health`

Imports should show as `external` rather than healthy/degraded/unknown. If validation hints are present, health could optionally verify the resource exists (same check as deploy-time, but on demand).

### 3.3 `kix deploy`

- Run import validation before wave 1 (see §2.4)
- Skip import markers in wave assignment — they're metadata CRs, not ordered resources
- Report validation results: `✓ 3 imports verified, 1 import unverifiable (no kind hint)`

### 3.4 `kix diff`

Already works — the marker CR shows up in the diff like any other resource. No changes needed.

### 3.5 `kix graph`

Show imports as distinct nodes (dashed border or different color). They're in the DI graph but not in the deploy DAG.

---

## 4. Implementation Sequence

### Phase 1: Marker Enrichment (Nix-side) ✓
- [x] Auto-populate `kix.dev/import-kind` and `kix.dev/import-apiversion` from `rootRes` in `evaluateImportInstance` when `from` is used
- [ ] Accept optional `apiVersion`/`kind` on `mkImport` for raw imports
- [x] Pass these through to the marker CR annotations
- [x] Add `isImport` to cluster instance info for CLI consumption

### Phase 2: CLI Validation (Rust-side) ✓
- [x] Parse import markers from manifest set (filter by `kix.dev/mode: import`) — `imports::collect_import_markers()`
- [x] Implement pre-deploy validation: targeted GET for imports with hints, unverifiable for others — `imports::validate_imports()`
- [x] `--skip-import-checks` flag
- [x] Report results before proceeding with wave deployment, fail-fast on missing imports

### Phase 3: CLI Visibility ✓
- [x] `kix list`: show `import [{ns}]` status for imported instances
- [x] `kix health`: show imports as `external` with `→` marker, separate count in summary
- [x] `kix graph`: dashed/gray nodes in dot output, `(import)` suffix in tree/JSON output

---

## 5. Open Questions

### 5.1 Should raw imports without hints fail or warn during deploy?

Current proposal: warn only. A raw import with just `out = { endpoint = "..."; }` is an external endpoint — there may not be a K8s resource to check at all (e.g. cloud S3). Namespace verification is the best we can do.

### 5.2 What about imports of cluster-scoped resources?

Some imports might reference cluster-scoped resources (e.g. a StorageClass, a ClusterIssuer). These don't have a namespace. The validation logic needs to handle `namespace: _cluster_` as "check cluster-wide."

### 5.3 Should `kix deploy` create the import marker CR if validation fails?

Probably not — if the import target doesn't exist, deploying the marker is misleading. The marker says "this is imported" but the thing it claims to import isn't there. Skip the marker and fail the deploy.
