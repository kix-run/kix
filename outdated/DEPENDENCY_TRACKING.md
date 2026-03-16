# Dependency Tracking: History and Architecture

## The Problem

K8s manifests have implicit ordering requirements (Namespace before namespaced resources,
SA before Deployments, CRDs before CRs, etc.). `kubectl apply` handles this with retries,
but single-pass tools and GitOps controllers benefit from correct ordering.

Apply ordering is the immediate use case, but dependency tracking is a key future feature
for cluster-level dependency management and introspection.

## How Original Kix Handled It

The original kix prototype (`~/Projects/kix`) had **three** dependency mechanisms:

### 1. Store paths as resource names (simple-dependency experiment)
Each resource was a **derivation**. Dependencies were `buildInputs`:
```nix
clusterrole = mkYamlDerivation "coredns-clusterrole" ./yamls/clusterrole.yaml [];
clusterrolebinding = mkYamlDerivation "coredns-clusterrolebinding" ./yamls/clusterrolebinding.yaml [
  clusterrole  # Nix DAG IS the K8s dependency graph
];
```
`nix-store --query --graph` gives you the K8s apply order for free.

### 2. mkManifest as reference (`coredns/lib/default.nix`)
Builders called `self.mkManifest` on referenced resources, embedding the store path as the name:
```nix
bind = clusterRole: serviceAccount:
  self.mkResource {
    kind = "ClusterRoleBinding";
    roleRef.name = self.mkManifest clusterRole;       # store path = name = reference
    subjects = [{ name = self.mkManifest serviceAccount; }];
  };

withServiceAccount = serviceAccount: deployment:
  lib.recursiveUpdate deployment {
    spec.template.spec.serviceAccountName = self.mkManifest serviceAccount;
  };
```

### 3. Explicit `addDependency` annotation
For deps that aren't name-references (e.g., Service→Deployment):
```nix
addDependency = drv: resource:
  lib.recursiveUpdate resource {
    metadata.annotations."build.kix.dev/dependencies" = newDeps;
  };

intoService = serviceArgs: deployment:
  self.networking.mkService (...)
  |> self.addDependency (self.mkManifest deployment);
```

**All three are really one idea:** let the Nix DAG be the K8s dependency graph.
Single source of truth — the reference in the YAML IS the dependency edge.

## What kixpkgs Lost

We moved to **human-readable names** (good — store paths are illegal in K8s names) but
didn't replace the dependency tracking with anything. Builders like `mkClusterRoleBinding`
and `withServiceAccount` still receive the actual Nix objects, extract `.metadata.name` as
a string, and **discard the reference**.

The `validateManifestSet` function in `flake.nix` then tries to **recover** these
relationships by string-parsing `serviceAccountName`, `roleRef.name`, `volumes[].configMap.name`,
etc. — a bunch of special cases that's fragile and can't produce an ordering.

## Options Considered

### Option A: `_deps` metadata (pragmatic patch)

Builders record dependencies at construction time via a `_deps` field:
```nix
mkClusterRoleBinding = clusterRole: serviceAccount: {
  # ... normal K8s fields ...
  _deps = [ clusterRole serviceAccount ];
};

withServiceAccount = sa: deployment: deployment // {
  # ... normal K8s fields ...
  _deps = (deployment._deps or []) ++ [ sa ];
};
```

**Problem: redundant bookkeeping.** The relationship is stored twice — once as a string
for K8s (`roleRef.name = "cert-manager"`), once as a Nix value in `_deps`. They can get
out of sync. Someone writes the correct K8s YAML but forgets `_deps` — the graph is
silently wrong.

### Option B: Kind-based static ordering

A fixed priority list (Namespace=0, SA=10, ClusterRole=20, Deployment=40, etc.).
Same approach Helm uses. Zero builder changes, covers 95% of apply ordering.

**Problem:** No real graph. Can't answer "what depends on what?" or validate references.
Not a foundation for cluster-level dependency management.

### Option C: Typed references (single source of truth with human-readable names)

**This is the chosen approach.** It recovers original kix's single-source-of-truth property
without store paths.

## Chosen Approach: Typed References

### Core idea

Instead of extracting `.metadata.name` as a string and discarding the object, builders
store a **ref** — a marker that carries the actual resource object. Resolution to a
human-readable string happens at serialization time, and the dependency graph falls out
as a byproduct.

```nix
# A reference — wraps the actual resource object
ref = resource: { _ref = resource; };

# Builders use ref() instead of extracting .metadata.name
mkClusterRoleBinding = clusterRole: sa: mkResource {
  kind = "ClusterRoleBinding";
  roleRef = {
    kind = "ClusterRole";
    name = ref clusterRole;       # not a string — carries the object
  };
  subjects = [{
    kind = "ServiceAccount";
    name = ref sa;                # same
  }];
};

withServiceAccount = sa: deployment:
  lib.recursiveUpdate deployment {
    spec.template.spec.serviceAccountName = ref sa;
  };
```

### Resolution

One function walks the tree, resolves refs to strings, and collects edges:

```nix
# Returns { resolved = <clean attrset>; deps = [ <referenced resources> ]; }
resolveRefs = resource:
  let
    walk = val:
      if builtins.isAttrs val && val ? _ref then
        { resolved = val._ref.metadata.name; deps = [ val._ref ]; }
      else if builtins.isAttrs val then
        let
          walked = builtins.mapAttrs (_: walk) val;
        in {
          resolved = builtins.mapAttrs (_: v: v.resolved) walked;
          deps = builtins.concatLists (map (v: v.deps) (builtins.attrValues walked));
        }
      else if builtins.isList val then
        let
          walked = map walk val;
        in {
          resolved = map (v: v.resolved) walked;
          deps = builtins.concatLists (map (v: v.deps) walked);
        }
      else
        { resolved = val; deps = []; };
  in walk resource;
```

`mkManifest` calls `resolveRefs` before serialization:

```nix
mkManifest = resource:
  let
    r = resolveRefs resource;
    # r.resolved = clean attrset (strings where refs were)
    # r.deps     = [ clusterRole, sa, ... ] (the actual objects)
  in
  yamlFormat.generate "..." (removeNulls r.resolved);
```

### Why this is better than `_deps`

- **Single source of truth.** The ref in `roleRef.name` IS the dependency. No separate
  bookkeeping. Can't have a reference without a dependency edge.
- **Can't get out of sync.** If you put `ref clusterRole`, it's both the K8s name and
  the dependency. If you put a plain string, there's no dep — and that's correct
  (it's an external reference).
- **Mixed refs and plain strings work naturally.** External resources (system ClusterRoles,
  default SA) stay as plain strings. `resolveRefs` passes strings through untouched.
  Only kix-managed references use `ref`.

### Implementation scope

1. `ref` constructor — 1 line
2. `resolveRefs` tree walker — ~25 lines
3. Update builders to use `ref` instead of `.metadata.name` — ~15 call sites, mechanical
4. Update `mkManifest` to call `resolveRefs` — small change
5. Expose deps in the module system (e.g., alongside `config.manifests`)

### Open questions

- **Where do deps live in the module system?** `config.manifests` stores raw attrsets
  (pre-serialization), so refs are still `{ _ref = ... }`. Resolution needs to happen
  at both the module level (for validation/graph) and at serialization (for YAML).
  Or: resolve once, store both resolved data and deps.

- **Intermediate consumers.** Anything that reads `resource.roleRef.name` expecting a
  string will get `{ _ref = ... }` instead. Preprocessors, `validateManifestSet`, and
  any code that inspects field values needs to either work with refs or run after
  resolution. `validateManifestSet` would actually get *simpler* (walk deps instead of
  parsing strings), but preprocessors need auditing.

- **ref to what?** Currently `ref` wraps the full resource attrset. Should it wrap
  something lighter (just kind + name + namespace)? Full attrset means the dep graph
  carries the entire resource tree — powerful for introspection but potentially
  memory-heavy for large clusters. Lazy eval mitigates this (Nix won't evaluate
  fields you don't access).

## Key Insight

The dependency information exists at the **call site** of every builder that accepts
another resource. `mkClusterRoleBinding clusterRole sa` knows both references. The
architecturally sound approach is to preserve that information structurally — not
discard it and recover it later by parsing strings.

Original kix got this right (store path = name = dependency). The only thing wrong
was the naming. Typed references fix the naming while preserving the single source
of truth.
