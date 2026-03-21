# 19 — Module System: Contrastive Approaches

**Problem statement:** The current module system proposal (doc 18) makes instances a side-effect of module config. You declare `options.instances` as a module option, and then fragments set `config.instances.ns.name = { ... }`. This feels wrong — instances aren't config, they're the *point* of the file. A fragment should own its instances as a first-class concern, not as a nested config key.

Additionally:
- `ref` should remain as the cross-instance reference mechanism
- Packages should have typed options
- Global configuration should be able to influence each package

This document contrasts four approaches with concrete code.

---

## Setup: What We're Building

A cluster with:
- **Platform infra**: cert-manager, ingress-nginx, ceph-storage
- **Team shopfront**: API server (prod + staging), postgres, valkey
- **Global policy**: all packages get `monitoring.enabled = true`, resource limits enforced

Package `acme-api` has typed options:
```nix
# packages/acme-api/_kixOptions.nix
{ lib, ... }: {
  replicaCount = lib.mkOption { type = lib.types.int; default = 2; };
  monitoring.enabled = lib.mkOption { type = lib.types.bool; default = false; };
  resources.limits.memory = lib.mkOption { type = lib.types.str; default = "512Mi"; };
}
```

---

## Approach A: Module System (Current Proposal, Doc 18)

Instances are a module option. Fragments are NixOS-style modules that set `config.instances`.

### Cluster definition
```nix
# clusters/nw1.nix
kix.buildCluster {
  name = "nw1";
  modules = [
    ./fragments/nw1/infra.nix
    ./fragments/nw1/shopfront.nix
    ./fragments/nw1/global-policy.nix
  ];
}
```

### Fragment: infra
```nix
# fragments/nw1/infra.nix
{ config, lib, packages, ... }: {
  # Options this fragment provides
  options.tls.issuer = lib.mkOption { type = lib.types.str; default = "letsencrypt-prod"; };

  # Instances are config — same namespace as monitoring.enabled or any other option
  config.instances = {
    cert-manager.cert-manager = {
      package = packages.cert-manager;
      config = { issuer = config.tls.issuer; };
    };
    ingress.ingress-nginx = {
      package = packages.ingress-nginx;
    };
    storage.ceph-fast = {
      package = packages.ceph-storage;
      config = { pool = "fast-ssd"; };
    };
  };
}
```

### Fragment: shopfront team
```nix
# fragments/nw1/shopfront.nix
{ config, lib, packages, ref, ... }: {
  config.instances = {
    shopfront-prod.api = {
      package = packages.acme-api;
      config = { replicaCount = 5; };
      deps = { postgres = ref.shopfront-prod.postgres; };
    };
    shopfront-prod.postgres = {
      package = packages.postgresql;
      config = { storage = "200Gi"; };
    };
    shopfront-staging.api = {
      package = packages.acme-api;
      config = { replicaCount = 1; };
    };
    shopfront-staging.postgres = {
      package = packages.postgresql;
      config = { storage = "10Gi"; };
    };
  };
}
```

### Global policy
```nix
# fragments/nw1/global-policy.nix
{ config, lib, ... }: {
  # How do you set monitoring.enabled on ALL packages?
  # Option 1: iterate over all instances (ugly, fragile)
  config.instances = lib.mapAttrs (_ns: lib.mapAttrs (_inst: prev:
    prev // { config = prev.config // { monitoring.enabled = true; }; }
  )) config.instances;  # ← this doesn't actually work in NixOS module system

  # Option 2: a separate global config mechanism
  options.global.monitoring.enabled = lib.mkOption { type = lib.types.bool; default = false; };
  config.global.monitoring.enabled = true;
  # ...but packages need to read scope.global.monitoring.enabled — new plumbing
}
```

### Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Instances are first-class | ❌ | They're nested under `config.instances` — same level as any random option |
| Fragment owns its instances | ⚠️ | Fragment *sets* instances, but they live in a global namespace it doesn't own |
| ref works | ✅ | `ref` is a `specialArg` to modules |
| Typed package options | ✅ | Via `deferredModule` per-instance eval |
| Global config → packages | ❌ | No clean mechanism; need to iterate or add `scope.global` |
| Clarity of "what does this file do?" | ⚠️ | `config.instances` is buried among other config |

**The core problem:** In NixOS modules, everything is `config`. There's no semantic distinction between "this module provides the postgres instance" and "this module sets monitoring.enabled = true". Instances deserve to be a separate, first-class declaration.

---

## Approach B: Fragment-Centric (Instances + Options + Config as Peers)

A **fragment** is a first-class construct with three sections: `options`, `config`, and `instances`. Instances are NOT options — they're a separate output of the fragment.

### Core idea
```
Fragment = {
  options   : attrset of option declarations     (NixOS-style)
  config    : attrset of option values            (NixOS-style)
  instances : { namespace.name = instance; ... }  (first-class, NOT a config key)
}
```

The fragment evaluator:
1. Collects all `options` and `config` from all fragments → evalModules
2. Collects all `instances` from all fragments → merge (collision = error)
3. Passes evaluated config to instance builders

### Cluster definition
```nix
# clusters/nw1.nix
kix.buildCluster {
  name = "nw1";
  fragments = [
    ./fragments/nw1/infra.nix
    ./fragments/nw1/shopfront.nix
    ./fragments/nw1/global-policy.nix
  ];
}
```

### Fragment: infra
```nix
# fragments/nw1/infra.nix
{ config, lib, packages, ref, ... }: {

  # What this fragment configures for the cluster
  options.tls.issuer = lib.mkOption {
    type = lib.types.str;
    default = "letsencrypt-prod";
  };

  # What this fragment deploys — first-class, not buried in config
  instances = {
    cert-manager.cert-manager = {
      package = packages.cert-manager;
      config = { issuer = config.tls.issuer; };
    };
    ingress.ingress-nginx = {
      package = packages.ingress-nginx;
    };
    storage.ceph-fast = {
      package = packages.ceph-storage;
      config = { pool = "fast-ssd"; };
    };
  };
}
```

### Fragment: shopfront team
```nix
# fragments/nw1/shopfront.nix
{ config, lib, packages, ref, ... }: {
  instances = {
    shopfront-prod.api = {
      package = packages.acme-api;
      config = {
        replicaCount = 5;
      };
      deps = { postgres = ref.shopfront-prod.postgres; };
    };
    shopfront-prod.postgres = {
      package = packages.postgresql;
      config = { storage = "200Gi"; };
    };
    shopfront-staging.api = {
      package = packages.acme-api;
      config = { replicaCount = 1; };
    };
    shopfront-staging.postgres = {
      package = packages.postgresql;
      config = { storage = "10Gi"; };
    };
  };
}
```

### Global policy
```nix
# fragments/nw1/global-policy.nix
{ config, lib, ... }: {
  # Cluster-wide options
  options.global = {
    monitoring.enabled = lib.mkOption { type = lib.types.bool; default = true; };
    resources.defaultLimits.memory = lib.mkOption { type = lib.types.str; default = "512Mi"; };
  };

  config.global = {
    monitoring.enabled = true;
    resources.defaultLimits.memory = "1Gi";
  };

  # No instances — this fragment is pure policy
}
```

### How global config reaches packages

The `scope` object carries `clusterConfig` (the evaluated module config):

```nix
# packages/acme-api/default.nix
{ scope, config, lib }: self: {
  deployment = scope.mkResource {
    spec.template.spec.containers = [{
      resources.limits.memory =
        config.resources.limits.memory  # instance-level (typed, from _kixOptions)
          or scope.clusterConfig.global.resources.defaultLimits.memory;  # cluster-level fallback
    }];
  };
  serviceMonitor =
    if config.monitoring.enabled or scope.clusterConfig.global.monitoring.enabled
    then scope.mkResource { ... }
    else null;
  # ...
}
```

Alternatively, `global` config can be injected into each instance's config as defaults *before* the per-instance deferredModule eval:

```nix
# In the fragment evaluator (lib/eval.nix):
evaluateInstanceConfig = inst:
  lib.evalModules {
    modules = [
      inst.package._kixOptions          # package's typed options
      { config = clusterConfig.global; } # global defaults (lowest priority)
      inst.config                        # instance-specific config (higher priority)
    ];
  };
```

This way `config.monitoring.enabled` in the package is `true` by default (from global), but any instance can override it.

### Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Instances are first-class | ✅ | Separate `instances` key, not buried in config |
| Fragment owns its instances | ✅ | Each fragment declares exactly what it deploys |
| ref works | ✅ | Passed as fragment arg |
| Typed package options | ✅ | Via deferredModule + _kixOptions |
| Global config → packages | ✅ | Via scope.clusterConfig or injected as defaults |
| Clarity of "what does this file do?" | ✅ | Glance at `instances` to see what's deployed |

**Trade-off:** This is NOT a pure NixOS module system anymore. We use evalModules for options/config, but instances are a separate merge. This means we can't use NixOS module features (like `mkIf`, `mkMerge`) on instances — but do we need to?

---

## Approach C: Instance-First with Typed Config Layers

Keep the current `buildCluster` shape where instances are front-and-center, but add typed options and a config layering system. No NixOS module system at all — just Nix functions + convention.

### Core idea
```
Cluster = buildCluster {
  name = "nw1";
  clusterConfig = { ... };          # global config
  fragments = [ frag1 frag2 ... ];  # each returns { instances, namespaces? }
}
```

Fragments are plain functions, not modules. No `options` declarations — typing comes from packages.

### Cluster definition
```nix
# clusters/nw1.nix
kix.buildCluster {
  name = "nw1";

  # Global config — reaches every package via scope.clusterConfig
  clusterConfig = {
    monitoring.enabled = true;
    resources.defaultLimits.memory = "1Gi";
  };

  # Fragments are just functions returning instances
  fragments = [
    (import ./fragments/nw1/infra.nix)
    (import ./fragments/nw1/shopfront.nix)
  ];
}
```

### Fragment: infra
```nix
# fragments/nw1/infra.nix
{ packages, ref, clusterConfig, ... }: {
  instances = {
    cert-manager.cert-manager = {
      package = packages.cert-manager;
      config = { issuer = "letsencrypt-prod"; };
    };
    ingress.ingress-nginx = {
      package = packages.ingress-nginx;
    };
    storage.ceph-fast = {
      package = packages.ceph-storage;
      config = { pool = "fast-ssd"; };
    };
  };
}
```

### Fragment: shopfront team
```nix
# fragments/nw1/shopfront.nix
{ packages, ref, clusterConfig, ... }: {
  instances = {
    shopfront-prod.api = {
      package = packages.acme-api;
      config = { replicaCount = 5; };
      deps = { postgres = ref.shopfront-prod.postgres; };
    };
    shopfront-prod.postgres = {
      package = packages.postgresql;
      config = { storage = "200Gi"; };
    };
    shopfront-staging.api = {
      package = packages.acme-api;
      config = { replicaCount = 1; };
    };
    shopfront-staging.postgres = {
      package = packages.postgresql;
      config = { storage = "10Gi"; };
    };
  };
}
```

### Typed options in packages
```nix
# packages/acme-api/default.nix
{ scope, config, lib }: self:
let
  # Package declares its own typed config (validated at eval time)
  cfg = scope.typedConfig config {
    replicaCount = { type = "int"; default = 2; };
    monitoring.enabled = {
      type = "bool";
      default = scope.clusterConfig.monitoring.enabled or false;  # ← global fallback
    };
    resources.limits.memory = {
      type = "string";
      default = scope.clusterConfig.resources.defaultLimits.memory or "512Mi";
    };
  };
in {
  deployment = scope.mkResource {
    spec.replicas = cfg.replicaCount;
    spec.template.spec.containers = [{
      resources.limits.memory = cfg.resources.limits.memory;
    }];
  };
  serviceMonitor = if cfg.monitoring.enabled then scope.mkResource { ... } else null;
  main = self.service;
}
```

### Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Instances are first-class | ✅ | Fragments return `{ instances }` — that's their whole purpose |
| Fragment owns its instances | ✅ | Fragment IS its instances |
| ref works | ✅ | Passed as fragment arg |
| Typed package options | ✅ | Via `scope.typedConfig` inline in package |
| Global config → packages | ✅ | `scope.clusterConfig` available, used as defaults in typed config |
| Clarity of "what does this file do?" | ✅ | Fragment = instances, nothing else |
| Cross-cutting options | ⚠️ | No module system → no `options` declarations, no `mkIf` |
| Composable policies | ❌ | Can't have a fragment that *modifies* another fragment's instances |

**Trade-off:** Maximum simplicity, but no way for a policy fragment to say "for all instances, add this sidecar" or "force replicaCount ≥ 2 in production namespaces". Global config is read-only defaults, not enforceable policy.

---

## Approach D: Fragment = Options + Config + Instances + Transforms

Extends Approach B. A fragment has four sections: `options`, `config`, `instances`, and `transforms`. Transforms let policy fragments modify instances they don't own.

### Core idea
```
Fragment = {
  options    : option declarations
  config     : option values
  instances  : { namespace.name = instance }       (first-class)
  transforms : instance → instance                  (applied after merge)
}
```

Evaluation order:
1. Collect all `options`/`config` → evalModules → `clusterConfig`
2. Collect all `instances` → merge (collision = error)
3. Apply all `transforms` to merged instances (in fragment order)
4. Evaluate instances with typed config (deferredModule)
5. Build fixpoint (DI, refs, closures)

### Cluster definition
```nix
# clusters/nw1.nix
kix.buildCluster {
  name = "nw1";
  fragments = [
    ./fragments/nw1/infra.nix
    ./fragments/nw1/shopfront.nix
    ./fragments/nw1/policy-prod.nix     # ← policy fragment
    ./fragments/nw1/policy-monitoring.nix
  ];
}
```

### Fragment: infra (same as B)
```nix
{ config, lib, packages, ref, ... }: {
  options.tls.issuer = lib.mkOption { type = lib.types.str; default = "letsencrypt-prod"; };

  instances = {
    cert-manager.cert-manager = {
      package = packages.cert-manager;
      config = { issuer = config.tls.issuer; };
    };
    ingress.ingress-nginx = { package = packages.ingress-nginx; };
    storage.ceph-fast = {
      package = packages.ceph-storage;
      config = { pool = "fast-ssd"; };
    };
  };
}
```

### Fragment: shopfront team (same as B)
```nix
{ config, lib, packages, ref, ... }: {
  instances = {
    shopfront-prod.api = {
      package = packages.acme-api;
      config = { replicaCount = 5; };
      deps = { postgres = ref.shopfront-prod.postgres; };
    };
    shopfront-prod.postgres = {
      package = packages.postgresql;
      config = { storage = "200Gi"; };
    };
    shopfront-staging.api = {
      package = packages.acme-api;
      config = { replicaCount = 1; };
    };
    shopfront-staging.postgres = {
      package = packages.postgresql;
      config = { storage = "10Gi"; };
    };
  };
}
```

### Policy: production hardening
```nix
# fragments/nw1/policy-prod.nix
{ config, lib, ... }: {
  options.prod.minReplicas = lib.mkOption { type = lib.types.int; default = 2; };

  config.prod.minReplicas = 2;

  # Transform: enforce minimum replicas in production namespaces
  transforms = {
    # Pattern: namespace glob → instance transformer
    "shopfront-prod.*" = inst: inst // {
      config = inst.config // {
        replicaCount = lib.max
          (inst.config.replicaCount or 1)
          config.prod.minReplicas;
      };
    };
    # Or apply to everything:
    # "*.*" = inst: inst // { ... };
  };
}
```

### Policy: monitoring everywhere
```nix
# fragments/nw1/policy-monitoring.nix
{ config, lib, packages, ... }: {
  # Transform: inject monitoring.enabled into every instance config
  transforms = {
    "*.*" = inst: inst // {
      config = inst.config // {
        monitoring = (inst.config.monitoring or {}) // { enabled = true; };
      };
    };
  };

  # Also deploy the monitoring stack itself
  instances = {
    monitoring.kube-prometheus = {
      package = packages.kube-prometheus-stack;
      config = { retention = "30d"; };
    };
  };
}
```

### How transforms compose

Transforms are applied in fragment order. Each transform sees the *current* state of the instance (after previous transforms). This is like overlays:

```
raw instances (from all fragments)
  |> policy-prod transforms     (enforce minReplicas)
  |> policy-monitoring transforms (inject monitoring.enabled)
  = final instances
```

### What a package sees
```nix
# packages/acme-api/default.nix
{ scope, config, lib, postgres ? null, cluster-issuer ? null }:
self:
let
  # config already has monitoring.enabled = true (from transform)
  # config already has replicaCount = max(5, 2) = 5 (from transform)
  # Package validates via _kixOptions (deferredModule)
in {
  deployment = scope.mkResource {
    spec.replicas = config.replicaCount;
    # ...
  };
  serviceMonitor =
    if config.monitoring.enabled
    then scope.mkResource { ... }
    else null;
  main = self.service;
}
```

### Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Instances are first-class | ✅ | Top-level `instances` key in fragment |
| Fragment owns its instances | ✅ | Clear ownership |
| ref works | ✅ | Passed as fragment arg |
| Typed package options | ✅ | deferredModule on final (post-transform) config |
| Global config → packages | ✅ | Transforms inject into config before package eval |
| Cross-cutting policy | ✅ | Transforms can modify any instance by pattern |
| Clarity of "what does this file do?" | ✅ | instances = what's deployed, transforms = what's modified |
| Composability | ✅ | Multiple policy fragments compose naturally |

**Trade-off:** Transforms add a new concept. The glob-pattern matching (`"shopfront-prod.*"`) needs clear semantics. Order-dependence of transforms could surprise.

---

## Approach E: Everything is a Fragment (Unified)

What if we push harder on the idea that a fragment defines options, config, instances, AND it can *contribute config to other fragments' instances*? Instead of transforms, use the module system's merge semantics — but only for instance *config*, not instance *existence*.

### Core idea

Instances have two phases:
1. **Declaration** — a fragment declares that an instance *exists* (package + initial config). Only one fragment can declare an instance (collision = error).
2. **Configuration** — any fragment can contribute additional config to any declared instance (via module merge with priority).

```
Fragment = {
  options    : option declarations
  config     : option values
  instances  : { ns.name = { package, config, deps, ... } }  (declaration)
  configure  : { ns.name = { config additions } }            (contribute to others)
}
```

### Cluster definition
```nix
kix.buildCluster {
  name = "nw1";
  fragments = [
    ./fragments/nw1/infra.nix
    ./fragments/nw1/shopfront.nix
    ./fragments/nw1/policy.nix
  ];
}
```

### Fragment: shopfront team
```nix
{ config, lib, packages, ref, ... }: {
  # I own these instances
  instances = {
    shopfront-prod.api = {
      package = packages.acme-api;
      config = { replicaCount = 5; };
      deps = { postgres = ref.shopfront-prod.postgres; };
    };
    shopfront-prod.postgres = {
      package = packages.postgresql;
      config = { storage = "200Gi"; };
    };
  };
}
```

### Policy fragment
```nix
# fragments/nw1/policy.nix
{ config, lib, ... }: {
  # I don't own any instances, but I configure all of them
  configure = {
    # Explicit: target specific instances
    shopfront-prod.api.config = {
      monitoring.enabled = lib.mkDefault true;     # can be overridden by owner
      resources.limits.memory = lib.mkForce "1Gi"; # cannot be overridden
    };
    shopfront-prod.postgres.config = {
      monitoring.enabled = lib.mkDefault true;
    };

    # Or with a wildcard helper:
    # (kix.forAllInstances { monitoring.enabled = lib.mkDefault true; })
  };
}
```

### How config merges

Each instance's final config is:
```
lib.evalModules [
  package._kixOptions                              # type declarations + defaults (priority 1500)
  instance.config                                   # owner's config (priority 100, normal)
  ...all configure contributions for this instance  # policy config (with explicit priorities)
]
```

`mkDefault` (priority 1000) means "unless the owner set it".
`mkForce` (priority 50) means "platform overrides the owner".

### Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Instances are first-class | ✅ | Top-level `instances` |
| Fragment owns its instances | ✅ | Only owner declares; others only `configure` |
| ref works | ✅ | Passed as fragment arg |
| Typed package options | ✅ | deferredModule with all config sources merged |
| Global config → packages | ✅ | `configure` with priorities |
| Cross-cutting policy | ✅ | `configure` can target any instance |
| Clarity | ✅ | `instances` = what I own, `configure` = what I influence |
| NixOS priority system | ✅ | `mkDefault`/`mkForce` give clear precedence |

**Trade-off:** `configure` is verbose when you want "apply to all instances" — you need a helper function or explicit enumeration. The separation between `instances.x.config` (owner) and `configure.x.config` (others) might feel redundant when you're both the owner and the policy maker.

---

## Side-by-Side: The Same Cluster in Each Approach

### "Add monitoring to all instances" pattern

| Approach | How |
|----------|-----|
| A (Module) | `config.instances = mapAttrs (mapAttrs (...))` — doesn't work with module system |
| B (Fragment) | `scope.clusterConfig.global.monitoring.enabled` — packages read it, opt-in |
| C (Instance-first) | `scope.clusterConfig.monitoring.enabled` — same as B but simpler |
| D (Transforms) | `transforms."*.*" = inst: inst // { config.monitoring.enabled = true; }` |
| E (Configure) | `configure = kix.forAllInstances { monitoring.enabled = mkDefault true; }` |

### "Force minimum replicas in prod" pattern

| Approach | How |
|----------|-----|
| A (Module) | Need custom assertion logic outside module system |
| B (Fragment) | Not possible — fragments can't modify others' instances |
| C (Instance-first) | Not possible — no modification mechanism |
| D (Transforms) | `transforms."*-prod.*" = inst: inst // { config.replicaCount = max ... }` |
| E (Configure) | `configure.*-prod.*.config.replicaCount = mkForce 2;` (with wildcard helper) |

### "Team adds a new service" pattern (DX for app developer)

All approaches are identical:
```nix
instances.shopfront-prod.new-service = {
  package = packages.my-new-service;
  config = { ... };
};
```

### "Package reads global + instance config" pattern

| Approach | How |
|----------|-----|
| A | Package reads `scope.clusterConfig.global.x` (if plumbed) + `config.x` — two sources |
| B | Same as A |
| C | `scope.typedConfig` with `default = scope.clusterConfig.x` — one source with fallback |
| D | config is already merged (transform applied) — package reads `config.x` only |
| E | config is already merged (configure applied) — package reads `config.x` only |

**Key insight:** D and E are the only approaches where the package doesn't need to know about global vs. instance config. It just reads `config.x`, and the system has already merged everything with proper priority. This is cleaner for package authors.

---

## Recommendation: Approach D or E

Both D (transforms) and E (configure) solve all the stated requirements. The choice is about style:

### D (Transforms) wins if:
- You want a functional, pipeline-style composition (`raw |> transform1 |> transform2`)
- You're comfortable with glob patterns for targeting
- You value that transforms are explicit functions — you can see exactly what they do
- You want to keep the fragment model simple (no module system needed for transforms)

### E (Configure) wins if:
- You prefer the NixOS priority model (`mkDefault`, `mkForce`) over ordered transforms
- You want type checking on configure contributions (they go through deferredModule)
- You value that configure targets are explicit (you name the instance you're configuring)
- You want the module system to catch type errors in policy config at eval time

### A hybrid of D and E is possible:

```nix
{ config, lib, packages, ref, ... }: {
  options.prod.minReplicas = lib.mkOption { type = lib.types.int; default = 2; };

  # First-class instances
  instances = {
    monitoring.prometheus = { package = packages.kube-prometheus-stack; };
  };

  # Type-checked config contributions to other instances (NixOS merge)
  configure = {
    shopfront-prod.api.config.monitoring.enabled = lib.mkDefault true;
  };

  # Functional transforms for structural changes (adding sidecars, etc.)
  transforms = {
    "*-prod.*" = inst: inst // {
      partsOverlays = (inst.partsOverlays or []) ++ [
        (self: base: { pdb = scope.mkResource { ... }; })  # enforce PDB in prod
      ];
    };
  };
}
```

This gives you:
- `instances` for ownership (first-class)
- `configure` for typed config contributions (priority-based merge)
- `transforms` for structural modifications that go beyond config (partsOverlays, sidecars, etc.)

---

## Open Questions

1. **Should `ref` be available in fragment args?** All approaches assume yes. But `ref` is the outer fixpoint — does it exist before instances are merged? Answer: yes, because `ref` is lazy (Nix thunks). You declare `deps = { x = ref.ns.y; }` and the thunk resolves during the fixpoint evaluation, after all instances are collected.

2. **Wildcard helpers for `configure`:** E needs `kix.forAllInstances`, `kix.forNamespace "prod-*"`, etc. These are just library functions that expand to explicit attrsets. How magical should they be?

3. **Transform ordering:** D's transforms apply in fragment list order. Is this sufficient? Should we support priority numbers on transforms?

4. **Can a transform add instances?** Probably not — that breaks the "instances are declared, not derived" principle. Transforms should only modify config/deps/partsOverlays of existing instances.

5. **Validation timing:** When do typed option errors surface? Ideally at `nix build` time with a clear message: "Instance shopfront-prod.api: option 'replicaCount' expects int, got string 'five'".

6. **Should `configure` and `instances.*.config` use the same merge semantics?** If yes, then the owner's config and policy config are equivalent — the only difference is that the owner declares the package. If no, the owner's config has a different default priority.
