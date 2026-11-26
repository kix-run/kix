# 27 — Auto-Instantiation and Optional Instances

## Status: RFC

## Predecessors

- Doc 02 (DI resolution, aliasing, fixpoint)
- Doc 25 (package meta, defaultAliases)
- Doc 11 (infrastructure DI)
- ROADMAP: "Auto-instantiation from default package set"

---

## 1. The Problem

The DI system (doc 02) resolves dependencies by looking up instances declared
in the cluster definition. If package `immich` requires `valkey`, a `valkey`
instance must exist in `cfg.instances`. This means the cluster operator must
manually declare every transitive dependency:

```nix
# Today: operator must know and declare everything
instances.immich = {
  immich = { package = packages.immich; };
  valkey = { package = packages.valkey; };          # manual
  postgres = { package = packages.stackgres-cluster; };  # manual
  storage = { package = packages.persistent-volume-claim; };  # manual
};
```

This is tedious, error-prone, and defeats the "just make it run" experience.
The operator shouldn't need to know that immich needs valkey — the package
already declares that as a function argument.

**The idea**: a cluster-level package registry (`availablePackages`) so that
when DI resolution fails for a required dep, the system auto-instantiates from
the registry. Combined with optional instances that let operators pre-configure
standby packages, the cluster can self-assemble while remaining fully auditable.

---

## 2. Two Complementary Mechanisms

### 2a. `availablePackages` — the "just make it work" path

A cluster-level registry of packages that the DI resolver can draw from. Only
packages that are actually needed (transitively) get instantiated. Default
config only.

```nix
# Simplest form: all packages are available
availablePackages = packages;

# Or with overrides for specific packages
availablePackages = packages // {
  valkey = { package = packages.valkey; namespace = "data"; };
};
```

The nice DX comes from accepting both raw package functions and config
attrsets. A raw function `packages.valkey` is normalized to
`{ package = packages.valkey; namespace = null; aliases = []; }`.

### 2b. `optional` instances — the "I've prepared this, use it if needed" path

A flag on explicitly declared instances that makes them dormant — included in
DI resolution but only deployed if a non-optional instance transitively
depends on them.

```nix
instances.data.valkey = {
  package = packages.valkey;
  optional = true;
  config = {
    replicaCount = 3;
    resources.requests.memory = "1Gi";
  };
};
```

The cluster operator has full control over config, namespace placement, and
aliases. Optional instances take priority over `availablePackages` when both
could satisfy a dependency — the operator's preparation wins.

### Why both?

| Concern | `availablePackages` | `optional` instances |
|---------|--------------------|--------------------|
| Config control | Defaults only | Full operator config |
| Namespace | Per-package or cluster default | Explicit in declaration |
| Use case | "I don't care, make it work" | "I've prepared this correctly" |
| Auditability | Auto-created, marked in annotations | Normal instance, just dormant |

---

## 3. Resolution Priority

When a required dep cannot be resolved from mandatory instances, the system
checks (in order):

1. **Optional instances** matching the dep name or alias → activate
2. **`availablePackages`** matching the dep name or alias → auto-instantiate
3. **Neither** → error (same as today)

This means a cluster operator can always "pre-empt" auto-instantiation by
declaring an optional instance with the right config.

---

## 4. Namespace Placement for Auto-Instances

Two-level policy, checked in order:

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | Per-package `namespace` | `availablePackages.valkey = { package = ...; namespace = "data"; }` |
| 2 | Cluster `autoNamespace` | `autoNamespace = "auto";` |
| 3 (default) | Requester's namespace | immich in "immich" ns → valkey goes to "immich" |

When `namespace = null` (default) and multiple requesters in different
namespaces need the same dep, each namespace gets its own auto-instance. This
is the safe default — it respects namespace isolation. For shared infrastructure,
the operator sets `namespace` explicitly.

```nix
# Everything auto goes to "auto" namespace
autoNamespace = "auto";

# Override: valkey always in "data"
availablePackages.valkey = {
  package = packages.valkey;
  namespace = "data";
};
```

---

## 5. The Algorithm: Static Reachability Pre-Computation

The key insight: we can determine the full set of needed instances **before**
the evaluation fixpoint, using only `builtins.functionArgs` (which is free —
no evaluation of the package body).

### Why pre-computation?

The resolution index (`buildResolutionIndex`) is built once before the fixpoint.
Auto-instances must be in the index so normal DI resolution finds them.
Computing them inline during resolution would require rebuilding the index
mid-fixpoint. Pre-computation avoids this — the index includes all instances
(explicit + auto) from the start.

### Algorithm

```
computeAutoInstances { explicitInstances, availablePackages, autoNamespace }:

  0. Normalize availablePackages (wrap raw functions as { package, ... })
     Partition explicit instances into mandatory vs optional

  1. Build lookup indexes:
     - availableByKey: depName → canonical availablePackages key
       (includes entry key + aliases + meta.defaultAliases via peekPackageMeta)
     - optionalByKey: depName → { ns, instName }
       (includes instance name + effective aliases of optional instances)
     - mandatoryKeys: set of all resolution keys from mandatory instances

  2. Seed: for each mandatory instance, extract required deps
     fnArgs = builtins.functionArgs(package)
     requiredDeps = { name | fnArgs[name] == false } minus {scope, lib, kix}

  3. builtins.genericClosure traversal:
     startSet = all (requesterNs, depName) from mandatory instances
                where depName not in mandatoryKeys

     operator(item):
       depName = item.depName

       A) Optional instance matches?
          → Mark as activated
          → Add its keys to mandatoryKeys
          → Emit ITS required deps as new items

       B) availablePackages matches?
          → Record auto-instance with computed namespace
          → Add its keys to mandatoryKeys
          → Emit ITS required deps as new items

       C) Neither → [] (will error in resolveArg as before)

  4. Return:
     - autoInstances: { ns.instName = instanceConfig }
     - activatedOptionals: { "ns/instName" = true }
```

`builtins.genericClosure` deduplicates by key (`"${ns}/${instName}"`), so
circular dependencies (A requires B, B requires A) and diamond dependencies
(A and B both require C) are handled correctly.

### Integration into `buildCluster`

```
1. evalModules → cfg                              (unchanged)
2. NEW: computeAutoInstances(cfg)
3. NEW: mergedInstances = auto ∪ cfg.instances     (explicit wins)
4. staticMeta from mergedInstances                 (was cfg.instances)
5. resolutionIndex from staticMeta                 (unchanged)
6. clusterInstances fixpoint over mergedInstances   (was cfg.instances)
7. Resource collection — filter out inactive optionals
```

Step 7 is the only change to resource collection: optional instances that were
not activated by step 2 are excluded from the final resource set. They still
exist in `clusterInstances` (so `ref.ns.name` works for ad-hoc access) but
produce no manifests.

---

## 6. Auditability

Auto-instantiated packages get:
- Annotation `kix.lithus.eu/auto-instantiated: "true"` on their PackageInstance CR
- `_meta._autoInstantiated = true` in the instance view (for tooling)
- `builtins.trace` during evaluation: `"auto-instantiated: valkey (data), postgres (immich)"`

Activated optional instances get:
- Annotation `kix.lithus.eu/optional-activated: "true"`
- Normal resource output (they're fully configured instances, just dormant by default)

Inactive optional instances produce no output — completely invisible in the
deployed cluster.

---

## 7. Cluster Option Definitions

### `availablePackages` (attrsOf raw)

```nix
availablePackages = lib.mkOption {
  type = lib.types.attrsOf lib.types.raw;
  default = {};
  description = ''
    Package registry for auto-instantiation. Accepts either raw package
    functions or attrsets { package, namespace?, aliases? }.
  '';
};
```

Accepts:
- `availablePackages = packages;` (raw functions, nice DX)
- `availablePackages.valkey = { package = packages.valkey; namespace = "data"; };`

### `autoNamespace` (nullOr str)

```nix
autoNamespace = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;
  description = ''
    Default namespace for auto-instantiated packages.
    null = co-locate with requester. A string = all auto-instances go here.
    Per-package namespace overrides this.
  '';
};
```

### `optional` (bool, on instance submodule)

```nix
optional = lib.mkOption {
  type = lib.types.bool;
  default = false;
  description = ''
    Dormant instance — included in DI resolution but only deployed
    if a non-optional instance transitively depends on it.
  '';
};
```

---

## 8. Examples

### Zero-config cluster

```nix
# The dream: this is the entire cluster definition
kix.buildCluster {
  name = "my-cluster";
  modules = [{
    availablePackages = packages;
    instances.default.immich = {
      package = packages.immich;
      config.host = "photos.example.com";
    };
    # valkey, postgres, storage — all auto-instantiated in "default" ns
  }];
}
```

### Operator-controlled infrastructure

```nix
kix.buildCluster {
  name = "production";
  modules = [{
    availablePackages = packages;
    autoNamespace = "auto";

    # Pre-configured shared infra (dormant until needed)
    instances.data = {
      postgres = {
        package = packages.stackgres-cluster;
        optional = true;
        config = {
          replicaCount = 3;
          extensions = [ "pgvecto.rs" "postgis" ];
          resources.requests = { cpu = "2"; memory = "4Gi"; };
        };
      };
      valkey = {
        package = packages.valkey;
        optional = true;
        config = {
          replicaCount = 3;
          resources.requests.memory = "1Gi";
        };
      };
    };

    # Application — triggers activation of postgres + valkey
    instances.app.immich = {
      package = packages.immich;
      config.host = "photos.example.com";
    };
    # postgres + valkey activated from "data" ns (operator config used)
    # storage auto-instantiated from availablePackages into "app" ns
  }];
}
```

### Per-namespace isolation (PR environments)

```nix
# Every namespace gets its own copy of everything
autoNamespace = null;  # default — co-locate

instances."pr-123".myapp = { package = packages.myapp; };
# myapp's deps auto-instantiated into "pr-123" — fully isolated
```

---

## 9. Edge Cases

| Case | Behavior |
|------|----------|
| `availablePackages = packages;` | All available; only needed ones instantiated |
| Explicit mandatory instance matches dep | Normal resolution, no auto-instantiation |
| Optional instance matches dep | Activated, takes priority over availablePackages |
| Optional instance never needed | In fixpoint (for ref access) but no resources |
| Optional depends on another optional | Both activated transitively |
| Auto-instance + explicit in same ns/name | Explicit wins (recursiveUpdate) |
| Circular auto-deps (A↔B) | genericClosure deduplicates; Nix laziness handles circular refs |
| Available pkg has unresolvable dep | Auto-instantiated; error surfaces in resolveArg later |
| Import packages in availablePackages | Type-guarded; skip functionArgs introspection |
| peekPackageMeta fails (pkg has required deps) | Relies on explicit aliases in the entry |

---

## 10. Non-Goals (This RFC)

- **Per-namespace auto-instantiation policy** — deferred. The two-level policy
  (per-package + cluster default) covers the common cases. Per-namespace
  overrides (`namespaces.staging.autoNamespace = "staging-auto"`) can be
  added later without breaking changes.

- **Auto-instantiation of optional deps** — only required deps (function args
  without `? null`) trigger auto-instantiation. Optional deps remain null if
  not found. This is intentional: optional features are opt-in.

- **Config inference for auto-instances** — auto-instances get default config.
  If you need custom config, use an optional instance or convert to explicit.
  Future work could allow `availablePackages` entries to carry default config.

- **Capability-based resolution** — resolving deps by `meta.provides` tags
  rather than name/alias. The `provides` field exists (doc 25) but isn't used
  for resolution yet. This RFC uses name + alias matching only.
