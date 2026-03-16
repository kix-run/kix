# Auto-Install: Implicit Dependency Instantiation

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Predecessor:** `04_dependency-injection-and-environments.md` (auto-resolve of existing instances)

---

## 1. The Problem

Auto-resolve (doc 04) finds *existing* instances by argument name. But you still have to explicitly declare every service in the cluster config. For infrastructure services (postgres, valkey, cert-manager) this is often ceremony — the app developer doesn't care about configuring postgres, they just need *a* postgres.

**Auto-install** means: if a package needs `postgres` and no instance exists, the system creates one with sensible defaults. You only declare the things you actually care about configuring.

The tension: this is incredibly convenient for dev environments and prototyping, but terrifying for production. The design must make the implicit/explicit boundary crystal clear.

---

## 2. What Auto-Install Actually Does

When `kixCallPackage` resolves argument `postgres` for `my-app`:

1. **Explicit override?** → use it (same as today)
2. **Auto-resolve finds existing instance?** → use it (doc 04)
3. **No instance found, auto-install enabled?** → create a default instance of package `postgres`
4. **No instance found, auto-install disabled?** → eval error

Step 3 is new. The system needs to:
- Know what "a default postgres" means (default config)
- Decide where to put it (which namespace)
- Make it visible to the fixpoint (other services can share it)
- Make the implicit instance inspectable (you can see what was auto-created)

---

## 3. Approach A: Demand-Driven Fixpoint

### The Idea

The outer fixpoint already lets all instances see each other. Extend it: when resolution fails, instead of throwing, insert a default instance into the fixpoint and retry.

### Mechanism

```nix
instances = lib.fix (self:
  let
    # Explicitly declared instances
    explicit = mapAttrs (name: svcCfg:
      kixCallPackage (loadPackage svcCfg) svcCfg { allInstances = self; }
    ) clusterConfig.services;

    # Demand-created instances (accumulated during resolution)
    # The fixpoint converges because each new auto-installed instance
    # may itself demand more instances, but the graph is finite.
    demanded = collectDemanded self;
  in explicit // demanded
);
```

The `resolve` function, instead of `throw "no postgres"`, returns a sentinel:

```nix
resolve = argName:
  # ... existing resolution logic ...
  else if autoInstall then
    { found = true; value = self.${demandKey argName}; autoInstalled = true; }
  else throw "...";
```

And `collectDemanded` materializes those:

```nix
collectDemanded = self:
  let
    # During resolution, record demands: { postgres = { requestedBy = "my-app"; }; }
    demands = getDemands self;  # collected as a side-effect of resolution
  in mapAttrs (name: demand:
    let
      pkg = loadPackage name;
      defaultConfig = pkg.defaultConfig or {};
      namespace = decideNamespace demand;
    in kixCallPackage pkg (defaultConfig // { inherit namespace; }) { allInstances = self; }
  ) demands;
```

### Namespace Placement

Where does the auto-installed postgres go? Options:

**A1. Same namespace as requester.**
Simple, predictable. But if two services in different namespaces both need postgres, you get two instances — maybe not what you want.

**A2. Dedicated "infra" namespace.**
All auto-installed services go to a well-known namespace (e.g., `auto` or `infra`). Predictable, but arbitrary.

**A3. Package declares a preferred namespace.**
The postgres package says `defaultNamespace = "data"`. If that namespace exists, use it. If not, create it. This feels most natural — infrastructure packages know where they belong.

```nix
# kixpkgs/postgres.nix
{
  defaultConfig = {
    namespace = "data";
    storage = "10Gi";
    version = "16";
  };
  # ...
}
```

**A4. Requester's namespace, but deduplicate.**
First auto-install goes to the requester's namespace. Subsequent requesters for the same package type find it via auto-resolve. Works but the first requester "wins" in a non-obvious way.

### Pros
- Minimal ceremony: declare your app, deps materialize
- The fixpoint handles everything — no separate pass
- Auto-installed instances are real instances, fully overridable via overlays

### Cons
- **Lazy eval hazard**: Nix is lazy, so "side-effect during resolution" is tricky. You can't accumulate demands imperatively. You'd need to structure this so that demands are derivable from the fixpoint itself — which means checking "does an instance with this package type exist? if not, I am the default."
- **Convergence**: The fixpoint must converge. If auto-installed postgres itself demands something that demands postgres, you get infinite recursion. Needs cycle detection.
- **Spooky action**: Adding an explicit postgres to the cluster suddenly changes behavior — the auto-installed one disappears and everything re-resolves. This could be confusing.

### The Lazy Eval Problem (Critical)

The biggest issue: Nix fixpoints are declarative. You can't "accumulate demands" during evaluation. The fixpoint is a function from `self` to `self`, and it must be total — it can't have side effects.

Workaround: instead of accumulating demands, make auto-installed instances **always present** in the fixpoint, but **only materialized** (included in manifests/closures) if something actually references them.

```nix
instances = lib.fix (self:
  let
    explicit = /* ... */;

    # Pre-create a default instance for every package in the registry.
    # These are lazy — Nix won't evaluate them unless someone accesses them.
    autoPool = mapAttrs (pkgName: pkg:
      kixCallPackage pkg (pkg.defaultConfig or {}) { allInstances = self; }
    ) packageRegistry;

    # Auto-pool instances are "shadowed" by explicit ones.
    # Resolution prefers explicit, falls back to autoPool.
  in explicit // (if autoInstall then removeAttrs autoPool (attrNames explicit) else {})
);
```

This is clean but expensive in theory — you evaluate every package in the registry. In practice, Nix laziness means only accessed packages get evaluated. The concern: does just having them in the attrset force evaluation? No — Nix attrsets are lazy in their values.

---

## 4. Approach B: Two-Pass Evaluation

### The Idea

Don't try to do auto-install in the fixpoint. Run two passes:

1. **First pass**: evaluate explicit instances, collect unresolved demands
2. **Second pass**: instantiate demanded packages, re-evaluate with the expanded instance set

### Mechanism

```nix
buildCluster = clusterConfig:
  let
    # Pass 1: try to resolve everything, collect failures
    pass1 = mapAttrs (name: svcCfg:
      let result = tryResolve (loadPackage svcCfg) svcCfg allExplicit;
      in { inherit result; unresolved = result.unresolvedArgs; }
    ) clusterConfig.services;

    # Collect all unresolved dependency names
    allDemands = unique (concatMap (r: r.unresolved) (attrValues pass1));

    # Auto-instantiate demanded packages
    autoInstances = genAttrs allDemands (name:
      let pkg = loadPackage name;
      in {
        package = name;
        namespace = pkg.defaultConfig.namespace or "auto";
      } // (pkg.defaultConfig or {})
    );

    # Pass 2: evaluate with explicit + auto instances
    mergedConfig = clusterConfig // {
      services = clusterConfig.services // autoInstances;
    };
  in buildClusterInner mergedConfig;
```

### Pros
- No fixpoint complexity — straightforward two-pass
- Clear separation: first you know what's needed, then you create it
- Easy to inspect: `pass1.unresolved` tells you exactly what was auto-installed and why

### Cons
- **Transitivity**: auto-installed postgres might itself need something (e.g., a PV provisioner). You'd need to recurse passes until convergence. This is essentially re-implementing the fixpoint, but worse.
- **Two-pass means two evaluations**: slower, and you need to be careful that pass 1 doesn't produce side effects that pass 2 relies on.
- **Doesn't compose with overlays as cleanly**: overlays operate on the fixpoint. If auto-installed instances are added between passes, overlays from pass 1 don't see them.

---

## 5. Approach C: Auto-Install as a Pre-Overlay

### The Idea

Auto-install is just an overlay that runs first. It inspects the package registry and the declared services, and fills gaps.

### Mechanism

```nix
autoInstallOverlay = packageRegistry: self: super:
  let
    # All package types that are depended upon but not instantiated
    needed = findNeededPackages packageRegistry (attrValues super);
    present = map (s: s.packageType) (attrValues super);
    missing = subtractLists present needed;
  in genAttrs missing (pkgName:
    let pkg = packageRegistry.${pkgName};
    in instantiate pkg (pkg.defaultConfig or {})
  );

mkCluster = {
  overlays = [
    autoInstallOverlay packageRegistry   # runs first
    # user overlays run after
  ];
};
```

### The Problem

`findNeededPackages` needs to know what each package depends on *before* instantiation. This requires either:
- Static metadata on packages (a `deps` field listing argument names)
- Or actually calling `builtins.functionArgs` on each package function

`builtins.functionArgs` is cheap and works:

```nix
findNeededPackages = registry: instances:
  let
    instancePkgs = map (i: loadPackage i) instances;
    allArgNames = unique (concatMap (p: attrNames (builtins.functionArgs p)) instancePkgs);
    depNames = subtractLists [ "scope" "config" "lib" ] allArgNames;
  in depNames;
```

But this only finds *direct* deps. The auto-installed postgres might need `certManager`, which needs `webhookCertProvider`, etc. The overlay would need to run iteratively until stable — which is what `lib.fix` does naturally.

### Pros
- Composes with the existing overlay system
- User overlays can override auto-installed instances normally
- Clean mental model: "auto-install is just a default overlay"

### Cons
- Transitivity problem (same as approach B)
- The overlay sees package *functions* but not their resolved instances, so it can only do static analysis of argument names
- Fragile: if a package uses `{ scope, config, ... }:` (variadic args), you can't introspect its deps

---

## 6. Approach D: Package Registry with Default Configs (Recommended for Discussion)

### The Idea

Combine approach A's fixpoint with explicit default configs. Every package in the registry can declare a `defaultInstance` — the config to use when auto-installing. The outer fixpoint includes a "virtual pool" of all registry packages, but they only manifest if referenced.

### Mechanism

```nix
# Package registry entry
# kixpkgs/postgres/default.nix
{
  package = import ./package.nix;

  # What to use when auto-installing this package
  defaultInstance = {
    namespace = "data";
    storage = "10Gi";
    version = "16";
  };

  # Packages that should never be auto-installed (e.g., your actual application)
  autoInstallable = true;  # default true for "library" packages, false for "app" packages
}
```

```nix
# The outer fixpoint
instances = lib.fix (self:
  let
    explicit = mapAttrs (name: svcCfg:
      kixCallPackage (loadPackage svcCfg) svcCfg { allInstances = self; }
    ) clusterConfig.services;

    # Virtual pool: every auto-installable package, with default config.
    # Only evaluated if accessed (Nix laziness).
    # Named with a well-known prefix to avoid collisions.
    pool = lib.optionalAttrs (clusterConfig.autoInstall or false) (
      mapAttrs (pkgName: entry:
        kixCallPackage entry.package entry.defaultInstance { allInstances = self; }
      ) (filterAttrs (_: e: e.autoInstallable) packageRegistry)
    );

  in explicit // pool  # explicit shadows pool
);
```

Resolution order becomes:
1. Explicit override → use it
2. Auto-resolve in explicit instances → use it
3. Auto-resolve in pool → use it (auto-installed)
4. Error

### Key Property: Promoting Auto-Installed to Explicit

When you want to customize an auto-installed package:

```nix
# Before: postgres auto-installed with defaults
services.my-app = { namespace = "prod"; image = "myapp:v1"; };
# postgres is auto-installed behind the scenes

# After: you want to customize postgres
services.my-app = { namespace = "prod"; image = "myapp:v1"; };
services.postgres = { namespace = "data"; storage = "500Gi"; version = "16"; };
# Now postgres is explicit, pool entry shadowed
```

This is the key UX win: auto-install gets you started, and promoting to explicit is just adding a `services.postgres` entry. No other changes needed — my-app doesn't know or care whether postgres was auto-installed or explicit.

### Visibility

```nix
cluster.autoInstalled
# → [ "postgres" "valkey" ]
# Shows which pool entries were actually accessed during evaluation

cluster.promote "postgres"
# → Prints the config you'd add to make postgres explicit:
#   services.postgres = { namespace = "data"; storage = "10Gi"; version = "16"; };
```

### Pros
- Clean fixpoint — no accumulation, no multi-pass
- Nix laziness handles the "only instantiate if needed" part naturally
- Promoting from auto to explicit is trivial
- Works with overlays (overlay can target pool entries)
- Transitive deps just work (pool entries can reference other pool entries)

### Cons
- Pool size = entire registry. For a large registry this means many lazy thunks. In practice probably fine, but worth measuring.
- Naming: auto-installed instances need stable names. Using the package name works unless you need two instances of the same type (but then you should be explicit anyway).
- The pool entry's namespace is decided by the package's `defaultInstance`, not by the requester. This is usually right but sometimes surprising.

---

## 7. Granularity: Cluster-Level vs Per-Service

Auto-install should be controllable at multiple levels:

```nix
{
  cluster.autoInstall = true;    # cluster-wide default

  services.my-app = {
    autoInstall = true;           # this service can trigger auto-install
  };

  services.critical-api = {
    autoInstall = false;          # all deps must exist explicitly
    autoResolve = false;          # all deps must be wired manually
  };
}
```

The relationship between auto-resolve and auto-install:

```
autoResolve = false, autoInstall = false  → everything manual
autoResolve = true,  autoInstall = false  → find existing, never create (default)
autoResolve = true,  autoInstall = true   → find existing, create if missing
autoResolve = false, autoInstall = true   → doesn't make sense (auto-install implies resolve)
```

---

## 8. Dev vs Prod: The Real Use Case

The killer use case for auto-install is environment differentiation:

```nix
# clusters/dev.nix
{
  cluster.autoInstall = true;      # just give me whatever I need
  defaults.replicas = 1;

  services.my-app = {
    namespace = "dev";
    image = "myapp:latest";
  };
  # postgres, valkey, cert-manager — all auto-installed with dev defaults
}

# clusters/production.nix
{
  cluster.autoInstall = false;     # everything explicit

  services.my-app = {
    namespace = "prod";
    image = "myapp:v2.1.0";
    replicas = 5;
  };

  services.postgres = {
    namespace = "data";
    storage = "500Gi";
    version = "16";
    backup.enabled = true;
    backup.schedule = "0 */6 * * *";
  };

  services.valkey = {
    namespace = "data";
    sentinel.enabled = true;
    persistence.enabled = true;
  };
}
```

The dev cluster is 5 lines. The prod cluster is fully explicit. Same packages, same dependency graph, completely different operational posture.

---

## 9. Interaction with `defaultInstance` Configs

Who controls the defaults for auto-installed packages?

### Option 1: Package declares defaults

```nix
# kixpkgs/postgres/default.nix
{ defaultInstance.storage = "10Gi"; defaultInstance.version = "16"; }
```

Pro: package author knows sensible defaults. Con: cluster operator can't override without going explicit.

### Option 2: Cluster-level default overrides

```nix
{
  cluster.autoInstall = true;
  cluster.autoInstallDefaults.postgres = {
    storage = "20Gi";    # override package default
  };
}
```

Pro: cluster operator controls defaults without going fully explicit. Con: another layer of config.

### Option 3: Environment defaults apply to auto-installed too

```nix
# In dev.nix
{
  defaults.storage = "5Gi";   # applies to all services including auto-installed
}
```

Pro: consistent with environment defaults mechanism. Con: coarse-grained.

Probably want all three, with precedence: explicit service config > cluster autoInstallDefaults > environment defaults > package defaultInstance.

---

## 10. Open Questions

### 10.1 Naming auto-installed instances
If auto-installed postgres is named `postgres` in the fixpoint, what happens when you explicitly add `services.postgres`? The explicit one shadows — clean. But what if the auto-installed one was in a different namespace? Services depending on it might break when you promote. The changeset visualizer should catch this.

### 10.2 Multiple auto-installs of same type
If `api` needs `valkey` and `worker` needs `valkey`, should auto-install create one or two? One (shared) is the right default — it matches what auto-resolve would do. But the user might want isolation. This is where promoting to explicit and using instance names matters.

### 10.3 Auto-install of non-library packages
Should `web-app` be auto-installable? Probably not — `autoInstallable = false` for "application" packages. But the boundary is fuzzy. cert-manager is infrastructure, postgres is a service, your app is an application. The package author decides by setting `autoInstallable`.

### 10.4 Fixpoint interaction
If auto-installed postgres auto-installs its own deps (say, a backup controller), and that controller auto-installs cert-manager — the chain works via fixpoint laziness. But how deep can this go before it becomes undebuggable? The `cluster.autoInstalled` introspection helps, but a tree view of "what caused what to be auto-installed" would be better.

### 10.5 Garbage collection
If you remove `my-app` and it was the only thing that needed postgres, the auto-installed postgres becomes unreferenced. Should the system warn? Remove it automatically? Nix's garbage collection analogy suggests: if nothing references it, it shouldn't be in the closure. Since auto-installed instances only manifest when referenced (via laziness), removing the last referencer should make it disappear from manifests automatically. This is a nice property.
