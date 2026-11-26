# Module System Approach C: Package Options via deferredModule

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 12, doc 13 (module system base), outdated/lib/options.nix

---

## 1. The Problem

Docs 12 and 13 describe the module system for cluster/fragment-level
cross-cutting concerns. But what about package-level config?

Today, packages use `scope.defaults config defs` — a deep `recursiveUpdate`
with no type checking, no documentation, and only a `builtins.trace` warning
for unknown keys. If a package like valkey has options (sentinel mode, replica
count, image tags), there's no formal declaration of what those options are.

Additionally, if a cross-cutting module wants to read a specific package's
typed config (e.g., "is sentinel enabled on the valkey in the cache
namespace?"), it can't — instance config is opaque `attrsOf anything`.

This doc explores making package config typed and visible in the cluster-level
module tree.

---

## 2. The Challenge: Chicken-and-Egg

To type `instances.cache.valkey.config` according to valkey's options, the
module system needs to know the instance uses valkey. But `package` is set in
the same module evaluation as `config`. Reading `config.package` to determine
the type of `config.config` creates a circular dependency in the module system.

NixOS faces the same problem with dynamic submodules (e.g., filesystems with
different options per fsType, containers with varying configs).

---

## 3. Solution: types.deferredModule + Per-Instance evalModules

NixOS's `types.deferredModule` stores module definitions without evaluating
them. Multiple modules contributing to the same deferred option get collected
into a list. Evaluation happens separately.

### Instance Submodule

```nix
instanceSubmodule = types.submodule ({ config, ... }: {
  options = {
    package = mkOption { type = types.anything; };
    packageType = mkOption { type = types.str; };
    aliases = mkOption { type = types.listOf types.str; default = []; };
    version = mkOption { type = types.nullOr types.str; default = null; };

    # Layer 1: Configuration (behavior) — deferred, evaluated per-instance
    config = mkOption {
      type = types.deferredModule;
      default = {};
    };

    # Layer 2: DI overrides (wiring) — like nixpkgs .override { }
    deps = mkOption {
      type = types.attrsOf types.anything;
      default = {};
    };

    # Layer 3: Parts overlays (resource structure) — like nixpkgs .overrideAttrs
    partsOverlays = mkOption {
      type = types.listOf (types.functionTo (types.functionTo types.anything));
      default = [];
    };

    # Evaluated config — runs evalModules with package options + deferred config
    evaluatedConfig = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      readOnly = true;
    };
  };

  # Evaluate deferred config against the package's options
  config.evaluatedConfig = (lib.evalModules {
    modules =
      # Package's option declarations (if it has them)
      lib.optional (config.package ? _kixOptions) config.package._kixOptions
      # The collected deferred config from all fragments
      ++ (if builtins.isList config.config
          then config.config
          else [ config.config ]);
  }).config;
});
```

### How deferredModule Merges

When multiple modules set config for the same instance, `types.deferredModule`
collects them into a list:

```nix
# Fragment A:
instances.cache.valkey.config = { sentinel.enabled = true; };

# Fragment B:
instances.cache.valkey.config = { replicaCount = 5; };

# Module system merges (deferredModule collects):
instances.cache.valkey.config = [
  { sentinel.enabled = true; }    # from fragment A
  { replicaCount = 5; }            # from fragment B
]
```

When `evaluatedConfig` is accessed, these get evaluated together:

```nix
lib.evalModules {
  modules = [
    packages.valkey._kixOptions    # declares options with types + defaults
    { sentinel.enabled = true; }   # from fragment A
    { replicaCount = 5; }          # from fragment B
  ];
}
```

Result: `{ sentinel.enabled = true; replicaCount = 5; image = { tag = "8.1.1"; ... }; ... }`

No chicken-and-egg problem because:
- `config` (deferred module) doesn't need types — it's just stored
- `evaluatedConfig` reads `config.package._kixOptions` and `config.config`
  — both set by modules, no circularity
- `types.deferredModule` is always the same type regardless of package

---

## 4. What the Package Provides

```nix
# packages/valkey/_kixOptions.nix (or inline as package attribute)
{ lib, ... }: {
  options = {
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Number of valkey replicas.";
    };
    sentinel = {
      enabled = lib.mkEnableOption "sentinel mode";
      quorum = lib.mkOption { type = lib.types.int; default = 2; };
      primarySet = lib.mkOption { type = lib.types.str; default = "mymaster"; };
    };
    image = lib.mkOption {
      type = lib.types.submodule {
        options = {
          repository = lib.mkOption { type = lib.types.str; default = "docker.io/bitnami/valkey"; };
          tag = lib.mkOption { type = lib.types.str; default = "8.1.1-debian-12-r0"; };
        };
      };
      default = {};
    };
    auth.enabled = lib.mkOption { type = lib.types.bool; default = true; };
  };
}
```

Packages without `_kixOptions` work unchanged — `evaluatedConfig` passes
through the raw config with no validation (no options module means no type
checking, just like today).

Detection in flake.nix:

```nix
packages' = lib.mapAttrs (name: _:
  let
    pkg = import ./packages/${name};
    optionsPath = ./packages/${name}/_kixOptions.nix;
  in
  if builtins.pathExists optionsPath
  then pkg // { _kixOptions = import optionsPath; }
  else pkg
) dirs;
```

---

## 5. Multiple Instantiations

Each instance gets its own `evaluatedConfig` — independent `evalModules` calls
with the same package options but different config values:

```nix
instances.cache = {
  valkey-main = {
    package = packages.valkey;
    config = { replicaCount = 5; sentinel.enabled = true; };
  };
  valkey-session = {
    package = packages.valkey;
    config = { replicaCount = 2; sentinel.enabled = false; };
  };
};

# valkey-main.evaluatedConfig.replicaCount == 5
# valkey-session.evaluatedConfig.replicaCount == 2
```

---

## 6. Cross-Cutting Modules Can Read Typed Config

```nix
# modules/sentinel-network-policy.nix
{ config, lib, ... }:
let
  # Find all instances with sentinel enabled
  sentinelInstances = lib.concatMapAttrs (ns: insts:
    lib.filterAttrs (_: inst:
      (inst.evaluatedConfig.sentinel.enabled or false)
    ) insts
  ) config.instances;
in {
  config = lib.mkIf (sentinelInstances != {}) {
    namespaces = lib.mapAttrs (ns: _: {
      networkPolicies.allow-sentinel = {
        ingress = [{ ports = [{ port = 26379; protocol = "TCP"; }]; }];
      };
    }) (lib.groupBy (inst: inst.evaluatedConfig._namespace or "default")
      (builtins.attrValues sentinelInstances));
  };
}
```

---

## 7. How evaluatedConfig Flows to the Package Function

`evaluateInstance` passes `evaluatedConfig` instead of raw config:

```nix
# In kixCallPackage:
packageFn ({
  scope = scope;
  config = instanceConfig.evaluatedConfig;  # typed, validated, defaults applied
  lib = lib;
} // resolvedDeps)
```

This replaces `scope.defaults` entirely. The module system merges defaults
from the package's options with user config. `scope.defaults` is removed.

---

## 8. Three Levels of evalModules

```
Level 1 — Cluster modules (lib.evalModules)
  Merges fragments, cross-cutting options, namespace policies
  Output: evaluated cluster config with instances as declarations

Level 2 — Per-instance config (lib.evalModules inside evaluatedConfig)
  Validates instance config against package options
  Output: typed, defaulted config per instance

Level 3 — buildCluster fixpoint (lib.fix)
  Evaluates packages, builds resources, resolves DI
  Output: K8s manifests, closures, activation CRD
```

---

## 9. Key Tradeoffs

**Pro:**
- Package options are typed, documented, and validated
- Cross-cutting modules can read typed instance config
- Module priority system (`mkDefault`, `mkForce`) replaces `recursiveUpdate`
- Multiple modules can contribute config to the same instance cleanly
- Gradual adoption — packages without `_kixOptions` work unchanged

**Con:**
- Three levels of evalModules adds conceptual complexity
- `evaluatedConfig` vs `config` distinction may confuse users
- Per-instance `evalModules` has performance cost (likely negligible for
  typical cluster sizes, but worth measuring)
- Package authors must maintain a separate options declaration alongside
  the package function

**Alternative considered:** Making the instance's `config` option dynamically
typed based on `config.package`. This doesn't work cleanly because option types
must be determined at declaration time, but `config.package` is a config value
determined at evaluation time. `types.deferredModule` avoids this by decoupling
storage (always `deferredModule`) from evaluation (per-instance `evalModules`).

---

## 10. Relationship to Outdated v1 Module System

The outdated v1 (in `outdated/modules/`) used `lib.evalModules` with:
- Level 1: cluster-wide defaults (cluster.nix)
- Level 2: service endpoint registry (registry.nix)
- Level 3: capabilities + implementations (monitoring, network policy)

The key differences from v1:
- v1 replaced the fixpoint entirely with evalModules; this approach layers
  evalModules on top of the existing fixpoint
- v1 had packages produce `config.manifests.*` directly; this approach keeps
  packages as functions returning parts (the inner fixpoint)
- v1 had no per-instance evalModules; this approach adds typed per-instance
  config as an optional layer
- v1's capability system (abstract intent → implementation) maps naturally to
  this approach's cross-cutting modules (declare option → implementation module
  reads it and acts)
