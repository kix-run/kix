# Package-Level Fixpoint: Resources as Derivations

## Working Document — March 2026

**Scope:** The inner fixpoint implementation — `mkResource`, `mkPackage`, `withRequires`, closure computation, the registry, and the post-processor. This is the technically deepest part of the v2 design.

**Predecessor:** v1 implementation in `lib/fixpoint/` (refs.nix, resolve.nix, resource.nix, package.nix, closure.nix)

---

## 1. What v1 Does and Why It Needs to Change

The v1 inner fixpoint works. Valkey, CoreDNS, cert-manager, and 10+ other packages are migrated and running. The problem is ergonomics and conceptual overhead:

```nix
# v1: tracked strings required everywhere
value = k8s.str [ "postgresql://" postgres.fqdn ":" postgres.out.port "/mydb" ];

# v2: native Nix interpolation
value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
```

v1 maintains a parallel dependency tracking system (~170 lines across refs.nix + resolve.nix) that reimplements what Nix's string context system already provides. The tree walker recursively visits every field of every resource spec, pattern-matching on `_type` tags. This works but has sharp edges:

- Forgetting `k8s.str` and using `${}` silently loses dependency tracking.
- The `resolve` function must know about every top-level K8s field (spec, data, subjects, roleRef, webhooks...) and handle each one explicitly.
- Refs are attrsets, which means they fail in contexts that expect plain strings (e.g., `builtins.toJSON` without resolution).

v2 eliminates this entire layer. Resources become derivations with store paths. `${}` interpolation *is* the tracking mechanism. The tree walker and refs disappear entirely.

---

## 2. `mkResource` Implementation

### 2.1 The Identity Derivation

Each K8s resource needs a store path that Nix's string context system can track. The store path's hash must change when the resource content changes (the Merkle DAG property).

```nix
mkResource =
  { apiVersion, kind, name, namespace ? "default"
  , labels ? {}, annotations ? {}, spec ? {}, data ? {}
  , stringData ? {}, rules ? null, subjects ? null
  , roleRef ? null, webhooks ? null
  , outputs ? {}, requires ? [], extraDeps ? []
  , extra ? {}
  }:
  let
    # Namespace key for the store path name (human-readable)
    nsKey = if namespace == null then "cluster" else namespace;

    # The manifest attrset — this is what eventually becomes YAML.
    # At this stage, strings contain store paths of referenced resources.
    manifest =
      { inherit apiVersion kind; }
      // { metadata = { inherit name; }
           // (if namespace != null then { inherit namespace; } else {})
           // lib.optionalAttrs (labels != {}) { inherit labels; }
           // lib.optionalAttrs (annotations != {}) { inherit annotations; };
         }
      // lib.optionalAttrs (spec != {}) { inherit spec; }
      // lib.optionalAttrs (data != {}) { inherit data; }
      // lib.optionalAttrs (stringData != {}) { inherit stringData; }
      // lib.optionalAttrs (rules != null) { inherit rules; }
      // lib.optionalAttrs (subjects != null) { inherit subjects; }
      // lib.optionalAttrs (roleRef != null) { inherit roleRef; }
      // lib.optionalAttrs (webhooks != null) { inherit webhooks; };

    fullManifest = lib.recursiveUpdate manifest extra;

    # Serialize the manifest to JSON for content hashing.
    # This string carries the context of all referenced resources
    # (their store paths appear in spec values via ${} interpolation).
    manifestJson = builtins.toJSON fullManifest;

    # The identity derivation. Its hash depends on:
    #   1. The resource's own content (kind, name, namespace, spec, data, ...)
    #   2. All referenced resources (their store paths appear in manifestJson)
    #
    # builtins.toFile content-addresses on the file content. Since manifestJson
    # contains store paths of dependencies, the hash changes when any dependency
    # changes — this is the Merkle DAG.
    #
    # LIMITATION: builtins.toFile can only reference other toFile paths, not
    # real derivations. If specs ever embed store paths from real Nix packages
    # (e.g., Nix-built container images), this must become a derivation{}.
    # See section 2.2 for the derivation{} variant.
    _identityPath = builtins.toFile
      "k8s-${kind}-${nsKey}-${name}"
      manifestJson;

    # Attach context helper: makes a plain value carry this resource's
    # store path in its string context, so ${resource.fqdn} tracks the dep.
    attachCtx = value:
      let
        ctx = builtins.getContext "${_identityPath}";
        str = if builtins.isString value then value else toString value;
      in builtins.appendContext str ctx;

    self = {
      _type = "k8s-resource";
      inherit apiVersion kind name namespace;
      inherit requires extraDeps;

      # The store path. ${resource} in a string → this path gets embedded,
      # Nix tracks the context, post-processor replaces with K8s name.
      outPath = _identityPath;
      inherit _identityPath;

      # Fully qualified DNS name — the actual value the consumer needs.
      # Carries this resource's context so the dependency is tracked.
      fqdn = attachCtx "${name}.${nsKey}.svc.cluster.local";

      # Named outputs — each carries this resource's context.
      out = lib.mapAttrs (_: v: attachCtx v) outputs;

      # The raw manifest (with store paths, pre-post-processing).
      inherit manifest;
      rawManifest = fullManifest;

      # Registry entry: maps this resource's store path to its metadata.
      # The cluster collects these to build the full registry.
      registryEntry = {
        ${_identityPath} = {
          inherit apiVersion kind name namespace;
        };
      };
    };
  in self;
```

### 2.2 Why `builtins.toFile` Works (and When It Does Not)

`builtins.toFile` is content-addressed: identical content produces identical store paths. It can reference other `toFile` paths in its content. Since all K8s resources are themselves `toFile` paths, cross-resource references work.

The limitation: `builtins.toFile` cannot reference store paths from real derivations (Nix packages). If a K8s spec ever contains `image = "${pkgs.myApp}/bin/server"` — a path from a real derivation — then `builtins.toFile` fails with an error about disallowed references.

**When this matters:** Nix-built container images. If the workflow is `nix build .#myAppImage` followed by pushing to a registry and referencing the tag as a plain string (`image = "registry/myapp:abc123"`), then `toFile` is sufficient. If the workflow embeds the store path directly in the spec, we need `derivation{}`.

The `derivation{}` fallback:

```nix
_identityPath = derivation {
  name = "k8s-${kind}-${nsKey}-${name}";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "echo -n '${manifestJson}' > $out" ];
  # manifestJson contains all store paths → they become inputDrvs automatically
};
```

This is heavier (requires a builder, creates a `.drv` file) but handles arbitrary store path references. The recommendation in the design doc is to start with `toFile` and switch to `derivation` if/when Nix-built images become a use case.

**A middle path** exists: use `toFile` for the identity path but include a separate `_extraInputs` list of real derivation paths, and manually add their context via `appendContext`. This keeps `toFile` for hashing while still tracking non-toFile dependencies. However, this reintroduces manual tracking, which defeats the purpose.

### 2.3 What Goes Into the Hash

The `manifestJson` string contains the full serialized resource. This means the hash reflects:

| Included | Why |
|---|---|
| `apiVersion`, `kind`, `name`, `namespace` | Resource identity |
| `spec`, `data`, `stringData`, `labels`, `annotations` | Resource content |
| Store paths of all referenced resources | Merkle DAG: change propagation |
| `extra` fields (webhooks, volumeClaimTemplates) | Full manifest fidelity |

| NOT included | Why |
|---|---|
| `requires` list | These are resource *objects*, not serializable values. They affect closure but not the manifest content. |
| `extraDeps` list | Same — ordering-only, not in the manifest. |
| `outputs` map | Outputs are metadata about the resource, not part of the K8s manifest. |
| `_type` tag | Internal kixpkgs metadata. |

The key insight: `requires` and `outputs` do NOT change the derivation hash. A resource with `requires = [ self.pdb ]` has the same hash as one without (assuming the manifest is otherwise identical). This is correct — `requires` is a closure-level concern (what to deploy together), not a content concern (what the YAML looks like).

### 2.4 Outputs and `builtins.appendContext`

Outputs let consumers access resource-specific values (port numbers, claim names) while preserving dependency tracking.

```nix
# Resource definition
service = mkResource {
  kind = "Service";
  name = "postgres";
  namespace = "data";
  outputs = { port = "5432"; };
  spec.ports = [{ port = 5432; targetPort = 5432; }];
};

# Consumer
env.DATABASE_URL = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
```

When `mkResource` processes `outputs = { port = "5432"; }`, it creates:

```nix
out.port = builtins.appendContext "5432" (builtins.getContext "${_identityPath}");
```

The result is the string `"5432"` that carries invisible context tying it back to the Service derivation. When this string gets interpolated into another resource's spec, Nix's string machinery propagates the context. The consuming resource's `manifestJson` will contain `"5432"` (not the store path) but will carry the context of `postgres.service`'s identity path.

This is the critical difference from v1: in v1, `postgres.out.port` is an attrset `{ _type = "k8s-ref"; resource = ...; value = 5432; }` that the tree walker must find. In v2, it is a plain string that Nix handles natively.

**Integer outputs:** `builtins.appendContext` only works on strings. Output values must be strings (or coerced to strings). For `port = 5432` (an integer), `mkResource` should `toString` it: `attachCtx (toString v)`. Consumers who need the integer back (rare — see section 7 of the design doc on the non-string problem) use `extraDeps` for explicit tracking and the plain integer value.

### 2.5 `fqdn` — The Derived Output

`fqdn` is a convenience output computed from the resource's name and namespace:

```nix
fqdn = attachCtx "${name}.${namespace}.svc.cluster.local";
```

This is the value consumers typically need for cross-namespace references. It is a real DNS name (not a store path), so it does NOT need post-processing. The post-processor only replaces store paths; `fqdn` values pass through unchanged.

The difference between `${resource}` and `${resource.fqdn}`:

| Expression | Produces | Needs post-processing? |
|---|---|---|
| `${postgres.service}` | `/nix/store/abc...-k8s-Service-data-postgres` | Yes → replaced with `"postgres"` |
| `${postgres.service.fqdn}` | `"postgres.data.svc.cluster.local"` | No — already a real value |
| `${postgres.service.out.port}` | `"5432"` | No — already a real value |

Use `${resource}` for same-namespace name references (configMapRef.name, serviceAccountName). Use `${resource.fqdn}` for cross-namespace or DNS-qualified references. Use `${resource.out.X}` for specific output values.

---

## 3. `mkPackage` Implementation

### 3.1 The Inner Fixpoint

`mkPackage` wraps the resource definitions in a fixpoint, so resources can reference each other via `self`:

```nix
mkPackage = packageFn: defaults:
  let
    parts = lib.fix (packageFn defaults);
  in
  parts // {
    _type = "k8s-package";

    # Main — the public interface
    main = parts.main or (throw "Package must define a 'main' resource");

    # Convenience shortcuts
    ref = parts.main;          # ${pkg.ref} → main resource's store path
    out = parts.main.out;      # pkg.out.port → main resource's port output
    fqdn = parts.main.fqdn;   # pkg.fqdn → main resource's FQDN

    # Closure rooted at main
    closure = computeClosure parts.main;

    # Per-package registry: union of all resources' registry entries
    registry = lib.foldl' (acc: r: acc // r.registryEntry)
      {}
      (builtins.filter (v: builtins.isAttrs v && (v._type or "") == "k8s-resource")
        (builtins.attrValues parts));

    # Override mechanisms
    overrideParts = overrideFn:
      mkPackage (args: self:
        let base = packageFn args self;
        in base // (overrideFn self base)
      ) defaults;

    override = newArgs: mkPackage packageFn (defaults // newArgs);
  };
```

### 3.2 How `lib.fix` Composes with `mkResource`

The fixpoint evaluates lazily. When `self.configmap` is referenced in the deployment's spec, Nix evaluates the `configmap` attribute, which calls `mkResource` and returns a resource attrset with an `outPath`. The deployment's spec then contains `${self.configmap}` — the configmap's store path — which gets embedded in the deployment's `manifestJson`, creating the dependency link.

```nix
# Inside a package function:
args: self: {
  configmap = mkResource {
    kind = "ConfigMap";
    name = "postgres-config";
    data = { "postgresql.conf" = "max_connections=100"; };
  };

  deployment = mkResource {
    kind = "Deployment";
    name = "postgres";
    spec.template.spec.volumes = [{
      configMap.name = "${self.configmap}";
      # ↑ Forces evaluation of self.configmap via the fixpoint.
      #   Nix creates the configmap's identity path, gets its store path,
      #   embeds it in this string, and records it in the string's context.
    }];
  };
}
```

The fixpoint ensures that:
1. Resources can be defined in any order.
2. Circular references between resources are possible (Nix's laziness handles this, as long as the cycle is in attribute access, not in value computation).
3. Adding/removing/modifying one resource automatically propagates to everything that references it.

### 3.3 The Package Interface

A package exposes:

```nix
postgres = {
  # --- Resources (from the fixpoint) ---
  configmap    = <resource>;    # Resource with outPath, fqdn, out, manifest, ...
  deployment   = <resource>;
  service      = <resource>;
  pvc          = <resource>;

  # --- Package metadata ---
  _type        = "k8s-package";

  # --- Public interface ---
  main         = <resource>;    # The "entry point" — usually a Service with requires
  ref          = <resource>;    # Shortcut: pkg.ref = pkg.main (for ${pkg.ref} in specs)
  out          = { ... };       # Shortcut: pkg.out = pkg.main.out
  fqdn         = "...";        # Shortcut: pkg.fqdn = pkg.main.fqdn

  # --- Closure ---
  closure      = [ ... ];       # All resources transitively reachable from main

  # --- Registry ---
  registry     = { ... };       # store path → resource metadata, for all resources

  # --- Override ---
  overrideParts = fn: <package>;
  override      = args: <package>;
};
```

Consumers interact with the package at the resource level:

```nix
# Cross-package reference (from the outer fixpoint):
env.DATABASE_URL = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";

# Or via the main shortcut:
env.DATABASE_URL = "postgresql://${postgres.fqdn}:${postgres.out.port}/mydb";
```

### 3.4 `overrideParts` — the `self: super:` Pattern

Identical to v1. The override function receives the NEW fixpoint (`self`) and the ORIGINAL parts (`super`):

```nix
myPostgres = postgres.overrideParts (self: super: {
  # Replace the deployment with a StatefulSet, keeping everything else
  deployment = mkResource {
    kind = "StatefulSet";
    name = "postgres";
    spec.template.spec.volumes = [{
      configMap.name = "${self.configmap}";  # self = new fixpoint
      # ↑ If another override also modifies configmap, this picks up the
      #   modified version. That's the fixpoint property.
    }];
  };
  # super.configmap, super.service, etc. carry over automatically
});
```

The inner fixpoint re-resolves: if the new StatefulSet references `self.configmap`, it gets whatever `configmap` is in the new fixpoint (which might also be overridden). This is the same property that makes nixpkgs overlays powerful.

### 3.5 The Per-Package Registry

Each package collects `registryEntry` from all its resources into a single `registry` attrset:

```nix
registry = {
  "/nix/store/abc123-k8s-ConfigMap-data-postgres-config" = {
    apiVersion = "v1"; kind = "ConfigMap"; name = "postgres-config"; namespace = "data";
  };
  "/nix/store/def456-k8s-Deployment-data-postgres" = {
    apiVersion = "apps/v1"; kind = "Deployment"; name = "postgres"; namespace = "data";
  };
  # ...
};
```

The cluster merges all package registries into a single cluster-wide registry. This registry serves two purposes:

1. **Post-processing:** Replace store paths with K8s names in serialized manifests.
2. **Dep extraction:** Distinguish K8s resource store paths from other store paths (Nix packages, toFile artifacts) when computing dependencies via `builtins.getContext`.

---

## 4. `withRequires` — Inverted Dependencies

### 4.1 What It Does

`withRequires` adds inverted dependencies to an existing resource and recomputes the closure. It does NOT create a new derivation — it wraps the existing resource attrset with additional `requires` entries.

```nix
# The service IS the main resource. But deploying it requires the deployment.
main = withRequires [ self.deployment self.configmap ] self.service;
```

### 4.2 Implementation

```nix
withRequires = additionalRequires: resource:
  let
    newSelf = resource // {
      requires = (resource.requires or []) ++ additionalRequires;
      # Closure is NOT stored on the resource in v2.
      # It is computed at query time from the registry + getContext.
      # See section 5.
    };
  in newSelf;
```

Key differences from v1:

- **Same derivation identity.** `withRequires` does NOT change the resource's `_identityPath` or `outPath`. The hash stays the same. This is correct: `requires` is a deployment concern (what to deploy together), not a content concern (what the YAML says).
- **Same `manifest`.** The manifest is unchanged — `requires` does not appear in the YAML.
- **Different closure.** The closure starting from this resource is larger because it includes the `requires` targets and their transitive deps.

### 4.3 How `requires` Propagates

`requires` is transitive. When computing the closure, the algorithm follows both `deps` (from `getContext` — resources whose store paths appear in the manifest) and `requires` (manual inverted deps):

```
self.service
  ├─ deps: [] (service spec has no cross-resource refs in this example)
  ├─ requires: [self.deployment, self.configmap]
  │
  ├─ self.deployment
  │    ├─ deps: [self.configmap, self.pvc] (from ${} in spec)
  │    ├─ requires: [self.pdb, self.serviceAccount]
  │    │
  │    ├─ self.pdb (leaf)
  │    ├─ self.serviceAccount
  │    │    └─ requires: [self.clusterRoleBinding]
  │    │         └─ deps: [self.clusterRole, self.serviceAccount]
  │    ...
  │
  └─ self.configmap (leaf — already visited, deduplicated)
```

The closure algorithm is unchanged from v1. The only difference is HOW `deps` is computed: v1 uses the tree walker result stored on the resource; v2 uses `builtins.getContext` on the manifest JSON at closure-computation time.

### 4.4 Why `requires` Cannot Be Replaced by Native Tracking

`requires` captures inverted relationships — "I need X, but X references me, not the other way around."

Example: A ServiceAccount needs its ClusterRoleBinding to function. But in the YAML, the ClusterRoleBinding references the ServiceAccount (by name), not the other way around. The ServiceAccount's spec contains no reference to the binding.

Native `${}` tracking only captures forward references (A's spec contains B's store path → A depends on B). It cannot capture: "B references A, therefore A semantically depends on B."

`requires` is the one piece of manual annotation that survives from v1. It is unavoidable because it encodes semantic domain knowledge that no amount of static analysis can infer from the YAML structure alone.

---

## 5. Closure Computation

### 5.1 The Algorithm

Unchanged from v1 — BFS traversal following both `deps` and `requires`, deduplicating by identity key (`kind/name@namespace`).

The difference is where `deps` comes from:

| v1 | v2 |
|---|---|
| `resource.deps` — list of resource objects, computed by the tree walker at resource construction time | Computed lazily from `builtins.getContext(manifestJson)` filtered through the registry |

### 5.2 Computing `deps` from `getContext`

```nix
# Given a resource and the cluster registry:
resourceDeps = registry: resource:
  let
    ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
    allPaths = builtins.attrNames ctx;
    k8sPaths = builtins.filter (p: builtins.hasAttr p registry) allPaths;
  in
  map (p: registry.${p}.resource) k8sPaths;
```

`builtins.getContext` returns an attrset mapping store paths to their context type. We filter to paths that appear in the registry (K8s resources), discarding any other store paths (Nix packages, arbitrary `toFile` artifacts that might appear in the manifest).

### 5.3 When Does This Run?

```
Evaluation timeline:

1. Inner fixpoints resolve
   - mkResource creates identity paths (builtins.toFile)
   - ${self.configmap} in specs embeds store paths
   - Each resource has _identityPath, manifest, registryEntry

2. Outer fixpoint resolves
   - Packages wired together (DI: postgres injected into myApp)
   - ${postgres.service.fqdn} in myApp's deployment spec
   - Cross-package store paths tracked automatically

3. Registry built
   - Union of all packages' registryEntry maps
   - Maps every K8s resource store path to its metadata

4. Deps computed (lazy — only when closure is queried)
   - builtins.getContext on manifestJson
   - Filter through registry → resource-level deps

5. Closures computed
   - BFS from main, following deps + requires
   - Deduplicated by identity key

6. Post-processing
   - Replace store paths with K8s names
   - Serialize to YAML
```

Steps 4-5 happen lazily. If you only query `myApp.main.closure`, only myApp's deps are computed (plus transitively reachable resources). Unused packages are never traversed.

### 5.4 Where Deps Are Computed: Cluster-Level vs. Package-Level

The design doc identifies three options. The recommended approach for v2 is **cluster-level computation** (option 1 from section 9.3 of the design doc):

Resources carry `rawManifest` but NOT `deps`. The cluster evaluator computes deps for all queried resources using the full cluster registry. This is simplest and avoids threading a registry through the fixpoint.

The implication: `resource.deps` is NOT an attribute on the resource object (unlike v1). Instead, closure computation takes the registry as an argument:

```nix
computeClosure = registry: root:
  let
    getDeps = resource:
      let
        ctx = builtins.getContext (builtins.toJSON resource.rawManifest);
        allPaths = builtins.attrNames ctx;
        k8sPaths = builtins.filter (p: builtins.hasAttr p registry) allPaths;
      in map (p: registry.${p}) k8sPaths;

    go = { seen, order, queue }:
      if queue == [] then order
      else let
        head = builtins.head queue;
        rest = builtins.tail queue;
        ns = if head.namespace or null == null then "_cluster_" else head.namespace;
        id = "${head.kind}/${head.name}@${ns}";
      in
      if builtins.hasAttr id seen then
        go { inherit seen order; queue = rest; }
      else
        go {
          seen = seen // { ${id} = true; };
          order = order ++ [ head ];
          queue = rest ++ (getDeps head) ++ (head.requires or []);
        };
  in go { seen = {}; order = []; queue = [ root ]; };
```

This means `pkg.closure` needs the registry. The package-level `closure` attribute could be a function (`pkg.closure registry`) or the cluster evaluator computes it externally. The latter is cleaner — packages don't need to know about the registry.

**Alternative: embed deps on the resource.** If `computeClosure` takes a registry argument, then the nice `resource.closure` API from v1 is lost. Users would need to call `cluster.closureOf resource` instead of `resource.closure`. This is a real ergonomic tradeoff.

A compromise: the package receives a `_registry` via the outer fixpoint (the cluster passes it in), and `computeClosure` is bound at package construction time:

```nix
# In mkCluster, after all packages are built:
finalPkgs = mapAttrs (name: pkg:
  pkg // {
    closure = computeClosure clusterRegistry pkg.main;
    closureOf = resource: computeClosure clusterRegistry resource;
  }
) rawPkgs;
```

This preserves the `pkg.closure` API while keeping the registry at the cluster level.

---

## 6. The Post-Processor

### 6.1 Purpose

Manifests contain store paths like `/nix/store/abc123-k8s-ConfigMap-data-postgres-config` where K8s expects `"postgres-config"`. Before serializing to YAML, these must be replaced.

### 6.2 Implementation

```nix
postProcessManifest = registry: manifest:
  let
    json = builtins.toJSON manifest;
    ctx = builtins.getContext json;
    allPaths = builtins.attrNames ctx;
    k8sPaths = builtins.filter (p: builtins.hasAttr p registry) allPaths;

    replaced = builtins.replaceStrings
      k8sPaths
      (map (p: registry.${p}.name) k8sPaths)
      json;

    # After replacement, the context is stale (store paths are gone from
    # the string content but still in the context). Discard it.
    clean = builtins.unsafeDiscardStringContext replaced;
  in
  builtins.fromJSON clean;
```

### 6.3 Edge Cases

**Substring replacement.** `"postgresql://${postgres.service}:5432/mydb"` becomes `"postgresql:///nix/store/...:5432/mydb"` at the Nix level. `replaceStrings` does substring matching, so this correctly becomes `"postgresql://postgres:5432/mydb"`. But this is almost always wrong — you want the FQDN for connection strings, not the short name. The solution is convention: use `${resource.fqdn}` for connection strings, `${resource}` only for same-namespace name refs.

**Non-K8s store paths.** If `image = "${pkgs.myApp}/bin/server"` appears in a spec, the `pkgs.myApp` store path is in the context but NOT in the registry. The filter `builtins.filter (p: builtins.hasAttr p registry) allPaths` skips it. `replaceStrings` only replaces known K8s paths. The unknown store path remains in the JSON. This is a problem — you do not want literal `/nix/store/...` paths in your K8s manifests.

Two mitigations:
1. **Convention:** Container images are always specified as plain strings (`image = "myapp:v2.1.0"`), not Nix derivation paths. This is the common case.
2. **Validation:** The post-processor can warn/error if the output JSON still contains `/nix/store/` substrings after replacement.

**Integer fields.** `builtins.toJSON` turns integers into JSON numbers. Store paths only appear in JSON strings. So `spec.replicas = 3` is never affected by the post-processor. The issue is only with cross-resource integer references, which are covered by `extraDeps` (section 7 of the design doc).

**Deeply nested store paths.** Store paths can appear anywhere in the JSON: inside list elements, nested attrset values, annotation values. Since `replaceStrings` operates on the entire JSON string, nesting depth is irrelevant. This is a significant simplification over v1's tree walker, which must know the structure.

### 6.4 The `builtins.unsafeDiscardStringContext` Question

After `replaceStrings`, the string no longer contains store paths as substrings, but it still carries their context (context is metadata, not content). `builtins.unsafeDiscardStringContext` strips this context.

The "unsafe" is about Nix's build system — discarding context means Nix won't track the dependency for build purposes. Since we are not building these manifests (they are eval-time data), this is safe. The context has served its purpose (dependency tracking and registry lookup), and the resulting clean JSON is ready for YAML serialization.

---

## 7. Concrete Example: Postgres Package in v2

```nix
# pkgs/postgres.nix
{ k8s, lib }:

k8s.mkPackage
  ({ namespace ? "data"
   , storage ? "100Gi"
   , version ? "16"
   , image ? "postgres:${version}"
   , clusterDomain ? "cluster.local"
   , ...
   }:
   self: let
     fqdn = name: "${name}.${namespace}.svc.${clusterDomain}";
   in {

    configmap = k8s.mkResource {
      apiVersion = "v1"; kind = "ConfigMap";
      name = "postgres-config"; inherit namespace;
      labels = { "app" = "postgres"; };
      data = {
        "postgresql.conf" = ''
          max_connections = 100
          shared_buffers = 256MB
        '';
      };
    };

    secret = k8s.mkResource {
      apiVersion = "v1"; kind = "Secret";
      name = "postgres-credentials"; inherit namespace;
      labels = { "app" = "postgres"; };
      stringData = {
        POSTGRES_USER = "postgres";
        # In practice, this would come from a sealed secret or external secret operator
        POSTGRES_PASSWORD = "changeme";
      };
    };

    pvc = k8s.mkResource {
      apiVersion = "v1"; kind = "PersistentVolumeClaim";
      name = "postgres-data"; inherit namespace;
      labels = { "app" = "postgres"; };
      spec = {
        accessModes = [ "ReadWriteOnce" ];
        resources.requests.storage = storage;
      };
    };

    serviceAccount = k8s.mkResource {
      apiVersion = "v1"; kind = "ServiceAccount";
      name = "postgres"; inherit namespace;
      labels = { "app" = "postgres"; };
    };

    deployment = k8s.mkResource {
      apiVersion = "apps/v1"; kind = "Deployment";
      name = "postgres"; inherit namespace;
      labels = { "app" = "postgres"; };
      # Manual: deployment needs the PDB, but the PDB selector points at the deployment's pods
      requires = [ self.pdb self.serviceAccount ];
      spec = {
        replicas = 1;
        selector.matchLabels = { "app" = "postgres"; };
        template = {
          metadata.labels = { "app" = "postgres"; };
          spec = {
            serviceAccountName = "${self.serviceAccount}";
            containers = [{
              name = "postgres";
              inherit image;
              ports = [{ containerPort = 5432; }];
              envFrom = [{ secretRef.name = "${self.secret}"; }];
              volumeMounts = [
                { name = "data"; mountPath = "/var/lib/postgresql/data"; }
                { name = "config"; mountPath = "/etc/postgresql/postgresql.conf"; subPath = "postgresql.conf"; }
              ];
            }];
            volumes = [
              { name = "data"; persistentVolumeClaim.claimName = "${self.pvc}"; }
              { name = "config"; configMap.name = "${self.configmap}"; }
            ];
          };
        };
      };
    };

    pdb = k8s.mkResource {
      apiVersion = "policy/v1"; kind = "PodDisruptionBudget";
      name = "postgres"; inherit namespace;
      labels = { "app" = "postgres"; };
      spec = {
        maxUnavailable = 1;
        selector.matchLabels = { "app" = "postgres"; };
      };
    };

    service = k8s.mkResource {
      apiVersion = "v1"; kind = "Service";
      name = "postgres"; inherit namespace;
      labels = { "app" = "postgres"; };
      outputs = { port = "5432"; };
      spec = {
        selector = { "app" = "postgres"; };
        ports = [{ port = 5432; targetPort = 5432; }];
      };
    };

    # Main: Service is the public interface, requires pulls in everything else
    main = k8s.withRequires [ self.deployment self.configmap self.secret ] self.service;
  })
  { namespace = "data"; };
```

### 7.1 What Changes From v1

| v1 | v2 |
|---|---|
| `configMap.name = self.configmap.ref;` | `configMap.name = "${self.configmap}";` |
| `serviceAccountName = self.serviceAccount.ref;` | `serviceAccountName = "${self.serviceAccount}";` |
| `k8s.str [ "postgresql://" db.fqdn ":" db.out.port "/mydb" ]` | `"postgresql://${db.fqdn}:${db.out.port}/mydb"` |
| `outputs` values are `mkRef` attrsets | `outputs` values are strings with `appendContext` |
| `resource.deps` — computed by tree walker | Computed from `getContext` at closure time |
| `resource.closure` — computed eagerly at construction | Computed lazily, needs registry |

### 7.2 Consumer Using This Package

```nix
# pkgs/my-app.nix
{ k8s, lib }:

k8s.mkPackage
  ({ namespace ? "production", postgres, ... }:
   self: {

    deployment = k8s.mkResource {
      apiVersion = "apps/v1"; kind = "Deployment";
      name = "myapp"; inherit namespace;
      spec.template.spec.containers = [{
        name = "app";
        image = "myapp:v2.1.0";
        env = [
          { name = "DATABASE_URL";
            # Native interpolation — Nix tracks dep on postgres.service
            value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
          }
          { name = "DATABASE_NAME";
            # ${postgres.service} → store path, post-processed to "postgres"
            # But this is unusual — you'd normally use the FQDN or a hardcoded name
            value = "${postgres.service}";
          }
        ];
      }];
    };

    service = k8s.mkResource {
      apiVersion = "v1"; kind = "Service";
      name = "myapp"; inherit namespace;
      outputs = { port = "8080"; };
      spec = {
        selector = { "app" = "myapp"; };
        ports = [{ port = 8080; targetPort = 8080; }];
      };
    };

    main = k8s.withRequires [ self.deployment ] self.service;
  })
  { namespace = "production"; };
```

---

## 8. Migration from v1 Valkey

To illustrate the concrete diff, here is how the valkey package's key patterns change:

```nix
# v1: refs in volume definitions
startScriptsVolume = {
  name = "start-scripts";
  configMap = {
    name = self.scriptsCm.ref;         # ← mkRef attrset
    defaultMode = 493;
  };
};

# v2: native interpolation
startScriptsVolume = {
  name = "start-scripts";
  configMap = {
    name = "${self.scriptsCm}";        # ← store path, post-processed to K8s name
    defaultMode = 493;
  };
};
```

```nix
# v1: ref in spec field
spec.serviceName = self.headlessSvc.ref;

# v2: native interpolation
spec.serviceName = "${self.headlessSvc}";
```

```nix
# v1: ref in HPA scaleTargetRef
spec.scaleTargetRef.name = if sentinel.enabled then self.sentinelSs.ref else self.replicaSs.ref;

# v2: native interpolation
spec.scaleTargetRef.name =
  if sentinel.enabled then "${self.sentinelSs}" else "${self.replicaSs}";
```

The `requires` lists are unchanged — they were already resource objects, not refs.

The `outputs` definitions are unchanged in syntax but different in semantics:

```nix
# v1: outputs become mkRef attrsets
outputs = { redisPort = 6379; sentinelPort = 26379; };
# → self.sentinelSvc.out.redisPort is { _type = "k8s-ref"; resource = ...; value = 6379; }

# v2: outputs become context-carrying strings
outputs = { redisPort = "6379"; sentinelPort = "26379"; };
# → self.sentinelSvc.out.redisPort is "6379" with sentinelSvc's context attached
```

Note the string coercion: v2 outputs must be strings (for `appendContext`). Consumers who used `port = 6379` as an integer now get `port = "6379"` as a string. For the `value` field of env vars, this is fine (env vars are always strings). For `spec.ports[].port` (which must be an integer in the manifest), the value is defined directly in the spec, not via a cross-resource reference — so no issue.

---

## 9. Open Design Questions

### 9.1 Registry Threading

The registry is cluster-level (needs all packages' registries merged), but `computeClosure` needs the registry. This creates a bootstrapping question:

- **Option A:** Packages don't have `.closure` — the cluster provides `cluster.closureOf(resource)`. Simpler but less ergonomic.
- **Option B:** The cluster injects the merged registry back into packages after construction (second pass). More ergonomic but requires re-wrapping package attrsets.
- **Option C:** The registry is built lazily from the outer fixpoint. Packages receive `self._registry` from the cluster fixpoint. Elegant but requires the inner fixpoint to reference the outer fixpoint's result.

Option B is recommended. It preserves the v1 API (`pkg.closure`, `resource.closure`) and the second pass is cheap (just attrset merging, no re-evaluation).

### 9.2 `toFile` vs. `derivation` — When to Decide

Start with `toFile`. If a concrete use case emerges for embedding real derivation store paths in K8s specs (Nix-built container images, Nix-built config files baked into images), switch to `derivation`. The switch is local to `mkResource` — no other code changes.

A middle ground: `mkResource` checks whether `manifestJson` contains any non-`toFile` store path references (by checking `builtins.getContext` for entries with `{ allOutputs = true; }` which indicates a real derivation). If it does, use `derivation`; otherwise use `toFile`. This auto-selects the lightweight path when possible.

### 9.3 Namespace Resources in the Identity Path

In v1, namespace is a plain string. In the design docs, namespaces are first-class resources. If `namespace` is a resource (with its own store path), then `inherit namespace` in the manifest embeds a store path where K8s expects a string.

Resolution: the manifest uses the namespace *name* (string), not the namespace *resource*. But the resource tracks a dependency on the namespace resource via `extraDeps` or by referencing `${namespaceResource}` somewhere in the manifest. This needs explicit design — the namespace resource dependency is implicit in v1 (namespace strings don't track deps) and needs to become explicit in v2.

### 9.4 Output Type Safety

v2 outputs are strings. An output `port = "5432"` is fine in `env.value` (string context) but wrong in `spec.ports[].port` (needs integer). v1 has the same issue — `mkRef` stores the raw value and `resolve` returns it as-is, which works for both strings and integers.

In v2, `attachCtx` coerces to string, so `port = "5432"` is always a string. The design doc's `extraDeps` pattern handles the rare case where you need an integer output from another resource:

```nix
spec.backend.service.port.number = postgres.service.out.portInt;  # plain integer, no tracking
extraDeps = [ postgres.service ];                                   # manual dep tracking
```

This means outputs could have two variants: `out.port` (string with context, for interpolation) and `out.portInt` (plain integer, for direct use in integer fields). Or just document that `extraDeps` is the way to handle integer cross-refs.

### 9.5 Performance of `builtins.toJSON` + `builtins.getContext`

Every `mkResource` call serializes the full manifest to JSON (for hashing). For large resources (valkey's sentinel StatefulSet with its long container specs), this is a non-trivial string. In v1, the tree walker only visits the spec — it skips container images, probe configs, and other constants that have no refs.

In v2, `builtins.toJSON` serializes everything, and `builtins.getContext` extracts context from the full string. This is almost certainly fine — JSON serialization is fast, and `getContext` is O(number of context entries) not O(string length). But it is worth benchmarking on the valkey package (the largest package in the repo) to confirm.

---

## 10. Summary of Implementation Surface

### New code needed:

| Component | Lines (est.) | Purpose |
|---|---|---|
| `mkResource` (v2) | ~50 | Create identity path, attach context to outputs, build manifest |
| `postProcessManifest` | ~15 | Replace store paths with K8s names |
| Registry merging (in `mkCluster`) | ~10 | Union all packages' registries |
| `computeClosure` (v2) | ~30 | BFS with `getContext`-based dep extraction |

### Deleted code:

| Component | Lines | Replacement |
|---|---|---|
| `refs.nix` | ~65 | `outPath` + `builtins.appendContext` |
| `resolve.nix` | ~100 | `builtins.toJSON` + `builtins.getContext` |

### Unchanged code:

| Component | Why |
|---|---|
| `mkPackage` (structure) | Same `lib.fix` + `overrideParts` + `override` pattern |
| `withRequires` (concept) | Same semantic — adds inverted deps, unchanged |
| `applyOverlays` | Overlay mechanics are independent of tracking |
| `mkCluster` (structure) | Same outer fixpoint pattern |
| Package definitions (structure) | Same `args: self: { ... }` pattern, just `${}` instead of `.ref` |

### Per-package migration:

Each package needs:
1. Replace `.ref` with `"${...}"` in all specs
2. Replace `k8s.str [...]` with native string interpolation
3. Change integer outputs to string outputs
4. No other changes — `requires`, `main`, `overrideParts` usage is identical
