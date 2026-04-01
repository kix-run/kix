# 63 — Storage Compilation: PVC Creation + Mount Wiring

**Status:** Design exploration
**Related:** `32_volume_mount_dsl.md` (mount helpers, `.path`, `.mountAt` — the foundation), `29_compiler-design.md` (§4.5 Storage Wiring), `39_di_driven_defaults_design.md` (archived, storage DI pattern)

---

## 1. Context

Doc 32 already designs the *mount wiring* side of storage: `.path` on mount objects, `.mountAt` on resources, volume deduplication, volume/mount-point split for multi-container pods. That design is solid and should be implemented as described.

This document addresses the *other* storage problem: **PVC creation boilerplate** inside packages that need local storage. It also clarifies the boundary between embedded PVCs and DI-provided storage.

---

## 2. The Two Storage Patterns Today

### Pattern A: First-Class PVC via DI (Already Good)

```nix
# Cluster definition:
instances.immich = {
  immich-library = {
    package = packages.persistent-volume-claim;
    aliases = [ "storage" ];
    config = { size = "200Gi"; };
  };
  immich = { package = packages.immich; };
};

# Package takes storage as hard dep:
build = { storage, ... }: {
  libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
};
```

The PVC is a separate instance, managed by the cluster operator, visible in kix-diff, lifecycle-protected. The package just mounts it. **This is the right model for stateful data.**

### Pattern B: Embedded PVC (The Boilerplate)

```nix
# Package creates its own PVC internally:
registryPVC = scope.mkResource {
  apiVersion = "v1";
  kind = "PersistentVolumeClaim";
  name = "${name}-registry";
  spec = {
    accessModes = [ "ReadWriteOnce" ];
    resources.requests.storage = config.persistence.registry.size;
  }
  // lib.optionalAttrs (config.persistence.registry.storageClass != null) {
    storageClassName = config.persistence.registry.storageClass;
  };
};

registryMount = kix.mount.pvc self.registryPVC {
  mountPath = "/storage";
};
```

~12 lines for a PVC + mount. Harbor has 3 of these (registry, jobservice, trivy). Immich ML has a conditional one (cache PVC vs emptyDir). Vaultwarden has one (data PVC).

The boilerplate: `apiVersion`, `kind`, `spec.accessModes`, `spec.resources.requests.storage`, and the conditional `storageClassName` are identical every time. Only `name`, `size`, and `mountPath` vary.

---

## 3. When to Use Which Pattern

| Concern | Pattern A (DI) | Pattern B (Embedded) |
|---------|---------------|---------------------|
| **Data lifecycle** | Outlives the package (user data, uploads) | Tied to the package (caches, logs, temp) |
| **Cluster operator visibility** | ✓ separate instance, kix-diff tracked | ✗ buried inside package |
| **Size/class control** | Cluster operator sets config | Package author sets defaults |
| **Cross-package sharing** | ✓ another package can mount same PVC | ✗ package-internal |
| **StorageClass selection** | Via DI dep (`storageClasses.out.storageClassName`) | Via config option or hardcoded |

**Rule of thumb:** If someone would be upset about losing the data when the package is removed → Pattern A (DI). If it's a cache or scratch space → Pattern B is fine.

---

## 4. Proposal: `scope.mkPVC` — PVC Shorthand

A helper on scope that creates a PVC resource with sensible defaults:

```nix
# In lib/eval/scope.nix:
mkPVC = {
  name,
  size,
  accessModes ? [ "ReadWriteOnce" ],
  storageClass ? null,      # null = cluster default
  ...
}@args:
scopeMkResource ({
  apiVersion = "v1";
  kind = "PersistentVolumeClaim";
  inherit name;
  spec = {
    inherit accessModes;
    resources.requests.storage = size;
  }
  // lib.optionalAttrs (storageClass != null) {
    storageClassName = storageClass;
  };
} // removeAttrs args [ "name" "size" "accessModes" "storageClass" ]);
```

### Before / After: Harbor Registry PVC

**Before** (~12 lines):
```nix
registryPVC = scope.mkResource {
  apiVersion = "v1";
  kind = "PersistentVolumeClaim";
  name = "${name}-registry";
  spec = {
    accessModes = [ "ReadWriteOnce" ];
    resources.requests.storage = config.persistence.registry.size;
  }
  // lib.optionalAttrs (config.persistence.registry.storageClass != null) {
    storageClassName = config.persistence.registry.storageClass;
  };
};
```

**After** (~4 lines):
```nix
registryPVC = scope.mkPVC {
  name = "${name}-registry";
  size = config.persistence.registry.size;
  storageClass = config.persistence.registry.storageClass;
};
```

Same output manifest. Same store path. Just less boilerplate.

### StorageClass from DI

When a package takes `storageClasses` as a DI dep, it threads through:

```nix
registryPVC = scope.mkPVC {
  name = "${name}-registry";
  size = config.persistence.registry.size;
  storageClass = if storageClasses != null then storageClasses.out.storageClassName else null;
};
```

This is the same pattern stackgres-cluster uses today (explicit fallback). `mkPVC` doesn't change the DI wiring — it just eliminates the manifest boilerplate.

---

## 5. Composing with Doc 32: `mkPVC` + `.mountAt`

When doc 32's `.mountAt` is implemented, the full embedded-PVC-with-mount pattern becomes:

```nix
# Today: ~15 lines
registryPVC = scope.mkResource { apiVersion = "v1"; kind = "PersistentVolumeClaim"; ... };
registryMount = kix.mount.pvc self.registryPVC { mountPath = "/storage"; };

# With mkPVC + mountAt: ~5 lines
registryPVC = scope.mkPVC { name = "${name}-registry"; size = "50Gi"; };
registryMount = self.registryPVC.mountAt "/storage";
```

The PVC resource is still visible in `self`. The mount is still explicit. But the ceremony is gone.

---

## 6. What This Does NOT Do

1. **No auto-PVC creation.** The package author explicitly creates each PVC. There's no magic "declare storage need → PVC appears."

2. **No replacement for Pattern A (DI storage).** `mkPVC` is for embedded/internal PVCs. User data PVCs should still be separate instances managed by the cluster operator.

3. **No storage class auto-detection.** The package or cluster config must specify the storage class. `mkPVC` doesn't query capabilities or DI deps — it just constructs the resource.

4. **No volume lifecycle management.** `mkPVC` creates a PVC resource like any other. Lifecycle protection (preventing accidental deletion) is handled by `meta.lifecycle = "stateful"` on the package, not on the PVC itself.

---

## 7. Alternative: `kix.mkPVC` in compose.nix (Scope-Free)

Instead of `scope.mkPVC`, put it in compose.nix as a pre-seal helper:

```nix
# In lib/compose.nix:
kix.pvc = { name, size, accessModes ? [ "ReadWriteOnce" ], storageClass ? null }:
{
  apiVersion = "v1";
  kind = "PersistentVolumeClaim";
  inherit name;
  spec = {
    inherit accessModes;
    resources.requests.storage = size;
  }
  // lib.optionalAttrs (storageClass != null) {
    storageClassName = storageClass;
  };
};

# Usage:
registryPVC = kix.pvc {
  name = "${name}-registry";
  size = "50Gi";
} |> scope.mkResource;
```

This follows the same pattern as `kix.ingress.fromService` — returns a pre-seal attrset, package calls `scope.mkResource` to seal it. Keeps compose.nix scope-free.

**Recommendation:** This is the better approach. It follows the existing pattern (`kix.X` returns attrset, `scope.mkResource` seals it) and doesn't add API surface to scope.

---

## 8. Implementation Plan

### Phase 0: Implement doc 32 phases 1-3

`.path` on mount objects, `.mountAt`/`.mount` on resources, volume deduplication. This is the foundation.

### Phase 1: Add `kix.pvc` to compose.nix

Simple pre-seal PVC builder. ~15 lines of code. Backward-compatible — existing packages keep working.

### Phase 2: Migrate embedded PVCs

Mechanical migration of packages with embedded PVCs (harbor, immich-ml, vaultwarden, filebrowser). Verify output hashes unchanged.

### Phase 3 (optional): `kix.options.persistence`

Shared options for the persistence config pattern:

```nix
kix.options.persistence = name: {
  size = lib.mkOption { type = lib.types.str; default = "10Gi"; };
  storageClass = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
};

# Package:
options.persistence.registry = kix.options.persistence "registry";
options.persistence.trivy = kix.options.persistence "trivy";
```

Low priority — the pattern isn't complex enough to warrant shared options yet.

---

## 9. Open Questions

### 9.1 Should `kix.pvc` set `outputs`?

The `persistent-volume-claim` package sets `outputs = { size = config.size; }` on its PVC. Should `kix.pvc` do the same? This would let consumers query `self.registryPVC.out.size` for validation.

Lean: yes. It's cheap and enables consumer-side checks (e.g., "warn if PVC < 50Gi").

### 9.2 Should embedded PVCs get `meta.lifecycle = "stateful"` automatically?

The persistent-volume-claim *package* declares `meta.lifecycle = "stateful"`. But embedded PVCs inside other packages don't — they're just resources, not packages. Should kix-diff/kix-gc treat PVCs specially regardless of package meta?

This is a broader question about resource-level metadata vs. package-level metadata. Defer to the resource type tags discussion (doc 38).

### 9.3 What about ephemeral storage?

Some packages use `emptyDir` for caches with an optional upgrade to PVC:

```nix
# immich-ml: conditional PVC vs emptyDir
cacheMount = if config.persistence.cache.enabled then
  kix.mount.pvc self.cachePvc { mountPath = "/cache"; }
else
  kix.mount.emptyDir { mountPath = "/cache"; name = "cache"; };
```

`kix.pvc` doesn't help here — the conditionality is the package's concern. But doc 32's `.mountAt` improves the PVC branch:

```nix
cacheMount = if config.persistence.cache.enabled then
  self.cachePvc.mountAt "/cache"
else
  kix.mount.emptyDir { mountPath = "/cache"; name = "cache"; };
```

This is already good enough. No further abstraction needed.
