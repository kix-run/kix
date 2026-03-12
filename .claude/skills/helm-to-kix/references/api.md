# Fixpoint API Reference

## k8s.mkResource

Creates a K8s resource with automatic dependency tracking.

```
k8s.mkResource {
  apiVersion : string       # required — "v1", "apps/v1", "rbac.authorization.k8s.io/v1", etc.
  kind       : string       # required — "Deployment", "Service", "ConfigMap", etc.
  name       : string       # required — metadata.name (human-readable)
  namespace  : string|null  # default "default" — null for cluster-scoped resources
  labels     : attrset      # default {} — metadata.labels
  annotations: attrset      # default {} — metadata.annotations (tree-walked for refs)
  spec       : attrset      # default {} — resource spec (tree-walked for refs)
  data       : attrset      # default {} — for ConfigMaps
  stringData : attrset      # default {} — for Secrets
  rules      : list|null    # default null — for ClusterRole/Role (top-level, not under spec)
  subjects   : list|null    # default null — for *RoleBinding (top-level)
  roleRef    : attrset|null # default null — for *RoleBinding (top-level)
  webhooks   : list|null    # default null — for *WebhookConfiguration (top-level)
  outputs    : attrset      # default {} — named outputs exposed as refs
  requires   : list         # default [] — inverted deps (resources I need that reference me)
  extraDeps  : list         # default [] — ordering-only deps (not included in spec)
  extra      : attrset      # default {} — additional top-level fields (recursiveUpdate into manifest)
}
```

### Returns

```
{
  _type     = "k8s-resource";
  ref       : Ref            # mkRef self "ref" name — use in other resources' specs
  out       : { <key> = Ref } # one Ref per outputs entry
  deps      : [Resource]     # auto-inferred from refs in spec/data/annotations/etc
  requires  : [Resource]     # manual inverted deps (passed through)
  closure   : [Resource]     # transitive closure (deps + requires, BFS order)
  manifest  : attrset        # resolved K8s manifest (refs replaced with plain values)
  apiVersion, kind, name, namespace  # identity fields
}
```

## k8s.mkPackage

```
k8s.mkPackage : (args -> self -> { ..resources.., main = ... }) -> defaults -> Package
```

- `packageFn`: takes default args and self (fixpoint), returns attrset of resources
- `defaults`: default argument values (used by .override)
- Must define `main` — the public interface resource

### Package operations

```
pkg.ref            # shortcut for pkg.main.ref
pkg.out            # shortcut for pkg.main.out
pkg.closure        # pkg.main.closure — all resources needed to deploy
pkg.closureOf res  # closure from a different root
pkg.override args  # argument override (like nixpkgs .override) — replaces defaults // args
pkg.overrideParts fn  # inner fixpoint override (self -> super -> { overridden parts })
```

**Important**: `.override` replaces ENTIRE argument values. It does NOT deep-merge.
`pkg.override { sentinel.enabled = true; }` does NOT work — you must provide the full `sentinel` attrset.

## k8s.withRequires

```
k8s.withRequires : [Resource] -> Resource -> Resource
```

Wraps an existing resource with additional requires AND recomputes closure. Must use this instead of `//` because `//` inherits the pre-computed closure.

## k8s.mkCluster

```
k8s.mkCluster { basePackages : self -> { <name> = Package; ... }; overlays ? []; }
```

Returns: `{ packages, manifests, dagDot, dagTree, _type = "k8s-cluster" } // <all packages>`

## k8s.str

```
k8s.str : [string|int|Ref] -> TrackedString
```

Tracked string concatenation. Preserves ref metadata through concatenation. The tree walker resolves all parts and collects deps from ref parts.

## k8s.mkRef / k8s.isRef / k8s.isTrackedStr

Low-level primitives. Normally not called directly — mkResource creates refs automatically via `.ref` and `.out`.

## k8s.computeClosure / k8s.closureManifests

```
computeClosure : Resource -> [Resource]     # transitive BFS closure
closureManifests : Resource -> [Manifest]   # just the .manifest fields
```

## k8s.closureToDot / k8s.closureToTree

Debug visualization. Render a resource's closure as Graphviz DOT or a text tree.

## k8s.clusterToDot / k8s.clusterToTree

Same as above but for arbitrary resource lists (used by mkCluster).

## k8s.applyOverlays

```
applyOverlays : [self -> super -> { ... }] -> (self -> { ... }) -> AttrSet
```

nixpkgs-style overlay composition, left-to-right. Used internally by mkCluster.
