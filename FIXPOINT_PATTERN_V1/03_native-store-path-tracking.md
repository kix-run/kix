# Native Store Path Tracking: Resources as Derivations

## Working Document — March 2026

**Status:** Design exploration (not yet implemented)
**Predecessor:** `02_kixpkgs-design-doc.md` (custom ref/resolve system)

---

## 1. The Problem with Custom Tracking

The current fixpoint implementation (`lib/fixpoint/`) maintains a parallel dependency tracking system:

1. **`mkRef`** creates `{ _type = "k8s-ref"; resource; output; value; }` tagged attrsets
2. **`k8s.str`** wraps string concatenation to avoid losing ref metadata through `${}`
3. **`resolve`** is a recursive tree walker (~100 lines) that pattern-matches on `_type` tags, extracts deps, and returns `{ resolved, deps }` tuples
4. **`mkResource`** calls `resolve` on every field (spec, data, annotations, rules, subjects, roleRef, webhooks), collects deps, and builds the resource

This works, but it's reimplementing what Nix already does natively. Nix strings carry invisible *context* — metadata recording which derivations produced parts of the string. When you write `"${openssl}/lib"`, Nix automatically:
- Substitutes `openssl.outPath` into the string
- Records `openssl` as a dependency in the string's context
- Propagates that context through all further string operations

We're building a shadow version of this in userspace, with worse ergonomics (`k8s.str` instead of `${}`).

---

## 2. Design Goals

Two outcomes are desired — these are architectural goals, not implementation details:

### 2.1 Dependency Injection at the Package Level

Packages receive their cross-package dependencies via arguments, like `callPackage`:

```nix
# my-app receives postgres as a package-level dependency
myApp = mkPackage ({ postgres, certManager, ... }: self: {
  # ...
}) { postgres = pkgs.postgres; certManager = pkgs.certManager; };
```

This is the DI pattern. The **package** is the unit of injection. You pass `postgres` to `myApp`, not individual resources from postgres.

### 2.2 Store Path Derivations at the Resource Level

Each K8s resource (each YAML document) is a Nix derivation with proper hashing and inputs. The actual store path references happen at the resource level — you literally reference the Service resource of postgres:

```nix
# Inside my-app, you reference a specific resource from postgres
env.DATABASE_URL = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
```

`postgres.service` is a derivation. `${postgres.service.fqdn}` embeds its store path (or a tracked value) in the string. Nix's native context system tracks the dependency.

### 2.3 Proper Hashing (Merkle DAG)

Because resources are derivations with proper inputs, we get a Merkle DAG:

```
Change ConfigMap data
  → ConfigMap hash changes
    → Deployment hash changes (it references the ConfigMap)
      → You know exactly what needs redeployment
```

This is one of Nix's core value propositions, applied to K8s resources. `nix-diff` between two cluster evaluations shows exactly which resources changed and which input caused the change.

### 2.4 Closure Semantics: Outputs Don't Split the Closure

Unlike Nix packages where `openssl.lib` is independently deployable without `openssl.dev`, K8s resource outputs are NOT independent:

```nix
# In Nix: openssl.lib is useful without openssl.bin
# In K8s: postgres.service.out.port is USELESS without the whole postgres service

${postgres.service.out.port}  # tracks dep on postgres.service
                              # which carries the whole postgres closure via requires
                              # you CANNOT deploy just the port
```

If you depend on the port, you depend on the Service, which `requires` the Deployment, which refs the ConfigMap, the ServiceAccount, etc. The output is a view into the resource, not a separate deployable unit.

### 2.5 Sub-Components CAN Split the Closure

A package can expose intentional seams — logical sub-components with their own smaller closures:

```nix
# "I need cert-manager's Certificate CRD to exist, but I don't need the controller running"
requires = [ certManager.crds.certificate ];   # just the CRD, not the full package

# "I need to share postgres's storage, but don't need the service exposed"
volumes = [{ persistentVolumeClaim.claimName = "${postgres.pvc}"; }];
```

These are explicit, intentional exports — not every resource. The package author decides what sub-components to expose.

---

## 3. Architectural Model

### 3.1 The Two Levels

```
┌─────────────────────────────────────────────────────────────────┐
│  PACKAGE LEVEL — Dependency Injection                           │
│                                                                 │
│  mkPackage ({ postgres, certManager }: self: { ... })          │
│                                                                 │
│  - Package = sugar for fixpoint + callPackage                   │
│  - Cross-package deps injected here                             │
│  - Each package is a self-referential set of resources          │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  RESOURCE LEVEL — Store Path Derivations                   │  │
│  │                                                            │  │
│  │  configmap = mkResource { ... };     ← derivation          │  │
│  │  deployment = mkResource {                                 │  │
│  │    spec.volumes.configMap.name = "${self.configmap}";       │  │
│  │    # ↑ native ${} — Nix tracks the dep via store path      │  │
│  │  };                                                        │  │
│  │                                                            │  │
│  │  Cross-package resource ref:                               │  │
│  │  env.DB_URL = "postgresql://${postgres.service.fqdn}";     │  │
│  │  # ↑ references a specific resource from an injected pkg   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

The package is the DI boundary. The resource is the derivation boundary.

### 3.2 How This Differs from the Nix Analogy

| Nix | K8s (kixpkgs) | Difference |
|---|---|---|
| `pkgs.openssl` (package) | `pkgs.postgres` (package) | Same: DI unit |
| `openssl` (derivation) | `postgres.service` (derivation) | Different: package contains MULTIPLE derivations (resources) |
| `${openssl}` → dep on openssl | `${postgres.service}` → dep on postgres.service | Same: store path tracking |
| `openssl.lib` → independent output | `postgres.service.out.port` → NOT independent | Different: K8s outputs need the whole service |
| — | `certManager.crds.certificate` → independent sub-component | New: explicit seams at package author's discretion |

### 3.3 The Nix Analogy, More Precisely

A kixpkgs package is like a Nix package that produces multiple outputs where **most outputs require each other** but some can be split:

```nix
# If Nix worked like K8s:
openssl = mkDerivation {
  outputs = ["lib" "dev" "bin" "man"];
  # BUT: using lib REQUIRES bin to be installed too
  # (unlike real Nix where lib is independent)

  # Except: man pages CAN be used independently
  # (like CRDs that can exist without the controller)
};
```

---

## 4. Resource Derivations: What Makes Them Tick

### 4.1 Each Resource Is a Derivation

Each `mkResource` call produces something with an `outPath` — a Nix store path that participates in string context tracking. The derivation's hash depends on:

1. The resource's own content (kind, name, namespace, spec, data, labels, etc.)
2. The hashes of all referenced resources (because their store paths appear in the spec)

This forms the Merkle DAG. Change any input → the hash changes → everything that references it gets a new hash.

### 4.2 What the Derivation Contains

Open question: should these derivations be **buildable** (producing the manifest YAML as output) or **eval-time only** (exist for hashing/tracking, never built)?

**Eval-time only (lightweight):**
```nix
# builtins.toFile — creates a store path, never built
identityPath = builtins.toFile
  "k8s-${kind}-${nsKey}-${name}"
  "${kind}/${nsKey}/${name}";
```
- Enough for string context tracking and hashing
- Manifests rendered at eval time, post-processed
- `nix-diff` still works (compares `.drv` files / store paths)

**Buildable (heavier, more capability):**
```nix
# Real derivation — when built, produces the manifest YAML
resourceDrv = derivation {
  name = "k8s-${kind}-${nsKey}-${name}";
  system = builtins.currentSystem;
  builder = writeScript "render" ''
    echo '${builtins.toJSON manifest}' > $out
  '';
  # Input derivations tracked automatically because
  # manifest strings contain store paths of dependencies
};
```
- `nix build .#cluster` produces all manifests as store artifacts
- Nix's build cache means unchanged resources aren't re-rendered
- Store closure of the cluster derivation IS the deploy set

The eval-time approach is simpler and sufficient for the core goals (hashing, tracking, change detection). Building can be added later if the store-artifact model proves valuable.

### 4.3 The Hash Must Reflect Reality

For the Merkle DAG to be useful, the derivation hash must change when and only when the K8s resource would actually change on the cluster. This means:

**Must be in the hash:**
- `spec`, `data`, `stringData`, `labels`, `annotations` (the resource content)
- Referenced resources' identity (via store paths in specs)
- `apiVersion`, `kind`, `name`, `namespace` (the identity)

**Must NOT be in the hash:**
- Metadata about the kixpkgs system itself
- Comments or documentation strings
- The order of attributes (Nix attrsets are unordered)

`builtins.toFile` content-addresses based on the file content. If we include the full spec in the content (as JSON), the hash reflects the resource content faithfully. If we only include kind/namespace/name, the hash doesn't change when the spec changes — which defeats the purpose.

```nix
# WRONG: hash only depends on identity, not content
identityPath = builtins.toFile "k8s-${kind}-${ns}-${name}" "${kind}/${ns}/${name}";

# RIGHT: hash depends on the full resource content
identityPath = builtins.toFile "k8s-${kind}-${ns}-${name}"
  (builtins.toJSON { inherit apiVersion kind name namespace spec data labels annotations; });
```

But wait — `builtins.toFile` can't contain references to other store paths if those store paths come from derivations (it CAN contain references to other `toFile` paths). If our specs contain `${otherResource}` (store paths from other resources' `toFile` calls), this works because they're all `toFile` paths. But if any referenced store path comes from a real derivation (like a Nix package for the container image), `builtins.toFile` would fail.

This is where `derivation { ... }` might be necessary after all — it handles arbitrary store path references in its inputs. The choice between `toFile` and `derivation` depends on whether we ever embed non-toFile store paths in specs.

> **Open question:** Will specs ever contain store paths from real Nix derivations (e.g., `image = "${pkgs.coredns}/bin/coredns"`)? If yes, we need `derivation`. If specs only contain store paths from other K8s resources (all `toFile`), then `toFile` works.

### 4.4 Outputs: Same Derivation, Different Views

All outputs of a resource (port, fqdn, etc.) track back to the same derivation. They're different views, not different dependencies:

```nix
# All of these create a dependency on postgres.service:
"${postgres.service}"              # → store path (the name)
"${postgres.service.fqdn}"         # → "postgres.data.svc.cluster.local" (with context)
"${postgres.service.out.port}"     # → "5432" (with context)

# The dep is the SAME in all cases: postgres.service (the derivation)
# The closure is the SAME: everything postgres.service requires
```

Implementation: outputs use `builtins.appendContext` to attach the resource derivation's context to the actual value. This way:
- `${resource}` → store path (needs post-processing to replace with K8s name)
- `${resource.fqdn}` → actual FQDN (already correct, context tracked invisibly)
- `${resource.out.port}` → actual port value (already correct, context tracked invisibly)

### 4.5 Sub-Components: Separate Derivations

When a package wants to expose a sub-component with its own closure (like a CRD that's useful without the controller), that sub-component is a separate resource derivation:

```nix
# cert-manager package
certManager = mkPackage (args: self: {
  # Each CRD is its own resource (derivation)
  certificateCRD = mkResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "certificates.cert-manager.io";
    # ... CRD spec ...
  };

  controller = mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "cert-manager-controller";
    # ...
  };

  # Expose sub-components for consumers who need partial closure
  crds = {
    certificate = self.certificateCRD;   # its own derivation, own closure
    issuer = self.issuerCRD;
  };

  # Main carries everything
  main = withRequires [
    self.controller
    self.certificateCRD
    self.issuerCRD
  ] self.service;
});

# Consumer that needs the full package:
requires = [ certManager.main ];

# Consumer that needs just the CRD:
requires = [ certManager.crds.certificate ];
```

The CRD resource has its own store path and its own (small) closure. The consumer can depend on just that, without pulling in the controller Deployment.

---

## 5. Package-Level DI + Resource-Level Store Paths

### 5.1 How Cross-Package Dependencies Work

The outer fixpoint (cluster level) injects packages into each other. But the actual resource references happen at the resource level:

```nix
# Cluster definition — outer fixpoint
clusterPackages = self: {
  postgres = mkPostgres { namespace = "data"; };
  myApp = mkMyApp {
    namespace = "production";
    postgres = self.postgres;       # ← package-level DI
  };
};

# Inside my-app package — inner fixpoint
mkMyApp = { postgres, namespace, ... }: mkPackage (args: self: {
  deployment = mkResource {
    spec.template.spec.containers = [{
      env = [{
        name = "DATABASE_URL";
        # resource-level store path reference:
        value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
        #                      ^^^^^^^^^^^^^^^^^^^^^^^^
        #                      This is a specific resource from the injected package.
        #                      Nix tracks the dep on postgres.service (derivation).
        #                      The closure includes everything postgres.service requires.
      }];
    }];
  };
  # ...
});
```

The package receives `postgres` (the whole package). It then reaches into `postgres.service` (a specific resource/derivation) to get the FQDN and port. The Nix string context tracks the dependency on that specific resource derivation.

### 5.2 What `.service`, `.main`, `.crds` etc. Are

These are just attrset accessors into the package's fixpoint. The package exposes:

```nix
# A package is a fixpoint attrset:
postgres = {
  configmap = <resource/derivation>;
  serviceAccount = <resource/derivation>;
  deployment = <resource/derivation>;
  service = <resource/derivation>;     # ← postgres.service
  pvc = <resource/derivation>;         # ← postgres.pvc (sub-component)

  main = <resource/derivation>;        # = service with requires pulling in everything
  ref = main.ref;                      # shortcut
  out = main.out;                      # shortcut
  closure = main.closure;              # shortcut
};
```

When a consumer writes `${postgres.service.fqdn}`, they're accessing:
1. `postgres` — the package (injected via DI)
2. `.service` — a specific resource within the package (a derivation)
3. `.fqdn` — an output of that resource (a string with context)

### 5.3 The Package as `callPackage`

The package constructor is sugar for the inner fixpoint + argument injection. It's analogous to `callPackage` in nixpkgs:

```nix
# nixpkgs callPackage:
callPackage = fn: args: fn (intersectAttrs (functionArgs fn) pkgs // args);

# kixpkgs mkPackage:
mkPackage = packageFn: defaults:
  let parts = lib.fix (packageFn defaults);
  in parts // { /* package interface: main, override, overrideParts, ... */ };
```

The package function receives its arguments (including injected dependencies) and produces a self-referential attrset of resources via `lib.fix`. The package wrapping adds `main`, `override`, `overrideParts`, and exposes the closure.

---

## 6. Post-Processing: Store Paths → K8s Names

### 6.1 Why Post-Processing Is Needed

Specs contain store paths like `/nix/store/abc123-k8s-ConfigMap-kube-system-coredns` where K8s expects `"coredns"`. Before serializing to YAML, we replace store paths with K8s resource names.

This is analogous to how Nix binaries contain references to store paths at build time, but at a different level — we do it at eval/serialize time.

### 6.2 The Registry

A mapping from store paths to resource metadata. Built from all resources in the cluster:

```nix
registry = {
  "/nix/store/abc123-k8s-ConfigMap-..." = { name = "coredns"; kind = "ConfigMap"; ... };
  "/nix/store/def456-k8s-Service-..." = { name = "coredns"; kind = "Service"; ... };
  # ...
};
```

Each resource registers itself by its `_identityPath` (store path) → its K8s metadata.

### 6.3 The Post-Processor

```nix
postProcessManifest = registry: manifest:
  let
    json = builtins.toJSON manifest;
    ctx = builtins.getContext json;
    paths = builtins.attrNames ctx;
    knownPaths = builtins.filter (p: builtins.hasAttr p registry) paths;
    replaced = builtins.replaceStrings
      knownPaths
      (map (p: registry.${p}.name) knownPaths)
      json;
    clean = builtins.unsafeDiscardStringContext replaced;
  in
  builtins.fromJSON clean;
```

### 6.4 When It Runs

```
Evaluation Flow:
  1. Inner fixpoints resolve → resources created as derivations
  2. Outer fixpoint resolves → packages composed, DI wired
  3. Registry built from all resources across all packages
  4. Closures computed (deps from getContext + requires)
  5. Post-process manifests → replace store paths with K8s names
  6. Serialize → YAML
```

### 6.5 Edge Cases

**Store path as substring.** `"postgresql://${postgres.service}:5432/mydb"` becomes `"postgresql:///nix/store/...:5432/mydb"`. `replaceStrings` does substring replacement correctly → `"postgresql://postgres:5432/mydb"`.

But that's wrong — you'd want the FQDN in a connection string, not the short name. The answer: use `${postgres.service.fqdn}` for connection strings (gives the real FQDN via `appendContext`), `${postgres.service}` for same-namespace name refs (gives the store path, post-processed to the short name).

**Context from non-K8s store paths.** If a spec contains `image = "${pkgs.coredns}/bin/coredns"`, this store path isn't in the registry. `extractDeps` filters to registry-known paths only. The post-processor ignores unknown paths. Correct behavior.

---

## 7. The Non-String Problem

### 7.1 The Issue

K8s has integer fields (port numbers, replica counts). Nix string context only works on strings. If you write `spec.port.number = "${svc.out.port}"`, the manifest gets `"port": { "number": "5432" }` — a string, not an integer.

### 7.2 How Rare This Is

Cross-resource integer references are uncommon. Most cross-resource refs are by name (string): `configMapRef.name`, `serviceAccountName`, `backend.service.name`, env var values, DNS names.

The main integer case is `backend.service.port.number` in Ingress specs. Even that usually uses port *name* (string) rather than port *number* (integer).

### 7.3 Solution

For the rare integer case, use `extraDeps`:

```nix
spec.backend.service.port.number = postgres.service.out.port.value;  # plain integer
extraDeps = [ postgres.service ];                                     # manual dep
```

Honest about the limitation. Works. Don't over-engineer for a problem that barely exists.

---

## 8. What Changes vs. What Stays

### Eliminated

| Component | Replacement |
|---|---|
| `refs.nix` — `mkRef`, `isRef`, `str`, `isTrackedStr` | Resource `outPath` + `builtins.appendContext` for outputs |
| `resolve.nix` — recursive tree walker | `builtins.toJSON` + `builtins.getContext` |
| `k8s.str [ ... ]` in all packages | Native `"${...}"` interpolation |

### New

| Component | Purpose |
|---|---|
| Identity derivation (per resource) | Store path for Merkle DAG hashing + string context tracking |
| Registry (cluster-level) | Maps store paths → resource metadata for post-processing |
| Post-processor | Replaces store paths with K8s names before YAML serialization |

### Modified

| Component | Change |
|---|---|
| `resource.nix` — `mkResource` | Creates derivation, adds `outPath`. Deps via `getContext` instead of tree walker. |
| `package.nix` — `mkPackage` | Collects registry entries from package resources. |
| `cluster.nix` — `mkCluster` | Merges registries. Runs post-processing on all manifests. |
| All packages (`pkgs-fp/*`) | `self.xyz.ref` → `"${self.xyz}"`. `k8s.str [...]` → `"${...}"`. |

### Unchanged

| Component | Why |
|---|---|
| `closure.nix` — `computeClosure` | Algorithm independent of how deps are sourced |
| `overrideParts`, `override` | Fixpoint mechanics unchanged |
| `applyOverlays` | Overlay mechanics unchanged |
| `requires` (inverted deps) | Semantic, can't be inferred from string context |
| Package structure (`main`, `closure`, etc.) | Same interface, different internals |

---

## 9. Open Questions

### 9.1 `builtins.toFile` vs `derivation`

`toFile` is lighter but can only reference other `toFile` paths in its content. `derivation` is heavier but handles arbitrary store path references.

If specs ever contain store paths from real Nix packages (e.g., `image = "${pkgs.coredns}/bin/coredns"`), the identity derivation's content (which includes the spec) can't use `toFile`. We'd need `derivation`.

If specs only reference other K8s resources (all `toFile`), then `toFile` works.

**Current assessment:** Nix package store paths in K8s specs (for images built by Nix) is a likely future use case. This argues for `derivation` despite the overhead.

### 9.2 Content-Based vs Identity-Based Hashing

Should the derivation hash reflect the full resource content (spec, data, labels) or just the identity (kind, namespace, name)?

**Content-based:** Hash changes when spec changes. Enables change detection. But: the spec contains store paths of dependencies, which means the hash changes when ANY dependency changes (even if this resource's own spec is unchanged). This is the Merkle DAG property — desirable for change propagation.

**Identity-based:** Hash only changes when the resource is renamed/moved. Much more stable. But: no change detection. Defeats the Merkle DAG purpose.

**Recommendation:** Content-based. The Merkle DAG is the point.

### 9.3 Where to Compute Deps

Resources need to know their deps (for closure computation). Deps come from `builtins.getContext` on the spec. But `getContext` returns store paths, which must be mapped back to resource objects via the registry.

Three options for when/where this happens:

1. **At cluster level.** Resources have `rawManifest` but no `deps`. The cluster evaluator computes deps for all resources using the full cluster registry. Simplest.

2. **Via a registry provider.** Resources receive a `registryFn` from the fixpoint and compute deps lazily. Most flexible, but more plumbing.

3. **Two-phase.** Package-level local deps + cluster-level cross-package deps. Most explicit.

This is an implementation detail — all three produce the same DAG.

### 9.4 `builtins.getContext` / `builtins.appendContext` Stability

Undocumented Nix builtins, stable since Nix 2.0, used in nixpkgs. Risk is low but nonzero. Mitigation: wrap in our own functions so we can adapt if the API changes.

### 9.5 Debugging Store Paths

Intermediate manifests contain store paths instead of K8s names. Harder to read during debugging. Mitigation: `debugManifest` function that post-processes and pretty-prints. Store path names are human-readable (`k8s-Deployment-kube-system-coredns`).

---

## 10. Example: Full Flow

### 10.1 Package Definitions

```nix
# postgres package
mkPostgres = mkPackage ({ namespace ? "data", ... }: self: {
  configmap = mkResource {
    apiVersion = "v1"; kind = "ConfigMap";
    name = "postgres-config"; inherit namespace;
    data = { /* postgres config */ };
  };

  pvc = mkResource {
    apiVersion = "v1"; kind = "PersistentVolumeClaim";
    name = "postgres-data"; inherit namespace;
    spec.resources.requests.storage = "100Gi";
  };

  deployment = mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = "postgres"; inherit namespace;
    spec.template.spec = {
      containers = [{
        name = "postgres";
        image = "postgres:16";
        volumeMounts = [{ name = "data"; mountPath = "/var/lib/postgresql/data"; }];
      }];
      volumes = [{
        name = "data";
        persistentVolumeClaim.claimName = "${self.pvc}";  # ← native ${}
      }];
    };
  };

  service = mkResource {
    apiVersion = "v1"; kind = "Service";
    name = "postgres"; inherit namespace;
    outputs = { port = 5432; };
    spec = {
      selector = { "app" = "postgres"; };
      ports = [{ port = 5432; targetPort = 5432; }];
    };
  };

  main = withRequires [ self.deployment self.configmap ] self.service;
});
```

### 10.2 Consumer Package

```nix
mkMyApp = mkPackage ({ namespace ? "production", postgres, ... }: self: {
  deployment = mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = "myapp"; inherit namespace;
    spec.template.spec.containers = [{
      name = "app";
      image = "myapp:v2.1.0";
      env = [{
        name = "DATABASE_URL";
        # Native ${} — Nix tracks dep on postgres.service (derivation)
        value = "postgresql://${postgres.service.fqdn}:${postgres.service.out.port}/mydb";
      }];
    }];
  };

  service = mkResource {
    apiVersion = "v1"; kind = "Service";
    name = "myapp"; inherit namespace;
    spec.selector = { "app" = "myapp"; };
  };

  main = withRequires [ self.deployment ] self.service;
});
```

### 10.3 Cluster Composition

```nix
cluster = mkCluster {
  basePackages = self: {
    postgres = mkPostgres { namespace = "data"; };
    myApp = mkMyApp {
      namespace = "production";
      postgres = self.postgres;           # ← package-level DI
    };
  };
};
```

### 10.4 What `${postgres.service.fqdn}` Does

1. `postgres.service` is a resource with `outPath` = `/nix/store/<hash>-k8s-Service-data-postgres`
2. `.fqdn` is `"postgres.data.svc.cluster.local"` with `postgres.service`'s store path attached via `builtins.appendContext`
3. `"postgresql://${postgres.service.fqdn}:..."` produces the string `"postgresql://postgres.data.svc.cluster.local:..."` with `postgres.service`'s context
4. When we compute deps (via `builtins.getContext` on the serialized spec), `postgres.service`'s store path appears → it's a dependency
5. `postgres.service.closure` includes: Service, Deployment, ConfigMap, PVC → all get deployed

### 10.5 Resulting Closure for myApp

```
myApp.main.closure:
  Service/myapp@production
  ├─ requires → Deployment/myapp@production
  │              └─ dep → Service/postgres@data          ← from ${postgres.service.fqdn}
  │                        ├─ requires → Deployment/postgres@data
  │                        │              └─ dep → PersistentVolumeClaim/postgres-data@data
  │                        └─ requires → ConfigMap/postgres-config@data

Deploy order:
  1. PVC/postgres-data
  2. ConfigMap/postgres-config
  3. Deployment/postgres
  4. Service/postgres
  5. Deployment/myapp
  6. Service/myapp
```

All inferred from native `${}` interpolation + `requires` annotations. No custom tracking code.

---

## 11. Summary

The design has two clear layers:

1. **Package level:** Dependency injection via the fixpoint/callPackage pattern. Packages receive their dependencies as arguments. This is the composition mechanism.

2. **Resource level:** Each K8s resource is a Nix derivation with proper hashing. Store paths enable native `${}` tracking. The Merkle DAG gives us change propagation, diffing, and caching for free.

The package is the DI boundary. The resource is the derivation boundary. Outputs don't split the closure (you always need the full service). Sub-components CAN split the closure (explicit seams for CRDs, storage, etc.).

What we eliminate: `refs.nix`, `resolve.nix`, `k8s.str` — ~170 lines of custom tracking code.
What we add: identity derivations, a registry, and a post-processor — ~50 lines.
What we gain: native `${}` everywhere, proper Merkle DAG hashing, and the full power of Nix's dependency tracking engine.
