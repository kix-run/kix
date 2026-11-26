# Resource Type Tags — Eval-Time Type Safety in Nix

## Working Document — March 2026

**Status:** Design exploration
**Related:** `29_compiler-design.md` (compiler design, esp. §7.4 "errors should be impossible, not detected"), `10_merkle_dag_package_instance.md` (content-addressed DAG)

---

## 1. The Problem

Nix has no type system. kix compensates with runtime validation (`checks.nix`), but these checks run as separate derivations *after* evaluation. The error surfaces late and far from the source. The compiler design (§7.4) states a clear priority:

1. **Make the error structurally impossible** (best)
2. **Detect the error at eval time** (good)
3. **Warn about unchecked territory** (acceptable)

Today most cross-resource wiring errors land at level 3 or below — they're caught (if at all) by post-hoc manifest walking in `checks.nix`, or only at apply time by Kubernetes itself.

This document explores how to push errors to level 1 or 2 using **type tags** on resources — lightweight markers that constructors attach and consumers assert on, without needing a real type system.

---

## 2. Motivating Example: Headless Services

A StatefulSet's `spec.serviceName` must reference a **headless** Service (`clusterIP: None`). If you pass a regular ClusterIP Service, the StatefulSet creates but pod DNS doesn't work — a runtime failure.

The current state:

```nix
# harbor/default.nix — the bug
redisService = scope.mkResource {
  kind = "Service";
  name = "${name}-redis";
  spec = {
    type = "ClusterIP";  # ← wrong, should be headless
    # ...
  };
};

redisStatefulSet = ... {
  spec.serviceName = self.redisService.name;  # accepts any string
};
```

`checks.nix` catches this, but only during `nix flake check`, and only because it walks every StatefulSet and searches for a matching headless Service by name. The package author gets no feedback at the point of error.

### Why we can't just check the Service from the StatefulSet

The obvious fix — have `mkStatefulSet` accept a service resource and inspect `rawManifest.spec.clusterIP` — creates a **circular dependency**:

```
StatefulSet reads Service.rawManifest → forces Service evaluation
Service has requires = [ StatefulSet ] → forces StatefulSet evaluation
→ infinite recursion
```

The `rawManifest` includes dependency context via `manifestJsonWithDeps` (k8s.nix:175), so reading it forces evaluation of the full dependency chain. This is why `scope.nix:72` warns against using `.out.name` (context-carrying) in `serviceName`.

### The solution: tags are set before the store path is computed

A tag like `_headless = true` can be attached to the resource *before* `mkResource` computes the store path and wires up `requires`. Tags are cheap metadata on the Nix attrset — reading them doesn't force the content-addressed computation or the dependency chain.

---

## 3. Tag-Based Typing: The Pattern

The pattern has three parts:

### 3.1 Producer: Constructor attaches a tag

```nix
# In scope or a helper
mkHeadlessService = attrs:
  scopeMkResource (attrs // {
    spec = (attrs.spec or {}) // { clusterIP = "None"; };
  }) // {
    _serviceType = "headless";
  };
```

The tag `_serviceType = "headless"` is on the outer attrset, not inside `rawManifest`. It costs nothing to read.

### 3.2 Consumer: Constructor asserts the tag

```nix
mkStatefulSet = attrs:
  let
    hs = attrs.headlessService or null;
    svcName =
      if hs != null then
        assert (hs._serviceType or "") == "headless"
          || throw "mkStatefulSet: headlessService must be created with mkHeadlessService (got ${hs._serviceType or "untagged"})";
        hs.name
      else
        attrs.spec.serviceName or (throw "mkStatefulSet: either headlessService or spec.serviceName is required");
  in
  mkWorkload "apps/v1" "StatefulSet" (
    removeAttrs attrs [ "headlessService" ]
    // lib.optionalAttrs (hs != null) {
      spec = (attrs.spec or {}) // { serviceName = svcName; };
    }
  );
```

### 3.3 Escape hatch: Raw strings still work

Packages that manage their own services outside kix (openebs, stackgres) continue to pass `spec.serviceName` as a raw string. The tag check only applies when `headlessService` is used. This follows the compiler design principle: compile what you can, don't block what you can't.

---

## 4. Where Else Tags Apply

The headless service is one instance of a general pattern: **a constructor produces a resource with a property, and a consumer needs to assert that property**. Scanning the codebase and the compiler design doc (§4), here are the other cases:

### 4.1 CRD → CR Reference (already exists)

`mkCRD` and `mkCRDRef` already use `_type = "crd-ref"` to tag CRD references. `mkCR` accepts a CRD resource and reads `.out.mkCR` from it. This is the tag pattern — the tag here is `_type` plus the `.out.mkCR` builder method.

This is actually the most sophisticated version: the tag isn't just a boolean, it's a **capability** (the `mkCR` function). The CRD doesn't just say "I am a CRD," it provides a function that knows how to create CRs for it. The consumer doesn't check a flag — it uses the capability.

### 4.2 ClusterIssuer → Certificate

`clusterIssuer.out.withCert` is another capability-as-tag: the ClusterIssuer resource exposes a function that creates Certificates referencing it. If you have a `withCert` function, the issuer reference is guaranteed correct by construction.

### 4.3 Workload → Service (selector matching)

Services that target a workload need matching selectors. Currently `scope.selectorLabels` provides a shared value, but nothing *enforces* that the Service's selector actually came from the workload. A typed reference could:

```nix
mkServiceFor = workload: attrs:
  assert (workload._type or "") == "k8s-resource"
    && builtins.elem workload.kind [ "Deployment" "StatefulSet" "DaemonSet" ];
  scopeMkResource (attrs // {
    spec = (attrs.spec or {}) // {
      selector = workload.rawManifest.spec.selector.matchLabels;
    };
  });
```

**Caveat:** This reads `workload.rawManifest`, which *does* force workload evaluation. But the dependency direction is safe here — Service depends on Workload, not the other way around. The circular dependency problem only arises when both directions carry evaluation-forcing references.

### 4.4 PVC → Volume Mount

Storage wiring (PVC name in volume, matching name in volumeMount) could use a tag that carries the PVC's name and storage class, so `mkVolumeMount` can reference a PVC resource directly rather than a string.

### 4.5 RBAC: ServiceAccount → RoleBinding

`rbac.mkRoleSet` already compiles SA + Role + Binding from a single declaration. But when a workload references a ServiceAccount by name, nothing verifies the SA exists. A tagged SA resource passed to the workload constructor would make invalid SA references a Nix eval error.

### 4.6 Ingress → Service backend

An Ingress backend references a Service by name and port. If the Ingress constructor accepted a Service resource (tagged with its ports), it could verify the port exists.

---

## 5. Tags vs. Capabilities: Two Flavors

Looking at the existing patterns and proposed ones, there are two distinct flavors:

### Boolean tags (simple flags)

```nix
resource // { _headless = true; }
```

Consumer does: `assert resource._headless or false`. Cheap, obvious, easy to grep for. Good for properties that are binary (headless/not, cluster-scoped/not).

### Capability tags (builder functions)

```nix
crdResource // { out = crdResource.out // { mkCR = ...; }; }
```

Consumer does: `crd.out.mkCR scope args`. The tag IS the API. Good for properties that carry behavior — "I am a CRD" means "I can create CRs," not just "I have a flag."

The capability pattern is strictly more powerful: it makes the correct usage the *only* usage. You can't misuse `mkCR` because the function already knows its CRD's group, version, and scope. The boolean tag only prevents the wrong resource from being passed — the consumer still has to do the right thing with it.

**Guideline:** Use capability tags when the producer knows how consumers should use it. Use boolean tags when the consumer's usage varies.

---

## 6. The Circular Dependency Constraint

The reason this whole approach exists (rather than just inspecting `rawManifest`) is the circular dependency problem. It's worth stating precisely when it occurs and when it doesn't.

**Circular dependency happens when:** Resource A's `rawManifest` or store path depends on Resource B, AND B's `rawManifest` or store path depends on A. This can be through `requires`, `extraDeps`, or Nix string context from interpolating `.out.name` values.

**Tags avoid this because:** Tags are plain Nix attributes on the outer attrset. Reading `resource._headless` does not force evaluation of `resource.rawManifest`, `resource.outPath`, or any dependency chain. Nix's laziness means the tag is available instantly.

**Safe to read (no forced evaluation):**
- `resource._type`, `resource._headless`, or any custom tag
- `resource.name` (plain string, set before store path computation)
- `resource.kind`, `resource.apiVersion`

**Unsafe to read from a potential dependency:**
- `resource.rawManifest` (forces content computation + all dep contexts)
- `resource.out.name` (carries store-path context, creates DAG edge)
- `resource.outPath` (the store path itself)

**Safe when dependency is one-directional:**
- `resource.rawManifest` is fine to read if the reader does NOT appear in the resource's `requires` or string context. E.g., a Service reading a Deployment's `rawManifest.spec.selector` is safe because the Deployment doesn't depend on the Service.

---

## 7. Interaction with the Rust Oracle

The compiler design (§9.4, `36_rust_oracle_at_fixpoint.md`) proposes a Rust oracle callable during Nix fixpoint evaluation. Tags complement rather than compete with this:

- **Tags handle structural constraints** — "this resource IS a headless service" — that are cheap to check in pure Nix. No oracle call needed.
- **The oracle handles semantic constraints** — "does this port actually exist on the target service?" — that require indexed lookups across the full resource graph.

Tags reduce the oracle's workload by eliminating a class of errors before the oracle is even consulted. The oracle focuses on whole-cluster analysis (§5, passes 4-5 in the compiler taxonomy) rather than local wiring.

---

## 8. Relation to checks.nix

Tags don't replace `checks.nix`. They handle different cases:

| Scenario | Tags | checks.nix |
|---|---|---|
| StatefulSet with non-headless Service | Tag on `mkHeadlessService` | Walks all StatefulSets post-hoc |
| Service selector not matching any workload | `mkServiceFor` reads workload selector | Walks all Services, matches selectors |
| Raw string `serviceName` (external) | Can't check (escape hatch) | Walks and validates |
| Orphaned resources | Can't check (needs whole-cluster view) | Graph analysis |
| CR field violating CRD schema | Can't check (needs schema knowledge) | Schema validation pass |

**Tags handle the "I have the resource object" case.** `checks.nix` handles the "I only have the serialized manifest" case. Both are needed. As more wiring moves through typed constructors, the tag coverage grows and `checks.nix` becomes a safety net rather than the primary error path.

---

## 9. Migration Path

### Phase 1: Introduce tagged constructors alongside existing ones

Add `scope.mkHeadlessService` without removing `scope.mkResource` for Services. Packages that create headless services switch to the new constructor. `mkStatefulSet` gains optional `headlessService` parameter.

No existing code breaks. New code gets eval-time checking.

### Phase 2: Add tags to more resource types

As patterns from §4 are implemented, add tagged constructors: `mkServiceFor`, PVC-aware volume helpers, typed SA references. Each is opt-in — raw `mkResource` always remains.

### Phase 3: Lint for untagged usage

A diagnostic pass (or the Rust oracle) can warn when a resource *could* have used a tagged constructor but didn't. "This Service has `clusterIP: None` but wasn't created with `mkHeadlessService` — consider using the typed constructor." This is a migration aid, not an error.

---

## 10. Open Questions

1. **Tag namespace.** Should tags use a flat namespace (`_headless`, `_serviceType`) or a structured one (`_kix.service.headless`)? Flat is simpler to assert; structured avoids collisions as the system grows.

2. **Tag visibility.** Should tags appear in `rawManifest` / serialized output, or only on the Nix-side attrset? Currently leaning toward Nix-only — tags are compiler metadata, not K8s metadata.

3. **Composition.** If a resource has multiple tags (headless + monitoring-port + owned-by-operator), how do they compose? Individual boolean attrs are simplest but could proliferate. An alternative is a `_tags` set: `_tags = { headless = true; monitoring = { port = 9090; }; }`.

4. **Capability vs. tag for headless.** Should `mkHeadlessService` just set a tag, or should it also expose a capability like `out.asStatefulSetService` that returns the plain name? The capability pattern would look like:
   ```nix
   # Producer
   mkHeadlessService = attrs: let svc = scopeMkResource ...; in
     svc // { out = svc.out // { statefulSetServiceName = svc.name; }; };

   # Consumer
   mkStatefulSet = attrs: ... {
     spec.serviceName = attrs.headlessService.out.statefulSetServiceName;
   };
   ```
   Accessing a non-existent attr (`out.statefulSetServiceName` on a regular Service) is already a Nix eval error — no explicit assert needed. This is "making the error structurally impossible" (level 1) rather than "detecting it" (level 2).

5. **How far do we push this?** Every K8s cross-resource reference *could* be typed. But over-tagging turns kix into a framework that wraps K8s rather than a compiler that understands it. The line: **tag wiring that the compiler derives** (selectors, service references, RBAC bindings). Don't tag arbitrary manifest fields — that's what kubeconform is for.
