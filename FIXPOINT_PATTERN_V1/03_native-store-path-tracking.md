# Native Store Path Tracking: Resources as Derivations

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Predecessor:** `02_kixpkgs-design-doc.md` (custom ref/resolve system)

---

## 1. The Problem with Custom Tracking

The current fixpoint implementation (`lib/fixpoint/`) maintains a parallel dependency tracking system:

1. **`mkRef`** creates `{ _type = "k8s-ref"; resource; output; value; }` tagged attrsets
2. **`k8s.str`** wraps string concatenation to avoid losing ref metadata through `${}`
3. **`resolve`** is a recursive tree walker that pattern-matches on `_type` tags, extracts deps, and returns `{ resolved, deps }` tuples
4. **`mkResource`** calls `resolve` on every field (spec, data, annotations, rules, subjects, roleRef, webhooks), collects deps, and builds the resource

This works, but it's reimplementing what Nix already does natively. Nix strings carry invisible *context* — metadata recording which derivations produced parts of the string. When you write `"${openssl}/lib"`, Nix automatically:
- Substitutes `openssl.outPath` into the string
- Records `openssl` as a dependency in the string's context
- Propagates that context through all further string operations

We're building a shadow version of this in userspace, with worse ergonomics (`k8s.str` instead of `${}`).

---

## 2. The Core Idea: Resources ARE Derivations

Each K8s resource creates a Nix derivation. The derivation exists purely for identity — it's never built, never produces output files. But it has an `outPath`, which means:

- `${resource}` in any Nix string substitutes the store path AND records the dependency
- String context propagates automatically through `${}`, `+`, `lib.concatStrings`, etc.
- `builtins.getContext` on any string returns which derivations contributed to it
- No custom `_type` tags, no tree walker, no `k8s.str`

The store paths appear as placeholders in the intermediate manifest. A post-processing step replaces them with actual K8s names before serialization.

---

## 3. Three Approaches Considered

### 3A. All-In Store Paths

Every reference — name, fqdn, port, host — is a store path. Post-processing replaces them all.

```
${resource}          → /nix/store/abc123-k8s-Service-postgres       → "postgres"
${resource.fqdn}     → /nix/store/def456-k8s-Service-postgres-fqdn  → "postgres.data.svc.cluster.local"
${resource.out.port} → /nix/store/ghi789-k8s-Service-postgres-port  → "5432"
```

**Pro:** Conceptually pure. One mechanism for everything.
**Con:** Non-string values (integers like port numbers) become strings in the manifest JSON. `"port": "/nix/store/..."` → `"port": "5432"` (string, not int). K8s rejects this for fields requiring integers. The post-processor needs type awareness to emit `"port": 5432`.

### 3B. Hybrid: Store Paths for Names, `appendContext` for Outputs

Primary name references use `outPath` (store paths, post-processed). Outputs (port, fqdn, host) use `builtins.appendContext` to attach the resource's derivation context to the *actual value*, so they resolve to real values with invisible tracking.

```
${resource}          → /nix/store/abc123-k8s-Service-postgres       → post-processed to "postgres"
${resource.fqdn}     → "postgres.data.svc.cluster.local"            → already correct, context tracked
${resource.out.port} → "5432"                                       → already correct, context tracked
```

**Pro:** Post-processing only handles name references (the common case). Outputs carry real values. No type confusion.
**Con:** Two tracking mechanisms (outPath for names, appendContext for outputs). Slightly less "pure."

### 3C. Multi-Output Derivations

Each resource is a multi-output derivation where outputs map to K8s outputs:

```nix
drv = derivation {
  name = "k8s-Service-postgres";
  outputs = ["out" "fqdn" "port"];
  # ...
};
# ${drv}      → outPath (name)
# ${drv.fqdn} → /nix/store/...-k8s-Service-postgres-fqdn
# ${drv.port} → /nix/store/...-k8s-Service-postgres-port
```

**Pro:** Most "Nix-native." Uses the same mechanism Nix uses for `openssl.dev`, `openssl.lib`.
**Con:** Output names must be valid Nix identifiers (no hyphens). Requires actual `derivation` calls (heavier than `toFile`). Still has the integer-becomes-string problem from 3A. The context format is `{ drvPath: { outputs: ["port"] } }` — need to map drvPath→outPath for post-processing.

### Recommendation

**Approach 3B (hybrid)** strikes the best balance. It minimizes post-processing, preserves types for non-string outputs, and still eliminates `k8s.str` and the custom tree walker. The name reference (the most common cross-resource reference) uses native `outPath`. Outputs use `appendContext` which is still native Nix string context — just attached explicitly rather than through interpolation.

> **DECISION NEEDED:** Which approach do you prefer? 3A is purest but needs type-aware post-processing. 3B is practical. 3C is most Nix-native but heaviest.

---

## 4. Detailed Design (Approach 3B)

### 4.1 Identity Tokens: `builtins.toFile` vs `derivation`

Each resource needs a Nix store path for identity. Two options:

**`builtins.toFile`** (recommended):
```nix
identityPath = builtins.toFile "k8s-${kind}-${nsKey}-${name}" "${kind}/${nsKey}/${name}";
```
- Lightweight — no builder, no system, no build step
- Content-addressed (same inputs → same path → deduplication for free)
- Context format: `{ "/nix/store/<hash>-name" = { path = true; }; }` — context key equals the store path (simplifies post-processing)

**`derivation { ... }`**:
```nix
identityDrv = derivation {
  name = "k8s-${kind}-${nsKey}-${name}";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = ["-c" "echo -n '${name}' > $out"];
};
```
- Heavier — needs `system`, `builder`, etc.
- Context format: `{ "/nix/store/<hash>-name.drv" = { outputs = ["out"]; }; }` — context key is the `.drv` path, different from `outPath`. Need an extra mapping.
- More "correct" in the derivation analogy

`builtins.toFile` is recommended because:
1. Simpler context handling (key = path)
2. No dead weight (no builder, no system)
3. Content-addressed — same resource definition across packages deduplicates automatically
4. These are never built — the derivation machinery adds nothing

> **DECISION NEEDED:** Is `builtins.toFile` acceptable, or do you want actual `derivation` calls for conceptual purity?

### 4.2 The New `mkResource`

```nix
mkResource = {
  apiVersion,
  kind,
  name,
  namespace ? "default",
  labels ? {},
  annotations ? {},
  spec ? {},
  data ? {},
  stringData ? {},
  rules ? null,
  subjects ? null,
  roleRef ? null,
  webhooks ? null,
  outputs ? {},
  requires ? [],
  extraDeps ? [],
  extra ? {},
}:
let
  # Namespace key for identity uniqueness
  nsKey = if namespace == null then "_cluster_" else namespace;

  # ── Identity token ──────────────────────────────────────────
  # Creates a store path that serves as this resource's tracking identity.
  # The file content encodes the K8s identity for debugging (readable with
  # `cat /nix/store/<hash>-k8s-Deployment-kube-system-coredns`).
  identityPath = builtins.toFile
    "k8s-${kind}-${nsKey}-${name}"
    "${kind}/${nsKey}/${name}";

  # ── Output refs ─────────────────────────────────────────────
  # Each output carries the actual value but with this resource's
  # identity attached via string context. When you write
  # `${resource.out.port}` the string "5432" appears in the result,
  # but Nix's context system records the dependency on this resource.
  mkOutputRef = outName: value:
    builtins.appendContext
      (toString value)
      { ${identityPath} = { path = true; }; };

  # FQDN output — pre-computed fully-qualified DNS name
  fqdnValue =
    if namespace != null
    then "${name}.${namespace}.svc.cluster.local"
    else name;

  fqdnRef = builtins.appendContext fqdnValue
    { ${identityPath} = { path = true; }; };

  # ── Dependency extraction ───────────────────────────────────
  # Instead of a recursive tree walker, we serialize the spec fields
  # to JSON and use builtins.getContext to find all referenced
  # resources in one shot.
  #
  # This works because:
  # - builtins.toJSON walks the entire attrset recursively
  # - Any string containing a store path (from ${resource} interpolation)
  #   carries that store path in its context
  # - builtins.getContext returns ALL contexts from the JSON string
  #
  # The registry maps store paths back to resource objects.
  extractDeps = registry: fields:
    let
      json = builtins.toJSON fields;
      ctx = builtins.getContext json;
      # Context keys are store paths. Look up each in the registry
      # to get the resource object. Filter out our own identity
      # (a resource shouldn't depend on itself).
      depPaths = builtins.filter (p: p != identityPath) (builtins.attrNames ctx);
    in
    map (p: registry.${p}) depPaths;

  # ── Post-processing ────────────────────────────────────────
  # Replaces store paths in the manifest with actual K8s names.
  # Only primary identity paths need replacement — outputs already
  # carry their real values via appendContext.
  postProcess = registry: manifestJson:
    let
      ctx = builtins.getContext manifestJson;
      paths = builtins.attrNames ctx;
      replacements = map (p:
        { from = p; to = registry.${p}.name; }
      ) (builtins.filter (p: builtins.hasAttr p registry) paths);
    in
    builtins.replaceStrings
      (map (r: r.from) replacements)
      (map (r: r.to) replacements)
      (builtins.unsafeDiscardStringContext manifestJson);

  # ── The resource ────────────────────────────────────────────
  self = {
    _type = "k8s-resource";
    _identityPath = identityPath;

    inherit apiVersion kind name namespace;
    inherit requires;

    # ${resource} → store path (post-processed to K8s name)
    outPath = identityPath;

    # ${resource.fqdn} → actual FQDN string (with tracking)
    fqdn = fqdnRef;

    # ${resource.out.port} → actual value string (with tracking)
    out = lib.mapAttrs mkOutputRef outputs;

    # ── deps ──────────────────────────────────────────────
    # Computed lazily when the registry is available.
    # See Section 5 for how the registry bootstraps.
    depsFrom = registry:
      let
        allFields = { inherit spec data stringData annotations; }
          // lib.optionalAttrs (rules != null) { inherit rules; }
          // lib.optionalAttrs (subjects != null) { inherit subjects; }
          // lib.optionalAttrs (roleRef != null) { inherit roleRef; }
          // lib.optionalAttrs (webhooks != null) { inherit webhooks; };
      in
      (extractDeps registry allFields) ++ extraDeps;

    # ── manifest ──────────────────────────────────────────
    # The raw manifest — contains store paths as placeholders.
    # Must be post-processed before serialization to YAML.
    rawManifest = {
      inherit apiVersion kind;
      metadata = {
        inherit name;
        namespace = if namespace != null then namespace else null;
      }
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
  };
in self;
```

### 4.3 What Packages Look Like

The package code gets *simpler*. No more `k8s.str`, no more thinking about whether `${}` loses tracking:

```nix
# BEFORE (current):
configVolume = {
  name = "config-volume";
  configMap.name = self.configmap.ref;   # .ref is a tagged attrset
};
saName = self.serviceAccount.ref;        # tagged attrset
dbUrl = k8s.str [ "postgresql://" db.fqdn ":" db.out.port "/mydb" ];  # k8s.str required!

# AFTER (native tracking):
configVolume = {
  name = "config-volume";
  configMap.name = "${self.configmap}";   # native ${} → store path, auto-tracked
};
saName = "${self.serviceAccount}";        # native ${} → store path, auto-tracked
dbUrl = "postgresql://${db.fqdn}:${db.out.port}/mydb";  # native ${} → JUST WORKS
```

The `"${self.configmap}"` interpolation:
1. Calls `self.configmap.outPath` (because the resource has `outPath`)
2. Produces `/nix/store/<hash>-k8s-ConfigMap-kube-system-coredns` in the string
3. Nix records the context automatically
4. Post-processing replaces the store path with `"coredns"` in the final manifest

The `"${db.fqdn}"` interpolation:
1. `db.fqdn` is already the string `"postgres.data.svc.cluster.local"` (via `appendContext`)
2. The string carries `db`'s identity in its context
3. No post-processing needed — the value is already correct

### 4.4 Full CoreDNS Example (key parts)

```nix
k8s.mkPackage (
  { namespace ? "kube-system", ... }:
  self:
  {
    configmap = k8s.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "coredns";
      inherit namespace;
      data.Corefile = corefile;
    };

    clusterRoleBinding = k8s.mkResource {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRoleBinding";
      name = "coredns";
      namespace = null;
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";         # ← native ${}!
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "${self.serviceAccount}";      # ← native ${}!
        inherit namespace;
      }];
    };

    workload = k8s.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "coredns";
      inherit namespace;
      requires = [ self.clusterRoleBinding ];
      spec.template.spec = {
        serviceAccountName = "${self.serviceAccount}";  # ← native ${}!
        containers = [{
          name = "coredns";
          image = imageRef;
          volumeMounts = [{ name = "config"; mountPath = "/etc/coredns"; }];
        }];
        volumes = [{
          name = "config";
          configMap.name = "${self.configmap}";          # ← native ${}!
        }];
      };
    };

    # ...
  }
) { namespace = "kube-system"; }
```

Every `${self.xyz}` is native Nix string interpolation. No wrappers, no tagged attrsets, no `k8s.str`.

---

## 5. The Registry: Mapping Store Paths to Resources

### 5.1 The Bootstrap Problem

`extractDeps` needs a registry mapping store paths → resource objects. Resources are the things *in* the registry. How do we avoid circularity?

**Key insight:** Nix is lazy. The registry entry for a resource only needs the resource's `_identityPath` (available immediately — just a `builtins.toFile` call) and its `name` (a plain string argument). It does NOT need the resource's `deps`, `closure`, or `spec`. So the registry can be built before any deps are computed.

The evaluation order:
1. All resources compute their `_identityPath` (from kind + namespace + name — no deps involved)
2. The registry is assembled: `{ identityPath → resource }` for all resources
3. Resources compute their `deps` by calling `depsFrom(registry)` — this reads specs (which contain store paths from other resources' `outPath`) and looks up those store paths in the registry
4. Closures are computed from deps + requires

Steps 1-4 all happen lazily and there are no circular data dependencies:
- `identityPath` depends on: kind, namespace, name (all plain values)
- `registry` depends on: all resources' `identityPath` values (no specs, no deps)
- `deps` depends on: specs (may contain `${otherResource}` → other resources' `identityPath`) + registry
- `closure` depends on: deps + requires

No cycle. The lazy evaluator handles this correctly.

### 5.2 Registry Construction

The registry lives at the **package level** (inner fixpoint) and the **cluster level** (outer fixpoint).

**Inner (package-level) registry:**
```nix
mkPackage = packageFn: defaults:
  let
    parts = lib.fix (packageFn defaults);

    # Build registry from all resources in this package
    resources = lib.filterAttrs
      (_: v: builtins.isAttrs v && (v._type or "") == "k8s-resource")
      parts;

    registry = lib.foldl' (reg: r:
      reg // { ${r._identityPath} = r; }
    ) {} (builtins.attrValues resources);
  in
  parts // {
    _registry = registry;
    # ... rest of package interface
  };
```

**Outer (cluster-level) registry:**
```nix
mkCluster = { basePackages, overlays ? [] }:
  let
    pkgs = applyOverlays overlays basePackages;

    # Merge all package registries
    clusterRegistry = lib.foldl' (reg: pkg:
      reg // pkg._registry
    ) {} (builtins.attrValues (filterPackages pkgs));
  in
  # ...
```

### 5.3 Cross-Package References

When package A references package B's main resource (`${pkgs.postgres}`), it gets B's `outPath` (store path). This store path is in B's registry. As long as the cluster-level registry merges all package registries, `extractDeps` can resolve cross-package references.

But there's a subtlety: at the package level, `extractDeps` only sees the package's own registry. Cross-package store paths won't be found there. Two solutions:

**Option 1: Defer dep computation to cluster level.** Resources don't compute deps themselves. The cluster evaluator runs `extractDeps(clusterRegistry, resource.rawManifest)` for all resources after the fixpoints resolve. This is clean but means resources don't have a `.deps` field until cluster evaluation.

**Option 2: Pass a registry provider.** The package receives a `registryFn` that can look up any resource, not just local ones. The outer fixpoint provides the full registry; the inner fixpoint provides a partial one that's extended at cluster level.

**Option 3: Two-phase deps.** Resources compute `localDeps` from the package-level registry, and the cluster adds `crossDeps` from the cluster registry. The resource's full `deps = localDeps ++ crossDeps`.

> **DECISION NEEDED:** Where should dep computation happen? Option 1 is simplest. Option 2 is most flexible. Option 3 is most explicit.

---

## 6. Post-Processing: Store Paths → K8s Names

### 6.1 When Post-Processing Happens

Post-processing is the final step before YAML serialization. It replaces store paths in manifest strings with actual K8s resource names.

```
Evaluation Flow:
  1. Fixpoints resolve → resources have store paths in specs
  2. Registry built → maps store paths to resource metadata
  3. Closures computed → DAG established
  4. Post-process → replace store paths with K8s names
  5. Serialize → JSON/YAML output
```

### 6.2 The Post-Processor

```nix
# Replace store paths in a manifest attrset with K8s resource names.
#
# Strategy: serialize to JSON (flattens all strings, preserves contexts),
# extract contexts (which store paths appear), replace them, deserialize.
postProcessManifest = registry: manifest:
  let
    json = builtins.toJSON manifest;
    ctx = builtins.getContext json;
    paths = builtins.attrNames ctx;

    # Only replace paths that are in the registry (identity tokens).
    # Other contexts (from normal Nix strings) are irrelevant.
    knownPaths = builtins.filter (p: builtins.hasAttr p registry) paths;

    replaced = builtins.replaceStrings
      knownPaths
      (map (p: registry.${p}.name) knownPaths)
      json;

    # Strip context — we've resolved all references, the contexts
    # are no longer meaningful.
    clean = builtins.unsafeDiscardStringContext replaced;
  in
  builtins.fromJSON clean;
```

### 6.3 Edge Cases

**Store path as substring.** A spec value might be `"postgresql://${db}:5432/mydb"`, which after interpolation is `"postgresql:///nix/store/abc123-k8s-Service-data-postgres:5432/mydb"`. `builtins.replaceStrings` handles this correctly — it does substring replacement. Result: `"postgresql://postgres:5432/mydb"`.

Wait — that's wrong! The K8s Service name is `postgres`, but the app needs `postgres.data.svc.cluster.local` (the FQDN) in connection strings. This is where the hybrid approach (3B) helps: for connection strings, you'd use `${db.fqdn}` (which carries the real FQDN via `appendContext`), not `${db}` (which gives the store path / short name).

**What about references that need the short name in a string?** Like `"--target=Deployment/${self.workload}"`. After replacement: `"--target=Deployment/coredns"`. This works correctly.

**Store paths in non-string positions.** If a store path appears as a JSON key (unlikely) or in a position where it shouldn't be replaced (also unlikely), the replacement could corrupt the manifest. In practice, store paths only appear in string values where resource names are expected, so this isn't a real concern.

**Multiple resources with the same name but different namespaces.** Their identity tokens are different (namespace is part of the `toFile` name), so they get different store paths. No collision.

### 6.4 What About `${resource}` vs `${resource.fqdn}` — When to Use Which?

This is a UX question. The rule is simple:

| Context | What you write | What it means |
|---|---|---|
| Same-namespace name ref | `"${self.configmap}"` | Short name, post-processed. For `configMapRef.name`, `serviceAccountName`, etc. |
| Cross-namespace connection | `"${db.fqdn}"` | FQDN, real value via appendContext. For DNS-based service discovery. |
| Specific output value | `"${svc.out.port}"` | Output value, real value via appendContext. For env vars, annotations. |

This maps naturally to K8s semantics: within a namespace, you reference by short name. Across namespaces, you use FQDN. Specific values (ports, IPs) are output references.

---

## 7. The Non-String Problem

K8s manifests contain integers (port numbers, replica counts), booleans, and arrays alongside strings. Nix's string context only works on strings. How do we handle cross-resource references to non-string values?

### 7.1 Where It Matters

```nix
# This works — string context tracks the dep:
spec.backend.service.name = "${svc}";         # string field ✓

# This doesn't — port.number is an integer in K8s:
spec.backend.service.port.number = ???;        # integer field ✗
```

If we write `spec.backend.service.port.number = "${svc.out.port}"`, the manifest gets `"port": { "number": "5432" }` — a string, not an integer. K8s rejects this.

### 7.2 How Common Is This?

Cross-resource integer references are actually rare. Most cross-resource references are by name (string). Let's enumerate the common cases:

**Always strings (covered by `${}`)**:
- `configMapRef.name`, `secretRef.name`, `serviceAccountName`
- `backend.service.name`, `issuerRef.name`
- `configMap.name` (in volumes)
- Environment variable values
- DNS names in connection strings

**Integers (not covered)**:
- `backend.service.port.number` — cross-resource port ref
- `containerPort` — usually hardcoded per container, not cross-resource

**Practically:** The `backend.service.port.number` case is the main one, and even that's uncommon (most Ingress→Service refs use port name, not number).

### 7.3 Solutions

**Option A: Use `extraDeps` for the rare integer case.**
```nix
spec.backend.service.port.number = svc.out.port.value;  # plain integer, no tracking
extraDeps = [ svc ];                                      # manual dep
```
Pragmatic. The integer value is correct, the dep is explicit. For the 1-2 cases per cluster where this comes up, it's fine.

**Option B: Stringify and post-process with type awareness.**
```nix
spec.backend.service.port.number = "${svc.out.port}";  # string "5432"
# Post-processor knows port.number should be an integer, converts
```
Requires the post-processor to understand K8s schema. Overengineered.

**Option C: Accept that integer outputs don't auto-track.**
The `out` map provides values for reading. If you use an output in a string context (`"port ${svc.out.port}"`), deps are tracked. If you use it as a bare integer (`port.number = svc.out.port.intValue`), you get the value but no tracking — add the dep manually.

**Recommendation: Option A.** It's honest about the limitation, works today, and covers the rare cases where this matters. Don't over-engineer for a problem that barely exists.

---

## 8. Closure Computation

### 8.1 What Changes

The closure algorithm (`computeClosure`) stays essentially the same. It walks `deps` + `requires` transitively. The difference is how `deps` are computed:

**Before:** `resolve(spec).deps` — custom tree walker finds `_type = "k8s-ref"` tags
**After:** `extractDeps(registry, spec)` — `builtins.toJSON` + `builtins.getContext` + registry lookup

The BFS traversal, deduplication by identity key, and `requires` handling are unchanged.

### 8.2 Interaction with `withRequires`

`withRequires` adds inverted deps to a resource and recomputes its closure. This still works — it doesn't depend on how `deps` are computed. It just adds to the `requires` list and calls `computeClosure`.

### 8.3 Interaction with `overrideParts`

When you override a part via the inner fixpoint, the new part creates its own identity token (possibly the same store path if kind/namespace/name are unchanged, or a different one if the name changes). Other parts that reference it via `${self.overriddenPart}` get the new store path automatically (the fixpoint re-resolves). Deps update accordingly.

---

## 9. What Changes vs. What Stays

### Eliminated

| Component | Lines | Replacement |
|---|---|---|
| `refs.nix` — `mkRef`, `isRef`, `str`, `isTrackedStr` | 66 | `builtins.toFile` + `builtins.appendContext` (inline in `mkResource`) |
| `resolve.nix` — recursive tree walker | 101 | `builtins.toJSON` + `builtins.getContext` (~5 lines) |
| `k8s.str [ ... ]` usage in all packages | many | Native `"${...}"` interpolation |

### Modified

| Component | Change |
|---|---|
| `resource.nix` — `mkResource` | Adds `_identityPath`, `outPath`, `fqdn` via appendContext. Deps via `extractDeps` instead of `resolve`. Manifest is "raw" (contains store paths). |
| `package.nix` — `mkPackage` | Builds a registry from package resources. May pass registry to resources for dep computation. |
| `cluster.nix` — `mkCluster` | Merges package registries. Runs post-processing on manifests before serialization. |
| All packages (`pkgs-fp/*`) | Replace `self.xyz.ref` with `"${self.xyz}"`. Replace `k8s.str [...]` with native `"${...}"`. |

### Unchanged

| Component | Why |
|---|---|
| `closure.nix` — `computeClosure`, visualization | Algorithm is independent of how deps are sourced |
| `package.nix` — `overrideParts`, `override` | Fixpoint mechanics unchanged |
| `cluster.nix` — `applyOverlays`, dedup | Overlay mechanics unchanged |
| `requires` — inverted deps | Can't be inferred from string context (semantic, not syntactic) |
| `lib/default.nix` — kixlib builders | Separate layer, not affected |
| Package structure and interface | `main`, `closure`, `out`, etc. stay the same |

---

## 10. Risks and Open Questions

### 10.1 `builtins.getContext` / `builtins.appendContext` Stability

These are undocumented Nix builtins. They've been stable since Nix 2.0 and are used in nixpkgs (e.g., `lib.strings.getContext`), but they're not in the official Nix manual. If the Nix team changes them, we're exposed.

**Mitigation:** Wrap them in our own functions (`k8s.getContext`, `k8s.appendContext`) so we can adapt if the API changes. Monitor Nix releases.

**Counter-argument:** We're already deeply coupled to Nix internals (lazy evaluation semantics, `lib.fix`, `builtins.toJSON` behavior). These builtins are no more risky than other Nix internals we depend on.

### 10.2 `builtins.unsafeDiscardStringContext`

The name says "unsafe." In practice, it's safe when you've already resolved all references (which we have, in the post-processor). It's "unsafe" in the Nix build sandbox sense — it strips context that Nix uses to track build dependencies. Since we're not building derivations, this doesn't matter.

### 10.3 Store Pollution

Each resource creates a store entry via `builtins.toFile`. For a cluster with 200 resources, that's 200 tiny files in `/nix/store`. This is negligible — the store already contains millions of entries in a typical NixOS system.

### 10.4 Debugging

When something goes wrong in the intermediate state, manifests contain store paths instead of names. This is harder to read than the current system where resolved manifests contain K8s names directly.

**Mitigation:** Provide a `debugManifest` function that post-processes and pretty-prints. Also, the store path format `k8s-<Kind>-<Namespace>-<Name>` is human-readable enough to debug visually.

### 10.5 Performance

`builtins.toJSON` on each resource's spec + `builtins.getContext` should be comparable to the current recursive tree walker. The tree walker visits every node; `builtins.toJSON` also visits every node (it's a serializer). `builtins.getContext` is O(number of unique contexts in the string), which is bounded by the number of cross-resource references.

The post-processor runs `builtins.replaceStrings` once per manifest, which is O(n * m) where n is the manifest size and m is the number of referenced resources. This is negligible.

### 10.6 Context Leakage

What if a string value in a spec happens to contain a store path from an unrelated source? For example, if a package hardcodes a Nix store path as an image reference:

```nix
image = "${pkgs.coredns}/bin/coredns";  # actual Nix package store path
```

This store path would appear in `builtins.getContext` output, and the post-processor would try to look it up in the registry. Since it's not in the registry, it wouldn't be replaced — which is correct behavior. But it would appear as a "dep" in `extractDeps`.

**Mitigation:** `extractDeps` should filter to only registry-known paths (already shown in the design above). Non-registry paths are ignored.

### 10.7 The `.ref` Ergonomics Question

Currently, packages write `self.configmap.ref` (explicit reference to the name output). With native tracking, they write `"${self.configmap}"` (string interpolation). The new form requires quotes and `${}` syntax, which is slightly more verbose for simple name assignments:

```nix
# Current:  more concise for simple refs
configMap.name = self.configmap.ref;

# New: requires string interpolation syntax
configMap.name = "${self.configmap}";
```

But for compound strings, the new form is much better:

```nix
# Current: k8s.str combinator
value = k8s.str [ "postgresql://" db.fqdn ":" db.out.port "/mydb" ];

# New: native interpolation
value = "postgresql://${db.fqdn}:${db.out.port}/mydb";
```

The trade-off favors the new approach — compound strings are more common and the ergonomic improvement is dramatic.

---

## 11. Migration Path

### 11.1 Incremental Migration

The custom ref system and native store path tracking can coexist during migration:

1. **Phase 1:** Implement new `mkResource` with `outPath` and `appendContext` outputs alongside the existing one. Add `_identityPath` to existing resources (backward compatible).

2. **Phase 2:** Migrate packages one at a time. Replace `self.xyz.ref` → `"${self.xyz}"` and `k8s.str [...]` → `"${...}"`.

3. **Phase 3:** Add registry construction and post-processing to `mkPackage` and `mkCluster`.

4. **Phase 4:** Remove `refs.nix`, `resolve.nix`, and the old `resolve` calls from `mkResource`.

### 11.2 Verification

For each migrated package, compare the post-processed manifest against the current resolved manifest. They should be identical (same K8s names in the same positions).

```bash
# Compare old (custom tracking) vs new (native tracking) output
diff <(nix eval --json .#old.coredns.main.manifest | jq -S .) \
     <(nix eval --json .#new.coredns.main.manifest | jq -S .)
```

---

## 12. Alternative: Make the Store Path BE the K8s Name

The user suggested: "directly have the k8s resource name be the path and just strip all /nix/store on deploy."

This means naming the derivation/file such that the store path encodes the K8s resource name:

```
builtins.toFile "coredns" "" → /nix/store/<hash>-coredns
```

On deploy, strip `/nix/store/<hash>-` to get `coredns`.

### 12.1 How This Would Work

```nix
identityPath = builtins.toFile name "";
# For "coredns": /nix/store/abc123-coredns
# Strip prefix: coredns ✓
```

The deploy script strips `/nix/store/<hash>-` from all strings in the manifest.

### 12.2 Problems

**Name collisions.** Two resources with the same name but different kinds/namespaces (e.g., Service/coredns and Deployment/coredns) would need different identity tokens but have the same Nix name. `builtins.toFile` with the same name and content produces the same store path — they'd be indistinguishable.

Fix: include kind and namespace in the file name: `builtins.toFile "${kind}-${ns}-${name}" ""`. But then stripping the prefix gives `Deployment-kube-system-coredns`, not `coredns`. You'd need to parse the convention.

**Fragile parsing.** The strip-and-parse approach depends on a naming convention. If a resource name contains hyphens (most do), parsing `Service-kube-system-my-cool-app` is ambiguous — where does the namespace end and the name begin?

**Store path format changes.** If Nix changes its store path format, the stripping logic breaks.

### 12.3 Verdict

The registry approach (Section 5) is more robust. The mapping from store path to K8s name is explicit, not derived from string conventions. The store path format is an implementation detail we don't depend on.

That said, for *debugging*, having the resource identity in the store path name is helpful. That's why the design uses `builtins.toFile "k8s-${kind}-${nsKey}-${name}" "..."` — the store path is human-readable even if we don't parse it programmatically.

---

## 13. Summary

| Aspect | Current (custom tracking) | Proposed (native store paths) |
|---|---|---|
| Name references | `self.xyz.ref` (tagged attrset) | `"${self.xyz}"` (native interpolation) |
| String building | `k8s.str [ a ":" b ]` | `"${a}:${b}"` (native interpolation) |
| Output values | `self.xyz.out.port` (tagged attrset) | `self.xyz.out.port` (string with appendContext) |
| Dep extraction | Custom tree walker (100 lines) | `builtins.toJSON` + `builtins.getContext` (5 lines) |
| Manifest state | Final (K8s names) | Intermediate (store paths) → post-processed |
| New infrastructure | None | Registry + post-processor |
| Eliminated code | — | `refs.nix`, `resolve.nix`, `k8s.str` |
| Inverted deps | `requires` (manual) | `requires` (manual, unchanged) |
| Integer outputs | `mkRef` (same as strings) | `extraDeps` (manual for rare cases) |

The net effect: ~170 lines of custom tracking code replaced by ~30 lines of registry + post-processing, plus native Nix string interpolation everywhere. The main trade-off is that manifests are no longer "final" at construction time — they contain store path placeholders until post-processing. This adds one step to the pipeline but removes the cognitive burden of remembering to use `k8s.str` instead of `${}`.
