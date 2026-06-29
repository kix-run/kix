# Package anatomy

This chapter covers the shape of a kix package: the function (or inline attrset) signature, the four top-level keys (`meta`, `options`, `deps`, `build`), what the `build` function returns, the `self` lazy-recursive reference, the `root` entry-point convention, how nested resources are flattened into the consumer view, and the build-time warning system that flags structural mistakes. The `reloader` and `echo-server` packages are used as complete, real examples. Later chapters drill into the pieces: options (see 03-options-and-config.md), resources and `out` (see 04-resources-and-out.md), and dependency injection (see 07-dependency-injection.md).

## The two package shapes

A package lives at `kix/packages/<name>/default.nix` and evaluates to one of two shapes. Both normalize to the same internal form in `kix/lib/eval/resolve.nix` (`normalizePackage`).

**Function form** (most common): a function taking system args and returning the package attrset.

```nix
{ scope, lib, kix }:
{
  meta = { version = "1.27"; };
  options = { /* ... */ };
  build = { self, config, clusterConfig }: { /* named resources */ };
}
```

**Inline attrset form**: a plain attrset that already has a `build` key. No outer function, so it cannot receive `scope`/`lib`/`kix` at the top level (only `build` gets system args).

```nix
{
  meta = { version = "1.0"; };
  build = { self, config, scope, kix }: { /* ... */ };
}
```

`normalizePackage` detects the shape: an attrset with a `build` key is taken as-is; anything else is called as a function. The outer function is invoked with `{ scope, lib }` plus `kix` only if the function's arg set actually requests it (introspected via `builtins.functionArgs`). This is "phase 1": it runs before any resources are built, so the evaluator can read `meta`, `options`, and `deps` (and introspect `build`'s args) without forcing the inner fixpoint.

The four top-level keys:

| Key | Required | Purpose |
| --- | --- | --- |
| `meta` | no | Static metadata: `version`, `description`, `owner`, `lifecycle`, `provides`, `scope`, `network` (see 09-networking-and-meta.md). |
| `options` | no | Typed configuration via `lib.mkOption` (see 03-options-and-config.md). |
| `deps` | no | Per-dependency assertions/warnings enrichment. Dep *names* come from `build` args, not from here (see 07-dependency-injection.md). |
| `build` | yes | Function (or list of functions) returning the named-resource attrset. |

## The outer function args (phase 1)

The outer function receives only system args, never config or deps:

- `scope` - the namespace-bound resource factory and helpers (`scope.instanceName`, `scope.namespaceName`, `scope.mkResource`, `scope.mkDeployment`, `scope.rbac`, `scope.selectorLabels`, ...). See 04-resources-and-out.md.
- `lib` - nixpkgs lib, used for `mkOption`, `types`, `optionalAttrs`, etc.
- `kix` - the composition helpers (`kix.port`, `kix.service.fromWorkload`, ...), injected only if requested. See 06-composition-helpers.md.

Common idiom: bind `name` and any chart-derived label sets in the outer `let`, before the keys.

```nix
{ scope, lib, kix }:
let
  name = scope.instanceName;
in
{
  meta = { version = "1.27"; };
  options = { /* ... */ };
  build = { self, config, clusterConfig }: { /* ... */ };
}
```

## What `build` returns: named resources and `self`

`build` returns an attrset whose values are named resources (each carries a `_type` marker, typically `"k8s-resource"`). Keys are conventional and human-meaningful: `serviceAccount`, `deployment`, `configmap`, `service`, and the mandatory `root`.

`build`'s `self` arg is the **lazy fixpoint of this same return attrset**. The evaluator wires it with `lib.fix`, so a resource can reference a sibling resource's derived surface before it is "finished":

```nix
build = { self, config, clusterConfig }: {
  configmap = scope.mkResource { /* ... */ };

  deployment = {
    inherit name;
    spec.template.spec.volumes = [
      { name = "config"; configMap.name = self.configmap.out.name; }
    ];
    # ...
  } |> scope.mkDeployment;

  service = self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

  root = self.service;
};
```

Referencing `self.configmap.out.name` does two things: it reads the derived name, and (because `out.name` carries Nix string context pointing at the ConfigMap's store path) it records a DAG edge so the ConfigMap deploys before the Deployment. This is the "store-path = DAG edge" rule - resources never declare dependencies as plain data, they fall out of references (see 01-overview.md and 04-resources-and-out.md).

`self` is lazy and recursive: read `.out` of a sibling freely, but do not create a real cycle (A's manifest references B, B's references A) - that will not terminate.

## The system args injected into `build` (phase 2)

`build` runs inside the fixpoint ("phase 2"). The evaluator (`callBuildFn` in `kix/lib/eval/instance.nix`) always passes `self`, `config`, and `clusterConfig`, and conditionally passes `scope`, `lib`, `kix`, `deps` only if the build function's arg set requests them (arg introspection again). The reserved system arg names are:

```
self  config  clusterConfig  scope  lib  kix  deps
```

Any *other* arg in the `build` function's signature is treated as a **dependency** to resolve via DI (see 07-dependency-injection.md). So `{ self, config, postgres }` declares a required dep `postgres`; `{ self, config, postgres ? null }` declares it optional.

- `config` - the fully-evaluated, typed configuration (option defaults + cluster overrides + dep injections). See 03-options-and-config.md.
- `clusterConfig` - cluster-wide settings (`clusterDomain`, `cluster.capabilities`, `networkPolicy`, `scorecard`, ...).
- `deps` - the full resolved-deps attrset (rarely needed; usually you name individual deps as args instead).

## The `root` convention

Every package's `build` return **must** include `root` (the evaluator throws `must define 'root'` otherwise). `root` is the package's entry point - the resource whose readiness means "the package is up", and the anchor of the forward dependency closure. Two accepted forms (see `rawRoot` handling in `kix/lib/eval/instance.nix`):

**Direct resource** (most common):

```nix
root = self.service;     # echo-server: service is the entry point
root = self.deployment;  # reloader: deployment is the entry point
```

**Structured form** with explicit forward requirements and post-deploy hooks:

```nix
root = {
  resource = self.deployment;
  requires = [ self.serviceAccount ];   # structural forward deps (no string-context edge)
  postHooks = [ self.migrationJob ];    # deployed AFTER all package resources finish
  out = { /* extra outputs merged on top of root.out */ };
};
```

`requires` declares forward edges that are *not* expressed through manifest string context (for example a ServiceAccount a Deployment uses but does not name in a way that carries context). `postHooks` resources run after the rest of the package and gate the `PackageInstance` marker's completion (typically migration Jobs). `out` extends the package's public surface beyond what is auto-derived from the root resource (see 04-resources-and-out.md). If you pass a bare resource, `requires`/`postHooks`/`out` all default to empty.

## How the return attrset becomes the consumer view

The whole `build` return is the "parts" attrset. Two collection passes run over it:

1. **Typed resources** are gathered for deployment by `collectTypedAttrs` (`kix/lib/eval/helpers.nix`), which walks nested attrsets up to 3 levels deep, stops at any `_type` boundary, and excludes the `root` and `meta` keys. So you can group resources in plain sub-attrsets (folders) and they still get collected.
2. **The consumer view** (`mkPackageView` in `kix/lib/eval/view.nix`) builds what *other* packages see when they depend on this one. It has three layers, merged with collision detection:
   - **folders** - plain attrsets in `parts` (no `_type`, excluding `root`) are surfaced as nested groups.
   - **autoKeys** - everything from the root resource's `out` (`name`, `fqdn`, `selector`, ...) is copied to the top of the view, so consumers write `pg.fqdn` not `pg.out.fqdn`.
   - **system** - evaluator plumbing: `_type = "k8s-instance"`, `root`, `out`, `raw` (the full parts attrset), and `_meta` (instanceName, namespace, aliases, packageMeta, config).

The `_type` leaf marker is what distinguishes a resource from a folder: anything with `_type` is a typed leaf (collection stops there); a plain attrset without `_type` is a folder to descend into. Two folder names are "known" and content-checked - `secrets` and `crds` (see `knownFolders`): putting a resource *directly* on `parts.secrets` (instead of `parts.secrets.someName`) throws, and a wrong `_type` inside them emits a trace warning.

### Spreading extra resources with `//`

Because `build` returns a plain attrset, you can compute a group of resources separately and merge them in. `reloader` builds its RBAC set in the `let` and spreads it onto the return:

```nix
build = { self, config, clusterConfig }:
  let
    clusterRoles = mkClusterRoleSet scope { /* ... */ };
  in
  {
    serviceAccount = scope.mkResource { /* ... */ };
    deployment = { /* ... */ } |> scope.mkDeployment;
    service = if config.service.enabled then /* ... */ else null;
    root = self.deployment;
  }
  // clusterRoles;
```

Resources set to `null` (like the optional `service` above) are filtered out during collection, so conditional/modal parts are fine.

## Build-time warnings (must be fixed)

After the fixpoint settles, `kix/lib/eval/instance.nix` computes the forward closure from `root` (plus `requires` and `postHooks`) and emits structural warnings. Treat these as errors to fix, not noise:

- **Orphaned resource** - `resource 'Kind/name' is defined but not reachable from root`. The resource exists in `build`'s return but nothing in the forward closure (and no inverse dep) references it. Either wire it into the graph (reference it from a resource that is reachable, or list it in `root.requires`) or remove it. Inverse deps (a ClusterRoleBinding referencing a reachable ServiceAccount) are not orphans.
- **Redundant requires** - `resource ... has redundant requires on ... - already tracked via store path reference`. You listed something in `requires` that the manifest already references through string context. Drop it from `requires`.
- **Duplicate requires** - `resource ... requires ... multiple times`. The same resource appears twice in a `requires` list. De-duplicate.
- **Post-hook not ordered** - `post-hook ... does not depend on any forward-closure resource - it won't be ordered after root`. A `postHooks` entry that does not depend on any main package resource cannot be placed after them. Make it depend on `root` or one of its descendants.

These warnings are emitted before the view is constructed (via `builtins.seq` on `diagnostics.emitWarnings`), so they surface on every evaluation of the cluster.

## Complete minimal example: reloader

`reloader` (`kix/packages/reloader/default.nix`) is a self-contained package - no DI deps, just config and RBAC. Abridged to its skeleton:

```nix
{ scope, lib, kix }:
let
  name = scope.instanceName;
  reloaderSelectorLabels = { app = "${name}-reloader"; release = name; };
  inherit (scope.rbac) core group grant watch allow emit mkClusterRoleSet;
in
{
  meta = { version = "v1.3.0"; };

  options = {
    replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { repository = "ghcr.io/stakater/reloader"; tag = "v1.3.0"; pullPolicy = "IfNotPresent"; };
    };
    # ...
  };

  build = { self, config, clusterConfig }:
    let
      clusterRoles = mkClusterRoleSet scope {
        subjects = [ { kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = scope.namespaceName; } ];
        roles = { /* grant/watch/allow/emit rules */ };
      };
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1"; kind = "ServiceAccount"; name = "${name}-reloader";
      };

      deployment = {
        name = "${name}-reloader";
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = reloaderSelectorLabels;
          template.spec = {
            serviceAccountName = self.serviceAccount.out.name;
            containers = [ {
              name = "${name}-reloader";
              image = "${config.image.repository}:${config.image.tag}";
              ports = [ (kix.port "http" 9090) ];
              # ...
            } ];
          };
        };
      } |> scope.mkDeployment;

      service = if config.service.enabled then
        self.deployment |> kix.service.fromWorkload { name = "${name}-reloader"; } |> scope.mkResource
      else null;

      root = self.deployment;
    }
    // clusterRoles;
}
```

Things to notice, tying the chapter together:

- The outer function takes `{ scope, lib, kix }`; `build` takes `{ self, config, clusterConfig }` (no extra args, so no DI deps).
- `self.serviceAccount.out.name` is referenced from the Deployment's `serviceAccountName`: that reference both reads the name and records the deploy edge (SA before Deployment).
- The `service` is conditional - `null` when disabled, filtered out automatically.
- The ClusterRole/Binding set is computed in the `let` and spread with `// clusterRoles`. Those resources reference the ServiceAccount, so they are reachable as inverse deps and are not flagged as orphans.
- `root = self.deployment` makes the Deployment the entry point.

## Gotchas / common mistakes

- **Forgetting `root`** throws `must define 'root'`. Every package needs exactly one entry point.
- **`root` of the wrong type** throws `root must be a resource or { resource, requires, postHooks }`. A bare config attrset is not a resource - pass a `mkResource`/`mkDeployment` output or the structured `{ resource = ...; }` form.
- **Naming a `build` arg that collides with a real dep name** - any non-system arg is interpreted as a DI dependency. A typo like `{ self, config, postgrs }` becomes a *required* dep `postgrs` and fails resolution, not a config error.
- **Resource directly on a known folder** (`parts.secrets = someSecret`) throws; it must be `parts.secrets.<name> = someSecret`.
- **Orphaned resources** ship as warnings, not hard errors - it is easy to leave a half-wired resource that never deploys. Fix every structural warning.
- **Deep nesting beyond 3 levels**: `collectTypedAttrs` only descends 3 levels into folders. Resources buried deeper than `parts.a.b.c` are not collected.
- **`self` cycles**: referencing a sibling's `out` is fine and lazy, but a genuine mutual manifest reference (A names B and B names A) will not terminate.
