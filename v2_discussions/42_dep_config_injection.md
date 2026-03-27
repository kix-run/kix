# Plan: Dep config injection — consumers push config into their dependencies

## Problem

Immich requires the `vectors` extension on its postgres instance. Today this is expressed as an assertion — immich checks after the fact and fails if the extension is missing. The cluster author must manually configure both sides:

```nix
# cluster definition — author must know immich's requirements
instances.postgres.config.extensions = [{ name = "vectors"; ... }];
instances.immich.package = packages.immich;
```

This is fragile: requirements live in the package's head but are declared in the cluster definition. If immich adds a new postgres requirement, every cluster that uses immich must be manually updated.

## Goal

Packages declare what config their deps should have. The eval system merges it automatically:

```nix
# immich/default.nix
{ scope, lib, kix }:
{
  deps = {
    postgres.config = {
      extensions = [{ name = "vectors"; publisher = "tensorchord"; version = "0.3.0"; }];
    };
  };
  build = { self, config, postgres, storage, ... }: { ... };
}
```

When immich resolves to a specific postgres instance, that config gets merged into the postgres instance's `evaluateInstanceConfig` call — alongside the cluster-level config and global defaults. The module system handles merge semantics (lists append, scalars conflict-error).

## Current eval flow (relevant parts)

```
cluster.nix:
  1. evalModules (cluster module system)          → cfg
  2. computeAutoInstances                         → mergedInstances
  3. peekPackageMeta for all instances             → staticMeta
  4. buildResolutionIndex(staticMeta)              → resolutionIndex
  5. lib.fix (fixpoint over all instances)
       └─ evaluateInstance for each instance:
            a. callPackagePhase1(pkg, scope)       → raw { meta, options, deps?, build }
            b. discoverBuildDeps(raw.build)         → discoveredDeps
            c. resolveDeclaredDeps(...)             → resolvedDeps
            d. evaluateInstanceConfig(options, instCfg, clusterConfig)  → evaluatedConfig
            e. callBuildFn(build, resolvedDeps, evaluatedConfig)        → parts
```

Step 5d (`evaluateInstanceConfig`) currently gets modules from:
- Package option declarations
- `clusterConfig.global` (cluster-wide defaults)
- `instCfg.config` (instance-specific config from cluster definition)

Dep config injection adds a 4th source: config modules contributed by instances that depend on this one.

## Design space

### Approach A: Pre-pass outside the fixpoint

Hoist steps 5a-5c out of the fixpoint into a pre-pass that runs for all instances before `lib.fix`. This produces a global `configInjections` map that the fixpoint consumes.

**Pre-pass (new, between steps 4 and 5):**
```
for each instance:
  raw = callPackagePhase1(pkg, scope)
  discoveredDeps = discoverBuildDeps(raw.build)
  depConfigs = raw.deps.*.config (where present)
  resolvedTargets = resolve each dep to (namespace, instanceName)

configInjections = invert the map:
  { targetNs.targetInst = [ { config from consumer A }, { config from consumer B } ]; }
```

**Inside the fixpoint**, `evaluateInstanceConfig` receives the pre-computed injections for this instance.

**Pros:**
- Clean separation — injection map is computed once, not per-instance
- No risk of accidental circularity inside the fixpoint
- Easy to inspect/debug the injection map

**Cons:**
- Duplicates scope construction (pre-pass needs `mkScope` for each instance to call phase1)
- Pre-pass resolution is separate from the fixpoint's resolution — must stay in sync
- `callPackagePhase1` needs `scope`, which needs `instanceName`, `namespaceName`, `namespaceResource`, `clusterLabels`, etc. Some of this is easy (names), but `namespaceResource` is currently built inside the fixpoint. Would need to hoist namespace resource creation too, or pass a minimal scope.

**Scope concern:** `callPackagePhase1` passes `scope` to the package function. Currently packages use `scope.instanceName`, `scope.namespaceName`, `scope.selectorLabels`, `scope.mkResource`, etc. in their phase-1 return value (e.g. `let name = scope.instanceName;`). The pre-pass scope doesn't need to be fully functional — packages only use `scope` for naming in phase 1, not for building resources. But `scope.mkResource` is available and some packages might call it in their `deps` or `meta` declarations. This needs investigation.

Actually — looking at all 12 packages, none of them use `scope` in `deps` or `meta` (just `scope.instanceName` in an outer `let`). So a lightweight pre-pass scope with just `instanceName`/`namespaceName` would work for phase 1.

### Approach B: Lazy collection inside the fixpoint

Each instance, when evaluating its config, lazily scans all other instances to collect injections targeting itself.

**Inside evaluateInstance:**
```nix
# Collect config injections from all instances that resolved to us
myInjections = lib.concatMap (ns:
  lib.concatMap (instName:
    let
      otherRaw = callPackagePhase1 { packageFn = mergedInstances.${ns}.${instName}.package; scope = minimalScope ns instName; };
      otherDeps = discoverBuildDeps otherRaw.build;
      otherEnrichment = otherRaw.deps or {};
    in
    lib.concatMap (depName:
      let resolution = resolveArg { ... };
      in
      if resolution.found && resolution.namespace == namespaceName && resolution.instanceName == instanceName
         && otherEnrichment ? ${depName} && otherEnrichment.${depName} ? config
      then [ otherEnrichment.${depName}.config ]
      else []
    ) (builtins.attrNames otherDeps)
  ) (builtins.attrNames mergedInstances.${ns})
) (builtins.attrNames mergedInstances);
```

**Pros:**
- No restructuring of cluster.nix — everything stays inside `evaluateInstance`
- No pre-pass, no sync issues

**Cons:**
- O(N^2) — every instance scans every other instance. For 50 instances, 2500 phase-1 calls (though Nix memoizes pure function calls, so the actual package call is cached)
- Complex lazy evaluation chains — harder to reason about and debug
- `callPackagePhase1` is called multiple times for the same package (once per scanner) — Nix's call-by-need means the thunk is shared if the args are the same, but `scope` differs per instance so they're NOT shared
- Harder to inspect — no single place to see "what config does postgres receive from its dependents"

### Approach C: Two-level fixpoint

Split the fixpoint into two phases:

1. **Phase-1 fixpoint:** evaluate all instances to phase-1 level only (raw, discoveredDeps, resolved dep targets). No config evaluation, no build.
2. **Injection map:** computed from phase-1 results.
3. **Phase-2 fixpoint:** full evaluation with injected configs.

```nix
# Phase 1: resolve deps (no config eval)
phase1Instances = lib.mapAttrs (ns: lib.mapAttrs (inst: instCfg:
  let
    raw = callPackagePhase1 { ... };
    discoveredDeps = discoverBuildDeps raw.build;
    depsEnrichment = raw.deps or {};
    # Resolve to (namespace, instanceName) pairs — no allInstances lookup needed
    resolvedTargets = resolveDepTargets { ... resolutionIndex ... };
  in
  { inherit raw discoveredDeps depsEnrichment resolvedTargets; }
)) mergedInstances;

# Build injection map
configInjections = buildConfigInjections phase1Instances;

# Phase 2: full fixpoint with injections
clusterInstances = lib.fix (self: lib.mapAttrs (ns: lib.mapAttrs (inst: instCfg:
  evaluateInstance {
    ...
    configInjections = configInjections.${ns}.${inst} or [];
    phase1 = phase1Instances.${ns}.${inst};
    allInstances = self;
  }
)) mergedInstances);
```

**Pros:**
- Clean separation of concerns
- Phase-1 results are computed once and reused
- Injection map is explicit and inspectable
- No O(N^2) scanning
- Phase 1 doesn't need the fixpoint (`allInstances`) — it only resolves dep *targets* (namespace + name), not actual instances

**Cons:**
- Biggest restructuring — splits evaluateInstance into two halves
- Need a new `resolveDepTargets` that returns `(ns, instName)` pairs without looking up actual instances
- `evaluateInstance` receives pre-computed phase1 data instead of computing it

### Approach D: Config injection as cluster-level module sugar

Instead of changing the eval loop, provide a utility that generates the right cluster-level config:

```nix
# In the cluster definition
{ kix, packages }:
kix.buildCluster {
  modules = [
    {
      instances.immich.package = packages.immich;
      instances.postgres.package = packages.stackgres-cluster;
    }
    # This function reads immich's deps.postgres.config and generates:
    # instances.postgres.config = { extensions = [...]; };
    (kix.applyDepConfigs { })
  ];
}
```

**Pros:**
- Zero eval loop changes
- Explicit — cluster author opts in
- Easy to implement

**Cons:**
- Not automatic — defeats the purpose
- Breaks when dep resolution is ambiguous (which postgres does immich get?)
- Can't work without running resolution first, which happens inside the eval loop

**Verdict:** Not viable — the whole point is that this should be automatic.

## Recommendation: Approach C (two-level fixpoint)

Approach C is the cleanest architecture. It separates "what depends on what" (phase 1, no fixpoint needed) from "evaluate everything" (phase 2, fixpoint). The injection map is an explicit, inspectable data structure.

The key insight is that **dep resolution doesn't need the fixpoint**. `resolveArg` only needs the `resolutionIndex` (built from static meta) to determine *which* instance a dep resolves to. It doesn't need the actual evaluated instance — that's only needed when the build function accesses `postgres.out.fqdn`. So phase 1 can resolve dep *targets* without entering the fixpoint.

### What `resolveDepTargets` returns

Currently `resolveDeclaredDeps` returns actual instances (looks up `allInstances.${ns}.${inst}`). We need a variant that returns just the coordinates:

```nix
resolveDepTargets = { declaredDeps, resolutionIndex, namespace, explicitOverrides }:
  lib.mapAttrs (argName: depSpec:
    let
      isOptional = depSpec.optional or false;
      explicitOverride = explicitOverrides.${argName} or null;
      resolution = resolveArg {
        inherit argName resolutionIndex explicitOverride;
        requesterNamespace = namespace;
        hasDefault = isOptional;
      };
    in
    if resolution.found then
      if resolution.direct or false then { found = true; direct = true; }
      else { found = true; namespace = resolution.namespace; instanceName = resolution.instanceName; }
    else
      { found = false; }
  ) declaredDeps;
```

### What `buildConfigInjections` does

```nix
buildConfigInjections = phase1Map:
  # For each instance's resolved deps, if it has deps.X.config,
  # add that config to the target instance's injection list.
  let
    entries = lib.concatMap (ns:
      lib.concatMap (inst:
        let p1 = phase1Map.${ns}.${inst};
        in lib.concatMap (depName:
          let
            target = p1.resolvedTargets.${depName};
            hasConfig = (p1.depsEnrichment.${depName} or {}) ? config;
          in
          if target.found && !(target.direct or false) && hasConfig
          then [{ targetNs = target.namespace; targetInst = target.instanceName;
                  config = p1.depsEnrichment.${depName}.config;
                  source = "${ns}/${inst}"; }]
          else []
        ) (builtins.attrNames p1.discoveredDeps)
      ) (builtins.attrNames phase1Map.${ns})
    ) (builtins.attrNames phase1Map);
  in
  # Group by target
  builtins.foldl' (acc: e:
    let existing = acc.${e.targetNs}.${e.targetInst} or [];
    in lib.recursiveUpdate acc {
      ${e.targetNs}.${e.targetInst} = existing ++ [e.config];
    }
  ) {} entries;
```

### How `evaluateInstanceConfig` changes

```nix
evaluateInstanceConfig = {
  packageOptions,
  instCfg,
  clusterConfig ? {},
  configInjections ? [],  # NEW — config modules from dependents
}:
  let
    ...
    evaluated = removeAttrs (lib.evalModules {
      modules = [
        { options = packageOptions; }
        { config = clusterConfig.global or {}; }
      ]
      ++ (map (c: { config = c; }) configInjections)  # NEW
      ++ wrappedModules;  # cluster-level config wins (comes last)
    }).config [ "_module" ];
    ...
```

Note: `wrappedModules` (cluster-level instance config) comes LAST, so explicit cluster config overrides dep-injected defaults. This is the right priority — the cluster author has final say.

## Priority order (lowest to highest)

1. Package option defaults (`default = ...` in `lib.mkOption`)
2. **Dep config injections** (from consumers of this instance) — NEW
3. Global config (`clusterConfig.global`)
4. Instance config (from cluster definition)

This means dep injections act as "soft defaults" — stronger than package defaults but overridable by the cluster author.

## Merge semantics

The module system handles merging automatically based on option types:

| Type | Merge behavior | Example |
|------|---------------|---------|
| `listOf` | Concatenate | `extensions`: immich adds `vectors`, another adds `postgis` → both present |
| `attrsOf` | Deep merge | `postgresqlConf`: immich sets `shared_preload_libraries`, another sets `max_connections` → both applied |
| `str` | Error on conflict | `version`: two consumers can't set different versions |
| `bool` | Error on conflict | `ssl.enabled`: conflict if one wants true and another false |
| `anything` | Last wins (no merge) | Problematic — should avoid for injectable fields |

**Concern:** Many package options use `lib.types.anything`, which doesn't merge — it replaces. For config injection to work well with lists (like `extensions`), those options should use proper types (`listOf`, `attrsOf`). This is a gradual improvement — packages can migrate options to richer types as config injection is adopted.

## What stays as assertions/warnings

Config injection handles "set this config on my dep." Some constraints can't be expressed as config:

- **Version bounds** — `compatibleWith.postgres.minVersion = "15"` (can't change a dep's version)
- **Size warnings** — "storage < 50Gi is not recommended" (informational, not a config override)
- **Existence checks** — "extension X must be present" could be either an injection (add it) or an assertion (verify a third party added it)

`deps.*.config`, `deps.*.assertions`, and `deps.*.warnings` coexist.

## Scope of changes

### Must change

| File | Change |
|------|--------|
| `lib/eval/cluster.nix` | Add phase-1 pre-pass, build injection map, pass to fixpoint |
| `lib/eval/resolve.nix` | Add `resolveDepTargets` (resolution without instance lookup) |
| `lib/eval/instance.nix` | Accept `phase1` + `configInjections`, skip redundant phase-1 work, pass injections to `evaluateInstanceConfig` |
| `lib/eval/resolve.nix` | `evaluateInstanceConfig` accepts and applies `configInjections` |

### May change

| File | Change |
|------|--------|
| `lib/eval/auto.nix` | Could reuse phase-1 results instead of calling `getRequiredDeps` separately (optimization, not required) |
| `packages/stackgres-cluster/default.nix` | Migrate `extensions` option from `anything` to `listOf anything` for proper merge semantics |
| `packages/immich/default.nix` | Add `deps.postgres.config` (the motivating example) |

### Won't change

| File | Reason |
|------|--------|
| `lib/meta.nix` | Assertions/warnings pipeline unchanged |
| Other packages | Only packages that want to inject config need `deps.*.config` |
| Cluster definitions | Existing configs keep working — injections are additive |

## Open questions

1. **Should injections be traceable?** When postgres gets `extensions = [vectors]` injected by immich, should there be a trace/warning so the cluster author knows? Pro: transparency. Con: noise.

2. **Conflict resolution for `anything` types:** If a package option uses `lib.types.anything` and two consumers inject different configs, last-writer-wins silently. Should we warn? Or require packages to use proper types for injectable fields?

3. **Direct dep overrides:** If `instCfg.deps.postgres` is an explicit override (pointing to a specific instance), should config injection still apply? Probably yes — the consumer still needs those settings regardless of which instance it resolves to.

4. **Transitive injection:** If A injects config into B, and B has a dep on C, should A be able to inject into C? Probably not — keep it one level deep to avoid complexity.

5. **Phase-1 scope:** The pre-pass needs to call `callPackagePhase1`, which needs a `scope`. Currently `mkScope` requires `namespaceResource`, `clusterLabels`, etc. We could either: (a) build full scopes in the pre-pass, or (b) create a lightweight `mkPhase1Scope` that only provides naming/labels (no `mkResource`). Option (b) is cleaner but means packages can't call `scope.mkResource` at the top level. None currently do in their `deps`/`meta` declarations, so this is safe.
