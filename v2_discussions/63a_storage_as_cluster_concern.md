# 63a — Storage as a Cluster-Level Concern

**Status:** Design exploration
**Related:** `63_storage_compilation.md` (predecessor — good PVC helpers but wrong abstraction level), `32_volume_mount_dsl.md` (mount wiring), `62a_exposure_as_composable_build_entry.md` (same "lift the concern" principle)

---

## 1. The Real Problem

Doc 63 proposed `kix.pvc` as a helper for creating PVCs inside packages. But the insight is: **the person choosing storage isn't the package author — it's the cluster operator.**

The package author knows: "I need persistent storage at `/data`."
The cluster operator knows: "This cluster has fast-nvme and slow-hdd storage classes, and immich should get 200Gi on fast-nvme."

Today, the cluster operator expresses this by creating a separate `persistent-volume-claim` instance:

```nix
# clusters/ludo/services.nix
instances.immich = {
  storage = {
    package = packages."persistent-volume-claim";
    config.size = "100Gi";
  };
  immich = {
    package = packages.immich;
  };
};
```

This works but has two problems:

**Problem 1: A whole package for a PVC feels overkill.** The `persistent-volume-claim` package is 63 lines including meta, options, and build — all to produce a single PVC resource. It has its own DI dep (`storageClasses`). It's a full participant in the resolution index. For what is fundamentally `{ size = "100Gi"; }` from the cluster operator's perspective.

**Problem 2: DI doesn't understand exclusivity.** A ReadWriteOnce PVC can only be mounted by one workload. But DI resolution happily resolves `storage` for multiple consumers to the same PVC instance. If the cluster has one `storage` instance and both immich and vaultwarden need storage, DI gives them the same PVC — which fails at runtime.

The current workaround (from ludo/services.nix) is putting each service in its own namespace with its own `storage` instance. This works because DI prefers same-namespace matches. But it's implicit — nothing *prevents* two services in the same namespace from resolving to the same PVC.

---

## 2. What the Cluster Operator Wants to Write

The ideal cluster definition for the ludo homelab:

```nix
instances.immich = {
  immich = {
    package = packages.immich;
    config = {
      image.tag = "v2.0.0";
      ingress.host = "photos.${domain}";
    };
    storage.size = "100Gi";      # ← This is all the operator wants to say
  };
};
```

Or even more minimally — just the size, since the storage class comes from the cluster's default:

```nix
instances.immich.immich = {
  package = packages.immich;
  storage = "100Gi";
};
```

The cluster operator shouldn't need to:
- Know that `persistent-volume-claim` is a package
- Create a separate instance for storage
- Understand DI resolution to connect storage to the consumer
- Worry about ReadWriteOnce exclusivity

---

## 3. Approaches

### Approach A: Sugar on the Instance Config

Add a `storage` option to the instance submodule (in `modules.nix`) that auto-creates a PVC companion instance:

```nix
# In lib/modules.nix, instance submodule:
storage = lib.mkOption {
  type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.submodule {
    options = {
      size = lib.mkOption { type = lib.types.str; };
      storageClass = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      accessModes = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "ReadWriteOnce" ]; };
    };
  }));
  default = null;
};
```

When `storage` is set, the cluster builder auto-creates a PVC instance in the same namespace, wired to the consuming package via explicit `deps.storage` override.

**Cluster definition:**
```nix
instances.immich.immich = {
  package = packages.immich;
  storage = "100Gi";           # shorthand for { size = "100Gi"; }
  # or:
  storage = { size = "100Gi"; storageClass = "fast-nvme"; };
};
```

**What happens under the hood (in cluster.nix):**
```nix
# Auto-generated from instance.storage:
instances.immich."immich-storage" = {
  package = packages.persistent-volume-claim;
  config.size = "100Gi";
  # Not aliased as "storage" — only wired to this specific consumer
};
instances.immich.immich.deps.storage = ref.immich."immich-storage";
```

**Pros:**
- Minimal syntax for the cluster operator
- PVC is still a real instance — visible in kix-diff, lifecycle-protected
- No DI ambiguity — storage is wired via explicit `deps`, not alias resolution
- String shorthand (`"100Gi"`) makes the 80% case trivial

**Cons:**
- Couples `modules.nix` to the PVC package concept
- `storage` as a module option implies every instance *could* have storage, even ones that don't declare a `storage` dep
- The auto-generated instance name (`${instName}-storage`) is a convention that could clash

### Approach B: Inline Resource on Instance Config

Instead of auto-creating a companion instance, let the cluster operator declare storage as an inline resource that the eval system wires into the package's `storage` dep:

```nix
instances.immich.immich = {
  package = packages.immich;
  provide.storage = {
    kind = "PersistentVolumeClaim";
    size = "100Gi";
    storageClass = "fast-nvme";
  };
};
```

The eval system sees `provide.storage`, creates the PVC resource inline (not as a separate instance), and passes it to the package's `storage` build arg.

**Pros:**
- Explicit: `provide.storage` clearly maps to the package's `storage` dep
- No separate instance — lighter weight
- Generalizable: `provide.X` could work for any dep that's just config

**Cons:**
- The PVC isn't a standalone instance → no lifecycle protection, no kix-diff visibility
- "Inline resource" is a new concept — not a package, not an import, not a regular instance
- The package still needs to handle a PVC resource as its `storage` dep. What does the inline PVC expose as `out`? It needs `out.name` at minimum.

### Approach C: Config-Level Storage Declaration (Package Declares Need, Cluster Provides)

The package declares "I need storage" as a structured requirement. The cluster provides it as config. No DI resolution for storage at all — it's a config concern.

**Package:**
```nix
{ scope, lib, kix }:
{
  options = {
    storage = lib.mkOption {
      type = lib.types.submodule {
        options = {
          size = lib.mkOption { type = lib.types.str; default = "10Gi"; };
          mountPath = lib.mkOption { type = lib.types.str; };
          storageClass = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          accessModes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ReadWriteOnce" ];
          };
        };
      };
    };
  };

  build = { self, config, scope, kix, ... }: {
    pvc = kix.pvc {
      name = "${scope.instanceName}-data";
      size = config.storage.size;
      storageClass = config.storage.storageClass;
      accessModes = config.storage.accessModes;
    } |> scope.mkResource;

    storageMount = self.pvc.mountAt config.storage.mountPath;  # doc 32

    deployment = { ... }
      |> kix.withMounts [ self.storageMount ]
      |> scope.mkDeployment;

    root = self.service;
  };
}
```

**Cluster:**
```nix
instances.immich.immich = {
  package = packages.immich;
  config.storage = {
    size = "200Gi";
    storageClass = "fast-nvme";
    mountPath = "/usr/src/app/upload";
  };
};
```

**Pros:**
- No DI needed for storage — it's just config
- Cluster operator controls size and class via the normal config mechanism
- PVC is created inside the package → part of the package's store DAG
- `mountPath` is set by the package default, overridable by the cluster operator

**Cons:**
- The package creates the PVC internally → less visible to the cluster operator
- If the mount path is an implementation detail (e.g., immich's `/usr/src/app/upload`), it shouldn't be in the cluster config
- Loses the DI-driven validation story (consumer checks `storage.out.size`)
- Every package that needs storage must implement the PVC creation boilerplate (though `kix.pvc` helps)

### Approach D: `kix.withStorage` Build Entry (Following 62a Pattern)

Like `kix.expose` from doc 62a — a reusable build entry that handles PVC creation:

**Package:**
```nix
{ scope, lib, kix }:
{
  options = {
    storage = kix.options.storage {
      defaultSize = "10Gi";
      defaultMountPath = "/data";
    };
  };

  build = [
    ({ self, config, scope, kix, ... }: {
      deployment = { ... }
        |> kix.withMounts [ self.storageMount ]  # storageMount provided by kix.withStorage
        |> scope.mkDeployment;
      service = ...;
      root = self.service;
    })

    (kix.withStorage {
      mountPath = "/data";            # package default
      partName = "dataStorage";       # name in self for the PVC
      mountName = "storageMount";     # name in self for the mount
    })
  ];
}
```

**Cluster:**
```nix
instances.immich.immich = {
  package = packages.immich;
  config.storage.size = "200Gi";
  config.storage.storageClass = "fast-nvme";
};
```

The `kix.withStorage` entry:
1. Reads `config.storage.size`, `config.storage.storageClass` from the evaluated config
2. Creates a PVC resource via `scope.mkResource`
3. Creates a mount object via `kix.mount.pvc`
4. Adds both to `self` as `self.dataStorage` (PVC) and `self.storageMount` (mount)
5. Declares `storageClasses ? null` as its DI dep for the storage class

**Pros:**
- Package author just says "I need storage at /data"
- Cluster operator just says "give it 200Gi on fast-nvme"
- PVC is a real resource in the store DAG
- Reusable across packages
- DI still works for storage class resolution

**Cons:**
- The app's build entry references `self.storageMount` before it exists (defined by the later entry). This works because of the fixpoint — `self` is the merged result of all entries. But it requires the developer to know the mount name convention.
- Multiple storage volumes need multiple `kix.withStorage` entries with different names
- Mount path is declared twice — once in `kix.withStorage` (for the build entry) and available via `self.storageMount.path` (for env vars). This is fine.

### Approach E: Hybrid — DI for External, Config for Embedded

Recognize that **the two storage patterns serve different needs** and don't try to unify them:

**External storage (Pattern A):** User data that outlives the package. The cluster operator creates it as a separate instance. DI resolution connects it. This is the right model and doesn't need to change — but it does need exclusivity semantics.

**Embedded storage (Pattern B):** Caches, logs, temp data tied to the package lifecycle. The package creates it internally, sized via config. `kix.pvc` (doc 63) + `kix.withStorage` (approach D above) make this ergonomic.

The key insight: **the cluster operator should only need to create separate PVC instances for data they care about.** Caches and scratch storage should be config, not instances.

**For immich specifically:**
- The photo library is external storage (Pattern A) — the operator cares about its size, class, and lifecycle
- The ML cache is embedded storage (Pattern B) — the package manages it, operator just sets size via config

Today, both use DI. The proposal: keep DI for the library (it's data the operator owns), switch to config for the cache (it's an implementation detail).

---

## 4. Recommendation: Approach A (Instance Sugar) + E (Hybrid)

### For operator-managed storage: Approach A

Add `storage` to the instance submodule. When set, the cluster builder auto-creates a `persistent-volume-claim` companion instance and wires it via `deps.storage`.

```nix
# What the operator writes:
instances.immich.immich = {
  package = packages.immich;
  config.ingress.host = "photos.${domain}";
  storage = "200Gi";
};

# What the cluster builder produces internally:
instances.immich."immich-storage" = {
  package = packages.persistent-volume-claim;
  config = { size = "200Gi"; };
};
instances.immich.immich.deps.storage = /* ref to immich-storage */;
```

Benefits:
- The PVC is still a real instance — visible, lifecycle-protected, in the dependency graph
- The cluster operator writes one line instead of a separate instance block
- No DI ambiguity — `deps.storage` is an explicit override, not alias-based resolution
- The `persistent-volume-claim` package continues to work for advanced cases (explicit instance, custom access modes, etc.)

The string shorthand (`"200Gi"`) covers the 80% case. The structured form covers the rest:

```nix
storage = {
  size = "200Gi";
  storageClass = "fast-nvme";
  accessModes = [ "ReadWriteMany" ];
};
```

### For package-internal storage: Config + kix.pvc

Caches, logs, scratch volumes use `kix.pvc` (doc 63) with config-driven sizing:

```nix
# Package:
options.cache.size = lib.mkOption { default = "5Gi"; };

build = { self, config, scope, kix, storageClasses ? null, ... }: {
  cachePvc = kix.pvc {
    name = "${scope.instanceName}-cache";
    size = config.cache.size;
    storageClass = if storageClasses != null then storageClasses.out.storageClassName else null;
  } |> scope.mkResource;

  cacheMount = self.cachePvc.mountAt "/cache";  # doc 32
  # ...
};

# Cluster:
instances.immich.immich.config.cache.size = "10Gi";
```

No separate instance needed. The PVC is internal to the package.

---

## 5. DI Exclusivity: The ReadWriteOnce Problem

### The Problem

DI resolves `storage` by name/alias. If two packages in the same namespace both declare `storage` as a required dep, and there's one `storage` instance, both get the same PVC. A ReadWriteOnce PVC mounted by two workloads fails at runtime.

### Short-Term Fix: Naming Convention

With approach A's `deps.storage` explicit wiring, this problem goes away for auto-created storage — each consumer gets its own PVC via `deps`. The problem only exists with manual DI resolution.

The naming convention from ludo already handles this: each service gets its own namespace (or its own explicitly-named storage instance). The operator writes `storage = "100Gi"` per instance, not a shared one.

### Medium-Term: `meta.scope = "exclusive"`

Add an exclusivity flag to package meta:

```nix
meta = {
  lifecycle = "stateful";
  scope = "namespace";
  exclusive = true;  # NEW: only one consumer may resolve to this instance
};
```

During DI resolution, if an instance marked `exclusive = true` would be resolved by a second consumer, throw an error:

```
error: instance 'storage' in namespace 'immich' is marked exclusive
  but is resolved by both 'immich' and 'filebrowser'
  — create separate storage instances or use explicit deps
```

This is a validation enhancement, not a fundamental DI change. It catches the mistake at build time instead of runtime.

### Long-Term: Typed DI Slots

The more principled solution is typed DI — a package declares not just "I need storage" but "I need exclusive ReadWriteOnce storage of at least 10Gi":

```nix
deps = {
  storage = {
    type = "storage";
    exclusive = true;
    constraints = {
      minSize = "10Gi";
      accessModes = [ "ReadWriteOnce" ];
    };
  };
};
```

This is the "declarative dep constraints" item from the ROADMAP (line 18). It's a bigger design change and should be deferred — but the direction is clear.

---

## 6. Multiple Storage Volumes

Some packages need multiple storage volumes (harbor: registry + jobservice + trivy). With approach A:

```nix
instances.harbor.harbor = {
  package = packages.harbor;
  storage = {
    registry = { size = "100Gi"; storageClass = "fast-nvme"; };
    jobservice = { size = "10Gi"; };
    trivy = { size = "5Gi"; };
  };
};
```

This requires the package to declare **named storage slots**:

```nix
# packages/harbor meta:
meta.storage = {
  registry = { default = "50Gi"; description = "Container image layers"; };
  jobservice = { default = "10Gi"; description = "Job log storage"; };
  trivy = { default = "5Gi"; description = "Vulnerability database cache"; };
};
```

The cluster builder would create three PVC instances (`harbor-registry-storage`, `harbor-jobservice-storage`, `harbor-trivy-storage`) and wire them via `deps.registryStorage`, `deps.jobserviceStorage`, `deps.trivyStorage`.

**Alternatively:** Harbor's internal PVCs (jobservice logs, trivy cache) are internal concerns — they should use config + `kix.pvc`, not DI. Only the registry storage (user data) needs the DI/instance model.

This reinforces the hybrid approach (§4): operator-managed data gets instance sugar, internal caches get config + `kix.pvc`.

---

## 7. Implementation Plan

### Phase 1: `kix.pvc` helper (doc 63)

Add the PVC builder to compose.nix. Small, no dependencies. Enables the config-driven pattern for internal storage.

### Phase 2: Instance `storage` sugar

Add `storage` to the instance submodule in `modules.nix`. Auto-create companion PVC instances in `cluster.nix`. Wire via explicit `deps`.

Design decisions needed:
- Single vs multiple storage slots (recommend: single for now, name it `storage`)
- Naming convention for auto-created instances (`${instName}-storage`)
- Where the storage class comes from (DI via `storageClasses` on the auto-created PVC, or from the `storage` config)

### Phase 3: `meta.exclusive` validation

Add exclusivity flag to package meta. Validate during DI resolution that exclusive instances aren't shared.

### Phase 4: Migrate packages

- immich: keep DI for library storage (use `storage = "200Gi"` sugar), switch ML cache to config + `kix.pvc`
- harbor: registry storage via `storage` sugar, jobservice/trivy via config + `kix.pvc`
- vaultwarden: `storage = "1Gi"` sugar
- filebrowser: `storage = "100Gi"` sugar

---

## 8. Open Questions

### 8.1 Should `storage` be a generic `provide` mechanism?

The `storage` sugar on instances is specific to PVCs. Should it be generalized?

```nix
instances.myapp.myapp = {
  package = packages.myapp;
  provide.storage = "100Gi";          # auto-creates PVC
  provide.database = "postgres-16";   # auto-creates postgres??
};
```

Postgres is vastly more complex than a PVC. Auto-creating a postgres instance from a string is probably not the right model. Storage is special because a PVC is essentially `{ size, storageClass }` — two config values.

**Recommendation:** Keep `storage` as a specific feature, not a generic mechanism. If other "simple infrastructure deps" emerge (unlikely at this scale of simplicity), they can get their own sugar.

### 8.2 Where does the storage class come from?

Three options for the auto-created PVC's storage class:

A. **From the `storage` config:** `storage = { size = "100Gi"; storageClass = "fast-nvme"; };`
B. **From a cluster-level default:** `cluster.defaults.storageClass = "fast-nvme";`
C. **From DI (current):** The PVC package depends on `storageClasses`

Approach A is the most explicit. Approach B reduces repetition when all PVCs use the same class. Approach C works today.

**Recommendation:** A as the primary path (cluster operator specifies per-storage), with B as a cluster-level default that the auto-created instance inherits. C continues to work for manually created PVC instances.

### 8.3 Should the package know about the sugar?

With approach A, the package still declares `storage` as a required DI dep and gets a PVC instance's `out` (name, fqdn, size). The package doesn't know whether the PVC was created via sugar or manually.

This is clean — the package's interface doesn't change. The sugar is purely a cluster-level ergonomic improvement.

### 8.4 What if the package doesn't have a `storage` dep?

If the cluster operator writes `storage = "100Gi"` on an instance whose package doesn't declare a `storage` dep, the PVC instance is created but nothing consumes it. This should be a warning:

```
warning: instance 'myapp' has storage = "100Gi" but package does not declare a 'storage' dependency
```

Detectable during the phase-1 pre-pass: check if `storage` (or the configured dep name) is in `discoverBuildDeps`.
