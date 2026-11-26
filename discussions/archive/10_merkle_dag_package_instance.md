# Full Nix Store Path Merkle DAG — PackageInstance & Inverse Dep Auto-Detection

**Status:** Implemented
**Files:** `lib/v2/k8s.nix`, `lib/v2/eval.nix`, `lib/v2/default.nix`, all `packages/*/default.nix`

---

## Problem

In the v2 design, some dependency relationships live outside the Merkle DAG. Specifically, inverse deps (e.g., SA←CRB) are modeled with a Nix-level `requires` field that doesn't appear in manifests or affect store path hashes. This means:

- The DAG is not the single source of truth — `requires` is a side-channel
- Inverse deps must be manually annotated on every ServiceAccount (`requires = [self.clusterRoleBinding]`)
- `computeClosure` must walk both `builtins.getContext` AND `requires`, making two separate dependency systems

The goal is to make the Merkle DAG the **sole** dependency tracker: all edges discoverable via `builtins.getContext` alone.

## Design Principles

1. **Forward ref deps** (e.g., Deployment → SA via `serviceAccountName = "${self.serviceAccount}"`): already tracked by `builtins.getContext` — no change needed.

2. **Forward non-ref deps** (e.g., Service → Deployment via label selector): expressed as `requires` on the resource or on `main`. These are NOT encoded as annotations on the individual resource (see "Circular Dependency Prevention" below). Instead, they are collected and placed on the PackageInstance CRD.

3. **Inverse deps** (e.g., CRB referencing SA): auto-detected by scanning which resources reference resources in the forward closure. Referenced from the PackageInstance CRD — NOT on the individual resource.

4. **PackageInstance CRD**: a real `kix.dev/v1alpha1` Kubernetes resource that serves as the root of each package's DAG subgraph. It holds references to the main resource, inverse deps, and all collected requires via `kix.dev/*` annotations.

5. **`main` becomes `{ resource = ...; requires = [...]; }`**: packages return a structured attrset instead of using `self.service // { requires = [...]; }`. The `resource` field is the primary resource; `requires` feeds into the PackageInstance.

## Circular Dependency Prevention

This is the critical constraint that shaped the design.

**The cycle:** CRB's manifest contains `${self.serviceAccount}` (CRB hash depends on SA hash). If we encoded `requires` as an annotation on the SA containing `${self.clusterRoleBinding}`, the SA hash would depend on CRB hash → **infinite recursion**.

**Less obvious cycle:** StatefulSet has `requires = [self.hpa]` (non-ref dep), and HPA has `spec.scaleTargetRef.name = "${self.statefulSet}"`. If we encoded requires as annotations on individual resources, the SS hash would depend on HPA hash (via annotation), and HPA hash would depend on SS hash (via spec) → cycle.

**Rule:** Individual resources NEVER get requires encoded in their manifests. All non-ref deps are collected and placed on the PackageInstance, which references all resources but is never referenced back (it's the root).

## PackageInstance CRD

Each evaluated instance gets a `kix.dev/v1alpha1 PackageInstance` resource:

```nix
mkPackageInstance = { instanceName, namespaceName, namespace, mainResource,
                      inverseDeps ? [], packageRequires ? [], version ? null, labels ? {} }:
  mkResource {
    apiVersion = "kix.dev/v1alpha1";
    kind = "PackageInstance";
    name = instanceName;
    inherit namespace labels;
    annotations = {
      "kix.dev/main" = "${mainResource}";
    }
    // lib.optionalAttrs (inverseDeps != []) {
      "kix.dev/inverse-deps" = builtins.concatStringsSep "," (map (r: "${r}") inverseDeps);
    }
    // lib.optionalAttrs (packageRequires != []) {
      "kix.dev/package-requires" = builtins.concatStringsSep "," (map (r: "${r}") packageRequires);
    };
    extra.spec = {
      inherit instanceName namespaceName;
    } // lib.optionalAttrs (version != null) { inherit version; };
  };
```

All references use `"${resource}"` interpolation → store paths tracked by `builtins.getContext` → full DAG edges in the Merkle tree.

The `postProcessManifest` function replaces store paths in ALL annotations (including `kix.dev/*`) with human-readable k8s resource names, so deployed manifests are readable.

## Inverse Dependency Auto-Detection

After the package fixpoint is evaluated, `evaluateInstance` automatically detects inverse deps:

1. **Collect** all resources from the fixpoint (filter for `_type == "k8s-resource"`, skip nulls)
2. **Build local mini-registry** from those resources (per-instance, not global — avoids chicken-and-egg issues)
3. **Compute forward closure** from `main.resource` + `main.requires` using `getContext` only
4. **Iterate to fixpoint:**
   - Find resources NOT in the forward set whose manifest (via `getContext`) references any resource in the forward set
   - Add them + their forward deps to the forward set
   - Repeat until no new resources are found
5. **Inverse deps** = (final forward set) − (initial forward closure)

This handles multi-level inverse deps (e.g., audit policy → CRB → SA). When an inverse dep is added, its own forward deps come along naturally via getContext.

### Why local mini-registry?

The auto-detection uses a per-instance registry, not the global cluster registry. This is because:
- The global registry doesn't exist yet during instance evaluation (chicken-and-egg)
- Inverse deps are always within the same package (a CRB always references an SA from the same package)

## Package Changes

### `main` pattern

Before:
```nix
main = self.service // { requires = [self.deployment, self.configmap]; };
```

After:
```nix
main = { resource = self.service; requires = [self.deployment, self.configmap]; };
```

`main.requires` feeds into the PackageInstance's `kix.dev/package-requires` annotation. `main.resource` becomes the primary resource referenced by `kix.dev/main`.

### Removed inverse dep requires

All ServiceAccount `requires = [self.clusterRoleBinding]` patterns are removed. The binding already contains `${self.serviceAccount}` in its subjects → forward ref tracked by getContext. The inverse direction (SA←CRB) is auto-detected.

Packages affected: coredns (2 SAs), ingress-nginx, cert-manager (4 SAs), velero, arc (3 SAs), event-logger, descheduler, reloader, external-dns.

### Forward non-ref requires kept

Forward deps not tracked via `${}` interpolation stay on the resource as `requires`. E.g., `deployment { requires = [self.ingressClass]; }` when the IngressClass isn't referenced in the deployment spec. These are collected and placed on the PackageInstance.

## Simplified `computeClosure`

Before:
```nix
queue = rest ++ (getDeps head) ++ (head.requires or []);
```

After:
```nix
queue = rest ++ (getDeps head);
```

All deps are discoverable through `builtins.getContext` alone. The PackageInstance's annotations contain store paths to all resources (main, inverse deps, collected requires), so starting from the PackageInstance, the entire closure is reachable.

## `evaluateInstance` Return Value

```nix
parts // {
  _type = "k8s-instance";
  _packageInstance = packageInstance;
  main = packageInstance;  # new closure root
  fqdn = mainRes.fqdn or null;
  out = mainRes.out or {};
  _meta = { ... };
}
```

`main` is now the PackageInstance (the closure root). `_packageInstance` is also exposed for direct access. The `fqdn` and `out` fields are forwarded from the original main resource.

## `buildCluster` Changes

`collectResources` now includes the PackageInstance resource alongside all resources from the fixpoint:

```nix
collectResources = inst:
  let
    parts = removeAttrs inst [ "_type" "_meta" "_packageInstance" "main" "fqdn" "out" "overrideParts" ];
    resources = lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "k8s-resource") parts;
  in
  builtins.attrValues resources
  ++ (if inst ? _packageInstance then [ inst._packageInstance ] else []);
```

## Store Path Sanitization

Resource names containing special characters (e.g., `:` in cert-manager's `leaderelection` roles) are sanitized for store path names:

```nix
sanitizedName = builtins.replaceStrings [ ":" ] [ "_" ] name;
```

This was previously hidden because those resources were only reached via the lazy `requires` field. With inverse dep auto-detection forcing evaluation of all resources, the store path creation is now eagerly triggered.

## Visualization Updates

`closureToDot` parses `kix.dev/requires` annotations to distinguish edge types:
- **Solid blue edges**: forward deps from manifest interpolation
- **Dashed red edges**: requires (non-ref deps) from `kix.dev/requires` annotation

`closureToTree` simplified to only show getContext-derived deps (no separate `req->` lines).

## Future Work

- **Phase 7: ClusterActivation CRD** — a `kix.dev/v1alpha1 ClusterActivation` resource listing root PackageInstance store paths, created in `buildCluster`. Lower priority.
- **Null sentinel** for conditional resources: `pdb = if enabled then mkResource {...} else null;` — enables cleaner conditional resource patterns.
