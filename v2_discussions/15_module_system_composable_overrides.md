# Module System: Override and Overlay Composition

## Working Document — March 2026

**Status:** Design exploration
**Predecessors:** doc 12, 13, 14 (module system approaches)

---

## 1. The Problem

kix has several override mechanisms that must survive the transition to a
module system:

- **Config overrides**: `scope.defaults config defs` does `recursiveUpdate` —
  whoever writes last wins, no priority control
- **DI overrides**: explicit instance references mixed into instance config
  attrs alongside `package`, `config`, etc.
- **Parts overrides**: `parts = self: base: base // { ... }` — replaces or
  extends individual parts in an instance's inner fixpoint
- **Namespace policies**: via `mergeFragments`'s `namespacePolicies` parameter

Two problems: (1) overrides lack priority control, (2) DI overrides are mixed
into config, conflating wiring with behavior.

---

## 2. Three Separate Concern Layers

Each instance gets three distinct attributes, each with its own semantics.
This mirrors nixpkgs conventions:

```nix
instances.cache.myapp = {
  package = packages.python-app;
  packageType = "python-app";

  # Layer 1: Configuration — values that control behavior
  config = {
    backend.replicaCount = 4;
    ingress.enabled = true;
  };

  # Layer 2: DI overrides — wiring, like nixpkgs .override { }
  deps = {
    postgres = ref.other-ns.special-pg;
    cluster-issuer = ref.cert-manager.staging-issuer;
  };

  # Layer 3: Parts overlays — resource structure, like nixpkgs .overrideAttrs
  partsOverlays = [
    (self: base: { hpa = null; })
  ];
};
```

| Layer | Attribute | Controls | nixpkgs analogy | Override mechanism |
|-------|-----------|---------|----------------|-------------------|
| 1 | `config` | Behavior (replicas, images, flags) | Config args | Module priority (`mkDefault`, `mkForce`) |
| 2 | `deps` | Wiring (which postgres, which issuer) | `.override { }` | Attrset merge (collision = error) |
| 3 | `partsOverlays` | Resource structure (add/remove parts) | `.overrideAttrs` | List concat (composable, ordered) |

---

## 3. Layer 1: Config (Module Priority)

The module system's priority mechanism replaces `scope.defaults` /
`recursiveUpdate`:

```nix
# Package default via _kixOptions (mkOption default)
replicaCount = lib.mkOption { type = lib.types.int; default = 3; };

# Fragment sets it (normal priority wins over mkDefault/option default)
config.instances.cache.valkey.config.replicaCount = 5;

# Platform forces it (mkForce wins over everything)
config.instances.cache.valkey.config.replicaCount = lib.mkForce 1;

# Two fragments both setting replicaCount at normal priority → merge error
# (explicit, not silent override)
```

Priority levels:
- Option `default` / `lib.mkDefault` (1000) — package defaults
- Normal (100) — fragment/team settings
- `lib.mkForce` (50) — platform enforcement
- `lib.mkOverride N` — arbitrary priority for fine-grained control

`scope.defaults` is removed. Defaults live in package option declarations.

---

## 4. Layer 2: DI Overrides via `deps` (Attrset Merge)

**Today** — DI overrides are mixed into instance config:

```nix
# Today: postgres override is a sibling of package, config, packageType
instances.cache.myapp = {
  package = packages.python-app;
  config = { ... };
  postgres = ref.other-ns.special-pg;  # DI override mixed in
};
```

This conflates wiring with config. `kixCallPackage` checks
`instanceConfig.${argName}` for each dep — same namespace as `package`,
`config`, `packageType`.

**After** — DI overrides are a separate `deps` attribute:

```nix
instances.cache.myapp = {
  package = packages.python-app;
  config = { ... };
  deps = {
    postgres = ref.other-ns.special-pg;      # explicit DI override
    cluster-issuer = ref.cert-manager.staging-issuer;
  };
};
```

In `kixCallPackage`:

```nix
# Before:
explicitOverride = instanceConfig.${argName} or null;

# After:
explicitOverride = (instanceConfig.deps or {}).${argName} or null;
```

### Module system type

```nix
options.deps = lib.mkOption {
  type = types.attrsOf types.anything;
  default = {};
  description = ''
    Explicit DI dependency overrides. Keys are package function arg names
    (e.g., "postgres", "cluster-issuer"). Values are instance references.
    Like nixpkgs .override { }.
  '';
};
```

### Override semantics

DI overrides are NOT subject to module priority. They're plain attrset merges.
If two modules set the same dep for the same instance → collision error:

```nix
# Module A:
config.instances.cache.myapp.deps.postgres = ref.data.pg-primary;

# Module B:
config.instances.cache.myapp.deps.postgres = ref.data.pg-replica;

# → Error: deps.postgres defined by multiple modules
```

This is intentional. Wiring should be unambiguous — if two modules disagree
about which postgres to use, that's a real conflict that must be resolved
explicitly.

### When `deps` is empty (the common case)

Most instances don't set `deps` at all. The DNS-like DI auto-resolution
handles it:

```nix
instances.cache.myapp = {
  package = packages.python-app;
  config = { ... };
  # No deps — DI auto-resolves postgres, valkey, cluster-issuer, etc.
};
```

`deps` is only for overriding the default resolution when a specific instance
must be wired explicitly.

---

## 5. Layer 3: Parts Overlays (Composable, Ordered)

Multiple modules can each contribute a parts overlay:

```nix
options.partsOverlays = lib.mkOption {
  type = types.listOf (types.functionTo (types.functionTo types.anything));
  default = [];
  description = "Parts overlay functions, applied in order. Like nixpkgs overlays.";
};
```

```nix
# Platform module: inject sidecar into all deployments
config.instances.cache.valkey.partsOverlays = [
  (self: base: {
    deployment = base.deployment // {
      # Add logging sidecar
    };
  })
];

# Team module: disable HPA
config.instances.cache.valkey.partsOverlays = [
  (self: base: {
    hpa = null;  # disable
  })
];
```

`evaluateInstance` folds them:

```nix
parts = builtins.foldl'
  (prevFn: overlay:
    self: let base = prevFn self; in base // (overlay self base))
  innerFn
  instanceConfig.partsOverlays;
finalParts = lib.fix parts;
```

This is analogous to `nixpkgs.overlays` — multiple overlays compose in order,
each seeing the result of previous overlays.

---

## 6. Namespace Policies: Become Module Priority

Currently `mergeFragments` has a `namespacePolicies` parameter that applies
platform-owned overrides on top of fragment namespace configs.

With the module system, this becomes priority-based:

```nix
# Platform module: enforced namespace policies
{ lib, ... }: {
  config.namespaces.cache.networkPolicies.deny-all = lib.mkForce {
    spec = { podSelector = {}; policyTypes = [ "Ingress" "Egress" ]; };
  };
}
```

`mkForce` ensures the platform policy wins over any team-level namespace
config. Teams can still add their own network policies (at normal priority)
without conflicting.

---

## 7. mkEnv Overrides

`mkEnv` currently supports per-environment config overrides. With the module
system, `mkEnv` becomes a module generator that returns a list of modules:

```nix
mkEnvModules = envName: envConfig: instanceSets:
  let
    baseModule = { ... }: {
      config.instances = lib.mapAttrs (setName: setFn: ...) instanceSets;
    };
    overrideModule = { lib, ... }: {
      config.instances = lib.mapAttrs (setName: overrides:
        lib.mapAttrs (instName: instOverrides: {
          config = instOverrides.config or {};
          deps = instOverrides.deps or {};
        }) overrides
      ) (envConfig.overrides or {});
    };
  in [ baseModule overrideModule ];
```

---

## 8. Summary: Override Mechanisms Mapping

| Current | Module System | Power |
|---------|--------------|-------|
| `scope.defaults` / `recursiveUpdate` | `config` with module priority | Strictly better — explicit priority, type-checked |
| DI overrides mixed into instance attrs | `deps` (separate attrset) | Better — clean separation, collision detection |
| `parts = self: base: ...` (single) | `partsOverlays` (list, composable) | Better — multiple modules contribute |
| `mergeFragments.namespacePolicies` | `mkForce` on namespace options | Equivalent — same semantics |
| `mkEnv.overrides` | Override modules with priority | Better — composes with other modules |
| Silent last-write-wins | Merge error on conflict | Better — explicit, no surprises |

No existing override capability is lost. All become more powerful through
priority control, clean separation of concerns, and composability.
