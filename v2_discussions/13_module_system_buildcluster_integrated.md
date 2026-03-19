# Module System Approach B: evalModules Integrated Into buildCluster

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 12 (evalCluster wrapper approach)

---

## 1. Core Idea

Instead of wrapping `buildCluster`, integrate `lib.evalModules` directly into
it. `buildCluster` accepts a `modules` list as its primary interface, replacing
the current `namespaces`/`instances` parameters.

This is the "replace buildCluster" variant of doc 12.

---

## 2. API

```nix
kix.buildCluster {
  name = "nw1";
  clusterLabels = { ... };
  modules = [
    ./fragments/platform.nix
    ./fragments/team-shopfront.nix
    ({ ... }: { config.monitoring.enabled = true; })
  ];
}
```

Internally, `buildCluster` does:

```
1. lib.evalModules { modules = builtinModules ++ userModules; }
2. Extract evaluated config → namespaces, instances, clusterConfig
3. Existing phases: static metadata → resolutionIndex → nested fixpoint
   → closures → activation
```

---

## 3. Two Fixpoints, Separated by Phase

**Phase A — Module fixpoint** (`lib.evalModules` internal):
All modules are evaluated together. Module A can read `config.monitoring.enabled`
set by Module B, and vice versa. Nix laziness resolves the cross-references.
Output: a plain attrset of merged config.

**Phase B — Resource fixpoint** (`lib.fix` in buildCluster):
Takes the plain config from Phase A. Evaluates packages, resolves DI, builds
resources, computes closures. Unchanged from current implementation.

```
Module A: sets config.monitoring.enabled = true
Module B: reads config.monitoring.enabled → sets namespace labels
                    ↓
        lib.evalModules resolves
                    ↓
        evaluated.config (plain attrset)
                    ↓
        buildCluster Phase B:
          static metadata → resolutionIndex
          lib.fix (instances reference each other's resources)
          closures → activation
```

Key constraint: modules can read **what instances are declared** (static config),
but **cannot** read evaluated instance outputs (resources, `out.name`). Those
only exist in Phase B.

---

## 4. Fragments as Modules

`mergeFragments` is eliminated. Each fragment is a NixOS-style module:

```nix
# Before (fragment for mergeFragments):
{
  namespaces = { cache = { labels = { ... }; }; };
  instances = { ref, ... }: {
    cache = { valkey = { package = packages.valkey; config = { ... }; }; };
  };
}

# After (module for buildCluster):
{ config, lib, ... }: {
  config.namespaces.cache.labels = { ... };
  config.instances.cache.valkey = {
    package = packages.valkey;
    packageType = "valkey";
    config = { ... };           # configuration (behavior)
    deps = {};                  # DI overrides (wiring)
    partsOverlays = [];         # resource-level overlays
  };
}
```

The `{ ref, ... }:` function pattern disappears from instance declarations.
Cross-instance wiring stays in package function args via DNS-like DI.
Explicit DI overrides use `deps`, not config.

---

## 5. Cross-Cutting Concerns

Any module can declare options and any other module can set them:

```nix
# Platform fragment declares capability
{ lib, ... }: {
  options.monitoring.enabled = lib.mkEnableOption "cluster-wide monitoring";
  config.instances.monitoring.prometheus = { ... };
}

# App team fragment enables it
{ ... }: {
  config.monitoring.enabled = true;
  config.instances.myapp.api = { ... };
}

# Implementation module reacts
{ config, lib, ... }: {
  config = lib.mkIf config.monitoring.enabled {
    namespaces.monitoring.labels."monitoring" = "enabled";
  };
}
```

Packages read cross-cutting options via `scope.clusterConfig`:

```nix
{ scope, config, lib }: self: {
  serviceMonitor =
    if scope.clusterConfig.monitoring.enabled or false
    then scope.mkResource { kind = "ServiceMonitor"; ... }
    else null;
}
```

---

## 6. Three Separate Override Layers

Each instance has three distinct attributes, each with its own override
semantics. This mirrors nixpkgs conventions:

| Attribute | Controls | Analogous to | Override mechanism |
|-----------|---------|-------------|-------------------|
| `config` | Behavior (replicas, images, flags) | Function config args | Module priority (`mkDefault`, `mkForce`) |
| `deps` | Wiring (which postgres, which issuer) | nixpkgs `.override { }` | Attrset merge (last wins, explicit only) |
| `partsOverlays` | Resource structure (add/remove parts) | nixpkgs `.overrideAttrs` | List concatenation (composable) |

### config (module priority)

```nix
# Package default via _kixOptions
replicaCount = lib.mkOption { type = lib.types.int; default = 3; };

# Fragment sets it (normal priority wins over mkDefault)
config.instances.cache.valkey.config.replicaCount = 5;

# Platform forces it (mkForce wins over everything)
config.instances.cache.valkey.config.replicaCount = lib.mkForce 1;
```

### deps (explicit DI overrides)

```nix
# Normally, DI auto-resolves postgres to the same-namespace instance.
# Override to use a specific one:
config.instances.cache.myapp.deps.postgres = ref.other-ns.special-pg;

# Override which ingress controller is wired:
config.instances.cache.myapp.deps.ingress-nginx = ref.nginx-system.ingress-private-v2;
```

`deps` is `types.attrsOf types.anything` — values are instance references from
the fixpoint. DI overrides are not subject to module priority; they're plain
attrset merges. If two modules set the same dep → merge error (collision).

### partsOverlays (composable resource overlays)

```nix
# Platform adds a sidecar
config.instances.cache.myapp.partsOverlays = [
  (self: base: { deployment = base.deployment // { /* add sidecar */ }; })
];

# Team disables HPA
config.instances.cache.myapp.partsOverlays = [
  (self: base: { hpa = null; })
];
```

Multiple modules contribute overlays; they're concatenated and folded in order.
Like `nixpkgs.overlays`.

---

## 7. Changes to buildCluster Implementation

1. New `modules` parameter, replaces `namespaces`/`instances` direct params
2. Run `lib.evalModules` at the top, extract `namespaces`, `instances`
3. Thread `clusterConfig` through `mkScope` → `scope.clusterConfig`
4. Remove `scope.defaults` — module system handles config merging
5. Everything else (fixpoints, resolution, closures, activation) unchanged

---

## 8. Key Tradeoff vs Doc 12

Doc 12 keeps `buildCluster` unchanged and adds `evalCluster` on top —
backward compatible, gradual migration. This approach replaces `buildCluster`'s
interface — cleaner, but a breaking change. All cluster definitions must be
rewritten to use modules.

The internal implementation is identical in both cases. The difference is
whether the module layer is opt-in (doc 12) or mandatory (this doc).
