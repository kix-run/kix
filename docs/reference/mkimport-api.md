# mkImport API Reference

## `kix.mkImport`

**Defined in:** `lib/eval.nix`
**Exported via:** `lib/default.nix`

Creates an import marker used as the `package` field for instances that represent external (non-kix-managed) resources.

```nix
kix.mkImport {
  from ? null,  # Package function to derive out from
  out  ? {},    # Manual out values (merged on top of derived)
}
```

**Returns:** `{ _type = "kix-import"; from; out; }`

This value is detected by `evaluateInstance`, which delegates to `evaluateImportInstance` instead of the normal evaluation path.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `from` | package function or `null` | `null` | A kix package function (e.g., `packages.valkey`). When provided, the package build runs with import-mode scope to derive `out` via lazy evaluation. |
| `out` | attrset | `{}` | Manual out values. When `from` is also set, these are merged on top of the derived values (overrides). When `from` is null, these are the only out values. |

### Instance-level fields

Import instances support the same module fields as regular instances:

| Field | Relevant for imports? | Notes |
|-------|----------------------|-------|
| `package` | Yes | Set to `kix.mkImport { ... }` |
| `packageType` | Yes | Required for DI resolution |
| `aliases` | Yes | Additional DI keys |
| `config` | Only with `from` | Evaluated against the package's options; only values affecting `out` matter |
| `deps` | No | Ignored — import builds receive null for all dependency args |
| `partsOverlays` | No | Ignored — no parts to overlay |
| `version` | No | Not used |

---

## `mkImportResource`

**Defined in:** `lib/k8s.nix`

Lightweight replacement for `mkResource` used in import mode. Computes `out` (name, fqdn, selector, outputs) without creating Nix store paths, manifests, or registry entries.

```nix
mkImportResource {
  name, namespace,
  apiVersion ? "", kind ? "",
  spec ? {}, data ? {}, stringData ? {},
  labels ? {}, annotations ? {},
  outputs ? {},
  requires ? [], extraDeps ? [],
  extra ? {},
}
```

**Returns:**

```nix
{
  _type = "k8s-resource-ref";
  name;          # K8s resource name (plain string, no context)
  namespace;     # as passed
  kind;          # as passed
  apiVersion;    # as passed
  out = {
    name;        # same as resource name
    fqdn;        # auto-derived: "${name}.${nsKey}.svc.cluster.local"
    selector;    # from spec.selector.matchLabels or labels (if non-empty)
  } // outputs;  # user-defined outputs (stringified)
  requires = []; # always empty
}
```

### Out derivation

| Field | Source | Notes |
|-------|--------|-------|
| `out.name` | `name` parameter | Plain string (no Nix context) |
| `out.fqdn` | `"${name}.${nsKey}.svc.cluster.local"` | Cluster-scoped resources get just `name` |
| `out.selector` | `spec.selector.matchLabels` or `labels` | Omitted if neither is set |
| Custom outputs | `outputs` parameter | Each value stringified via `toString` |

Unlike `mkResource`, output values carry **no Nix string context** — import resources are not part of the store DAG.

---

## `mkImportScope`

**Defined in:** `lib/eval.nix`

Creates a scope identical to `mkScope` but with `mkResource` and `mkClusterResource` replaced by `mkImportResource`-based versions. Injected into package functions during import evaluation.

```nix
mkImportScope {
  instanceName,
  namespaceName,
  namespaceResource,
  clusterLabels ? {},
}
```

The returned scope has the same shape as a regular scope:

- `scope.instanceName` — instance name
- `scope.namespaceName` — namespace name
- `scope.namespace` — namespace resource
- `scope.mkResource` — creates `k8s-resource-ref` (not `k8s-resource`)
- `scope.mkClusterResource` — creates cluster-scoped `k8s-resource-ref`
- `scope.rbac` — real RBAC DSL (available but unlikely to be forced)

---

## `evaluateImportInstance`

**Defined in:** `lib/eval.nix`

Evaluation path for import instances. Called by `evaluateInstance` when the package is a `kix-import`.

### Evaluation steps

1. **If `from` is provided:**
   - Creates `mkImportScope`
   - Introspects the package function args, passes `null` for all dependency args
   - Evaluates typed config (package options + instance config)
   - Runs the build fixpoint — Nix laziness means only `out`-relevant code evaluates
   - Extracts `mainRes.out` from the fixpoint
   - Merges manual `out` overrides on top

2. **If `from` is null:**
   - Uses the raw `out` from `mkImport` directly

3. **Creates a marker PackageInstance CR** with:
   - `kix.dev/mode: import` annotation
   - `kix.dev/import-name` and `kix.dev/import-fqdn` annotations (when available)
   - `spec.mode = "import"`

4. **Returns** an instance with `_type = "k8s-instance"`, `_isImport = true`, the marker as `_packageInstance`, and the derived `out`.

### What is skipped

Compared to normal `evaluateInstance`, the import path skips:

- Forward closure computation
- Inverse dependency detection
- Orphan / redundant-requires / duplicate-requires warnings
- Resource collection (only the marker CR enters the cluster graph)
- Parts overlays

---

## Marker PackageInstance

The marker is a real K8s resource deployed to the cluster:

```yaml
apiVersion: kix.dev/v1alpha1
kind: PackageInstance
metadata:
  name: <instanceName>
  namespace: <namespaceName>
  annotations:
    kix.dev/mode: import
    kix.dev/import-name: <out.name>
    kix.dev/import-fqdn: <out.fqdn>
  labels:
    app.kubernetes.io/instance: <instanceName>
    app.kubernetes.io/managed-by: kix
spec:
  instanceName: <instanceName>
  namespaceName: <namespaceName>
  mode: import
```

Deploy tooling can use the annotations to verify that the expected external resource exists in the cluster before proceeding.
