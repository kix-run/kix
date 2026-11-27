# 65: Passthrough Instances — Abstract Dependencies Without K8s Resources

**Status:** Draft
**Related:** `63a_storage_as_cluster_concern.md` (storage as abstract infra), `64a_secret_origins_and_ownership.md` (secrets as abstract deps), `40_composite_packages.md` (composition), `29_compiler-design.md`

---

## 1. The Problem

Some infrastructure concepts are real dependencies but don't materialize as Kubernetes resources. An **S3 bucket** is the canonical example:

- It has a **provider** (minio, ceph, cloud-managed) → dependency
- It has **credentials** (access key, secret key) → dependency on a secret
- It has an **endpoint** and **bucket name** → `out` values consumers need
- But the bucket itself is not a K8s resource — it lives outside the cluster

Today, kix requires every instance to produce a `root` resource. This forces a choice:

1. **Don't model it at all** — consumers hardcode bucket names and credential references as config strings. No DI, no validation, no graph visibility. This is the Helm status quo.
2. **Create a fake resource** — wrap the concept in a CRD (like a `Bucket` CR) and deploy it. The resource exists purely as a DI anchor, not because anything reads it at runtime.
3. **Use `mkImport`** — model it as an import, but imports are for pre-existing cluster resources, not abstract concepts with their own dependency chains.

None of these are right. Option 1 breaks the DI story. Option 2 pollutes the cluster with meaningless CRDs. Option 3 abuses the import system — imports skip dependency resolution entirely.

What's needed: instances that participate fully in the DI graph (have deps, provide `out`, show up in `kix list`, contribute to the connection graph) but produce **zero K8s resources**.

### 1.1 More Examples Beyond S3

- **Database logical databases** — a postgres instance exists, but the *logical database* for immich (with its schema, extensions, user) is a concept, not a K8s resource. Today this is modeled implicitly via config on the postgres package.
- **DNS zones** — external-dns manages a zone, but the zone itself isn't a K8s resource. A package depending on "DNS" should resolve to the zone provider.
- **Cloud IAM bindings** — a workload identity binding is a cloud-side concept. The K8s ServiceAccount exists, but the IAM ↔ SA link doesn't.
- **TLS certificate authorities** — the CA is a concept. cert-manager's `ClusterIssuer` is a resource, but the *trust chain* it represents (root CA + intermediates) is an abstract dependency.
- **Feature flags / config providers** — LaunchDarkly, ConfigCat — the SDK key and endpoint are dependencies, but no K8s resource represents "the feature flag service."

The pattern: **infrastructure-as-a-service concepts that have real dependencies and consumers but live outside the K8s resource model.**

---

## 2. How the Eval System Handles Instances Today

### 2.1 Normal instances (instance.nix)

```
callPackagePhase1 → discoverBuildDeps → resolveDeclaredDeps
→ evaluateInstanceConfig → build fixpoint → root resource
→ forward closure → PackageInstance CRD → resource collection
```

The critical constraint: `root` must exist (line 199). The forward closure walks store-path references from `root`. The PackageInstance CRD records the root resource. Resource collection gathers everything reachable.

### 2.2 Import instances (import_.nix)

```
evaluateImportInstance → mkImportResource (marker CR only) → out derivation
```

Imports skip build entirely. They produce a lightweight marker CR and derive `out` from the package's declared outputs. No dependencies, no fixpoint, no closure.

### 2.3 The gap

Passthrough instances need something **between** these two paths:

| Capability | Normal | Import | Passthrough |
|---|---|---|---|
| Has dependencies (DI consumer) | ✅ | ❌ | ✅ |
| Provides `out` (DI provider) | ✅ | ✅ | ✅ |
| Has config options | ✅ | ❌ | ✅ |
| Produces K8s resources | ✅ | ❌ | ❌ |
| In resolution index | ✅ | ✅ | ✅ |
| In deploy graph | ✅ | ❌ | ❌ (but deps are) |
| In `kix list` | ✅ | ✅ | ✅ |

---

## 3. Approaches

### Approach A: `passthrough = true` Flag on Instance

The simplest option. Add a flag to the package definition that tells the evaluator to skip resource collection.

**Package:**
```nix
# packages/s3-bucket/default.nix
{ scope, lib, kix }:
{
  meta = {
    passthrough = true;  # No K8s resources produced
    defaultAliases = [ "objectStorage" "s3" ];
  };

  options = {
    bucket = lib.mkOption { type = lib.types.str; };
    endpoint = lib.mkOption { type = lib.types.str; };
    region = lib.mkOption { type = lib.types.str; default = "us-east-1"; };
  };

  build = { self, config, deps, s3Provider ? null, ... }: {
    # No resources — just derive out values from config + deps
    root = {
      out = {
        bucket = config.bucket;
        endpoint = config.endpoint;
        region = config.region;
        # Credentials come from the provider via DI
        credentials = s3Provider.out.credentials or null;
      };
    };
  };
}
```

**Cluster:**
```nix
instances.immich-ns = {
  immich-s3 = {
    package = packages.s3-bucket;
    config = {
      bucket = "immich-photos";
      endpoint = "s3.eu-central-1.amazonaws.com";
    };
  };

  immich = {
    package = packages.immich;
    # DI resolves s3 / objectStorage to immich-s3
  };
};
```

**What the evaluator does differently:**

```
callPackagePhase1 → discoverBuildDeps → resolveDeclaredDeps
→ evaluateInstanceConfig → build fixpoint → root.out (no root resource)
→ NO forward closure, NO resource collection
→ PackageInstance CRD? (see §5)
```

The `root` for a passthrough is not a resource — it's just an attrset with `out`. The evaluator skips the entire closure computation and resource collection.

**Pros:**
- Minimal change to the eval system — just a conditional branch in `instance.nix`
- Package author explicitly opts in — no ambiguity about what's happening
- Full DI participation — deps resolve normally, `out` is available to consumers
- Config options work normally

**Cons:**
- `root` becomes overloaded — sometimes a resource, sometimes just `{ out }`. This is a semantic divergence.
- The "deploy graph" question is unclear — if a passthrough has deps, those deps need to be deployed. But the passthrough itself doesn't. Who pulls the deps forward?

### Approach B: Passthrough as a `_type` (Like `kix-import`)

Instead of a flag, make passthrough a distinct package type with its own evaluation path, similar to how `kix-import` works.

**Package:**
```nix
# packages/s3-bucket/default.nix
kix.mkPassthrough {
  meta.defaultAliases = [ "objectStorage" "s3" ];

  options = {
    bucket = lib.mkOption { type = lib.types.str; };
    endpoint = lib.mkOption { type = lib.types.str; };
  };

  # Instead of `build`, use `resolve` — makes it clear no resources are produced
  resolve = { config, deps, s3Provider ? null, ... }: {
    bucket = config.bucket;
    endpoint = config.endpoint;
    credentials = s3Provider.out.credentials or null;
  };
}
```

**What the evaluator does:**

A new `evaluatePassthroughInstance` function alongside `evaluateInstance` and `evaluateImportInstance`. It:
1. Evaluates config options
2. Resolves DI deps (unlike imports, which skip this)
3. Calls `resolve` (not `build`) with deps
4. Wraps the result as `out` on a view object (no resources)

**Pros:**
- Clean separation — no overloading of `root`
- The `resolve` vs `build` naming makes intent clear
- Can have its own validation rules (e.g., warn if a passthrough has no consumers)
- Could support a simpler fixpoint (no `self` needed if there are no resources to cross-reference)

**Cons:**
- New evaluation path — more code to maintain
- `mkPassthrough` is a new API surface
- May be over-engineered for what is essentially "build but skip resource collection"

### Approach C: Cluster-Side Visibility via PackageInstance CR

Instead of a new CRD, reuse the existing PackageInstance CR. Every instance already gets a PI — for a passthrough, the PI simply has no owned resources and carries a `kix.dev/passthrough: "true"` annotation. The passthrough's `out` values can be serialized into the PI spec for cluster-side visibility (`kubectl get packageinstances`).

Note: PIs are **not part of the resource DAG** — they're metadata CRs collected separately in `cluster.nix`. So a passthrough PI doesn't help with deploy ordering or dependency tracking. That's pull-through's job. The PI is purely observability.

**Pros:**
- No new CRD — reuses existing infrastructure
- Unified view: `kix list` and `kubectl get packageinstances` show everything (real, import, passthrough)
- The PI is already deployed for every instance — this is just "keep doing that"

**Cons:**
- A PI with no owned resources might confuse `kix health` (what does "healthy" mean?)
- Minor: PI spec may need a small extension to carry passthrough output metadata

**This is orthogonal to pull-through.** Pull-through handles the graph; PI handles visibility. Both can exist independently.

### Approach D: Dependency Hoisting (No New Concept)

Instead of modeling passthroughs explicitly, **hoist their dependencies to consumers**. The S3 bucket isn't an instance — it's a configuration module that injects deps and config into the consuming package.

**Cluster definition:**
```nix
instances.immich-ns.immich = {
  package = packages.immich;
  config.s3 = {
    bucket = "immich-photos";
    endpoint = "s3.eu-central-1.amazonaws.com";
  };
  # The s3 config also brings in the secret dependency somehow
};
```

This doesn't work cleanly because:
- The S3 credentials are a separate dependency that the consumer (immich) shouldn't know about
- Multiple consumers sharing the same bucket can't share the config without duplication
- There's no DI resolution — every consumer must be manually configured

**Verdict:** This is the non-solution. It's what you do today without DI and it doesn't scale.

---

## 4. Recommendation: Approach A (Flag) + Dependency Pull-Through

### 4.1 Core Design

A passthrough instance is a normal instance with `meta.passthrough = true`. The evaluator:

1. **Evaluates normally** through phase 1 (options, config, dep discovery, dep resolution)
2. **Calls build** with the full `{ self, config, deps, ... }` — the package can compute derived values
3. **Expects `root.out`** but NOT `root.resource` — the root is just an `out` attrset
4. **Skips resource collection** — no forward closure, no inverse deps, no resource list
5. **Skips PackageInstance CRD** — no resource deployed for the passthrough itself
6. **Remains in the resolution index** — consumers resolve against it via DI normally
7. **Appears in `kix list`** — with a `(passthrough)` marker

### 4.2 The Deploy Graph Problem: Dependency Pull-Through

This is the core design challenge you identified. If a passthrough has dependencies, those deps need to be deployed. But the passthrough produces no resources, so it's not in the deploy graph. The dependency chain is broken:

```
immich → s3-bucket (passthrough) → minio (real) + s3-credentials (real)
```

Without the passthrough in the deploy graph, the link from immich to minio is lost.

**Solution: pull-through dependencies.** When a consumer resolves a passthrough via DI, the passthrough's own deps become implicit deps of the consumer. The deploy graph sees:

```
immich → minio (pulled through s3-bucket)
immich → s3-credentials (pulled through s3-bucket)
```

The passthrough acts as a transparent proxy in the dependency graph. Its deps are flattened into the consumer's dep set.

**Implementation:** In `instance.nix`, after resolving deps, check if any resolved dep is a passthrough. If so, recursively collect the passthrough's own resolved deps and merge them into the consumer's `resolvedDeps` (for graph purposes, not for the build function — the build function still sees the passthrough's `out`, not the raw deps).

This is the "pull requirements one node up" behavior you described.

### 4.3 What the Consumer Sees

The consumer package is completely unaware that its dependency is a passthrough:

```nix
# packages/immich/default.nix
{ scope, lib, kix }:
{
  build = { self, config, objectStorage, ... }: {
    deployment = {
      # ...
      env = {
        S3_BUCKET = objectStorage.out.bucket;
        S3_ENDPOINT = objectStorage.out.endpoint;
        # credentials would come from objectStorage.out.credentials.out.keyRef
      };
    } |> scope.mkDeployment;
  };
}
```

Same interface as any other DI dep. The consumer uses `objectStorage.out.bucket` regardless of whether the dep is a passthrough or a real minio instance.

### 4.4 What the Passthrough Package Looks Like

```nix
# packages/s3-bucket/default.nix
{ scope, lib, kix }:
{
  meta = {
    passthrough = true;
    defaultAliases = [ "objectStorage" "s3" ];
  };

  options = {
    bucket = lib.mkOption { type = lib.types.str; };
    endpoint = lib.mkOption { type = lib.types.str; };
    region = lib.mkOption { type = lib.types.str; default = "us-east-1"; };
  };

  # build still works — it just doesn't produce resources
  build = { self, config, s3Credentials ? null, ... }: {
    root = {
      # No `resource` field — just `out`
      out = {
        bucket = config.bucket;
        endpoint = config.endpoint;
        region = config.region;
        credentials = s3Credentials;
        # Convenience: pre-formatted connection URL
        url = "s3://${config.endpoint}/${config.bucket}";
      };
    };
  };
}
```

### 4.5 Cluster Definition

```nix
instances.immich-ns = {
  # The S3 provider (real instance with resources)
  minio = {
    package = packages.minio;
    config.rootPassword = "...";  # or via secret ref
  };

  # The bucket (passthrough — no resources, but has deps)
  immich-bucket = {
    package = packages.s3-bucket;
    aliases = [ "objectStorage" ];
    config = {
      bucket = "immich-photos";
      endpoint = "minio.immich-ns.svc.cluster.local:9000";
    };
    # s3Credentials resolves via DI to minio's credentials
  };

  # The consumer (depends on objectStorage, gets the passthrough)
  immich = {
    package = packages.immich;
    # objectStorage resolves to immich-bucket (passthrough)
    # immich-bucket's deps (minio, credentials) are pulled through
  };
};
```

---

## 5. Open Questions

### 5.1 PackageInstance CR for passthroughs

**Decision: yes** — reuse the existing PI, no new CRD needed. A passthrough PI has no owned resources and carries `kix.dev/passthrough: "true"`. This gives unified visibility in `kix list` and `kubectl get packageinstances` without introducing new infrastructure.

PIs are not part of the resource DAG (they're metadata CRs collected separately in `cluster.nix`), so a passthrough PI doesn't affect deploy ordering — that's entirely pull-through's job. The PI is purely observability and bookkeeping.

`kix health` should report passthrough PIs as `virtual` rather than healthy/degraded, since there are no owned resources to check.

### 5.2 How does pull-through interact with deploy ordering?

If immich depends on s3-bucket (passthrough) which depends on minio, the pull-through means immich implicitly depends on minio for deploy ordering. This is correct — immich can't function until minio is running.

But what about the wave system? Minio should be in an earlier wave than immich. Since pull-through adds minio to immich's dep set, the wave computation should handle this naturally — it already orders by dependency depth.

**Verify:** Does the wave computation in `cli/kix/src/deploy/plan.rs` use the DI dep graph or the store-path graph? If store-path, pull-through deps won't be visible. If DI, they should work.

### 5.3 Should build support `self`-references in passthroughs?

The `self` fixpoint exists because resources reference each other (a Deployment references a ServiceAccount's store path). Passthroughs don't have resources, so `self`-references are less useful. But they might still want to compute derived values:

```nix
build = { self, config, ... }: {
  # self.root.out.url is used by... nobody in the build. But it exists.
  root.out = {
    bucket = config.bucket;
    url = "s3://${config.endpoint}/${config.bucket}";
  };
};
```

**Probably yes** — keep `self` for consistency. The fixpoint is cheap when there are no store-path references to walk.

### 5.4 Can a passthrough depend on another passthrough?

```
immich → s3-bucket (passthrough) → cloud-credentials (passthrough) → secret-store (real)
```

Pull-through must be recursive. When resolving s3-bucket's deps for pull-through, if cloud-credentials is also a passthrough, its deps (secret-store) must also be pulled through to immich.

This is a transitive closure over passthroughs in the dep graph. Should be implementable as a simple recursive walk — but needs cycle detection (two passthroughs depending on each other is an error, not infinite recursion).

### 5.5 Pull-through and virtual resources are orthogonal

Pull-through is a **graph operation** — it answers "how do deploy ordering and dependency tracking work when a node produces no resources?" by flattening the passthrough's deps into its consumers.

Virtual resources are a **materialization choice** — they answer "should this concept have a cluster-side representation?" by deploying a lightweight marker CR.

These operate on different axes and are **not mutually exclusive**:

| | No virtual resource | Virtual resource |
|---|---|---|
| **No pull-through** | `mkImport` (today) | Normal instance |
| **Pull-through** | Pure passthrough (wiring only) | Passthrough with cluster-side marker |

A passthrough with a virtual resource still needs pull-through — the virtual CR is metadata, not something minio or credentials "depend on" in the store-path DAG. The deploy graph problem remains unless you artificially thread store-path references through the virtual CR's manifest, which is exactly the kind of hack pull-through avoids.

**Pull-through is the core mechanism** and should always be present for passthroughs. Virtual resources are an optional extra — a regular resource that happens to be deployed alongside an otherwise-resourceless instance. A package could make it conditional:

```nix
build = { self, config, ... }: {
  # Optional: deploy a marker CR for cluster-side visibility
  marker = lib.optionalAttrs config.deployMarker (
    kix.mkVirtualResource { kind = "S3Bucket"; ... } |> scope.mkResource
  );

  root.out = { bucket = config.bucket; ... };
};
```

If `marker` exists, it goes through the normal deploy path. Pull-through still handles deps that aren't reachable via store-path references in the marker's manifest.

**Cluster-side visibility:** Since we reuse the PackageInstance CR (see §5.1), every passthrough automatically gets a PI deployed into the cluster. No separate "virtual resource" CRD is needed. The PI carries the passthrough annotation and can optionally serialize `out` values into its spec for `kubectl` inspection. If a passthrough later evolves into a real instance (e.g., a bucket operator starts managing actual `Bucket` CRs), the PI naturally gains owned resources — no migration needed.

### 5.6 Naming: "passthrough" vs alternatives

- **passthrough** — emphasizes that deps pass through to consumers. Accurate but slightly obscure.
- **virtual** — emphasizes "not real" (no resources). Could be confused with virtual machines or virtual services.
- **abstract** — emphasizes the concept-level nature. Good, but "abstract package" sounds like a base class.
- **phantom** — Rust-inspired. "A phantom instance participates in the type system but has no runtime representation." Actually quite accurate.
- **facade** — from design patterns. The passthrough presents a unified interface to a set of deps. Decent.

**Leaning toward: `passthrough`** — it directly describes the deploy behavior (deps pass through to consumers). But `virtual` is also reasonable and might be more intuitive.

### 5.7 How does this interact with scorecard rules?

Scorecard currently evaluates at manifest, package, namespace, and cluster levels. Passthroughs have no manifests. Should scorecard skip them, or should there be passthrough-level rules?

Potential passthrough rules:
- "Every passthrough must have at least one consumer" (orphan detection)
- "S3 bucket credentials must not be inline" (security)
- "Passthrough deps must all be satisfiable" (validation)

These are useful but can wait — scorecard can simply skip passthroughs for now.

---

## 6. Implementation Sketch

### 6.1 Changes to `instance.nix`

After the build fixpoint (line ~196), check `packageMeta.passthrough`:

```nix
# After parts = lib.fix (...)
if packageMeta.passthrough or false then
  let
    # Passthrough: extract out from root, skip resource collection
    passthroughOut = parts.root.out
      or (throw "Passthrough instance '${instanceName}' must define root.out");

    view' = mkPassthroughView {
      inherit instanceName namespaceName packageMeta;
      out = passthroughOut;
      aliases = instCfg.aliases or [ ];
      resolvedDeps = resolvedDeps;  # Needed for pull-through
    };
  in
  view' // {
    _isPassthrough = true;
    _resolvedDeps = resolvedDeps;  # Exposed for pull-through computation
    _diagnostics = { ... };
  }

else
  # ... existing normal instance evaluation ...
```

### 6.2 Changes to `cluster.nix`

In `collectResources`, skip passthrough instances:

```nix
collectResources = inst:
  if inst._isPassthrough or false then []
  else /* existing logic */;
```

In the `packageIndex`, skip passthroughs (they have no store paths to track).

### 6.3 Pull-through in `resolve.nix` or `cluster.nix`

After the fixpoint is computed, add a post-pass that enriches each non-passthrough instance's dep metadata with the transitive closure of passthrough deps:

```nix
# Pseudo-code for pull-through
pullThroughDeps = inst:
  let
    directDeps = inst._resolvedDeps or {};
    passthroughDeps = lib.filterAttrs (_: dep:
      dep._isPassthrough or false
    ) directDeps;
    transitiveRealDeps = lib.concatMapAttrs (_: pt:
      lib.filterAttrs (_: d: !(d._isPassthrough or false))
        (pullThroughDeps pt)
    ) passthroughDeps;
  in
  directDeps // transitiveRealDeps;
```

This is conceptually clean but implementation-wise may conflict with the lazy fixpoint — accessing `_isPassthrough` on a dep forces that dep's evaluation. This is fine because DI already forces dep evaluation (to get `out`).

### 6.4 CLI changes

- `kix list`: show passthrough instances with a marker (e.g., `(virtual)` or `(passthrough)`)
- `kix deploy`: skip passthroughs in wave computation (they have no resources to apply)
- `kix health`: skip or report passthroughs as "N/A"
- `kix graph`: show passthroughs as dashed nodes (present in the dependency graph but not in the deploy graph)

---

## 7. Future: Passthrough + Operator = Real Resource

A compelling evolution: a passthrough today, a real resource tomorrow. If someone writes a bucket operator (CRD: `Bucket`), the `s3-bucket` package can drop `meta.passthrough = true` and start producing a `Bucket` CR instead. The DI interface (`out.bucket`, `out.endpoint`, `out.credentials`) stays identical. Consumers don't change.

This is the "virtual → concrete" upgrade path. It's the same pattern as `mkImport` → real instance — the DI interface is stable, the implementation behind it evolves.
