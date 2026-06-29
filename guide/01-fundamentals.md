# Fundamentals

What a package is, its shape, and how config flows in.

Sections: [Overview & mental model](#overview--mental-model) · [Package anatomy](#package-anatomy) · [Options & config](#options--config)

## Overview & mental model

Authoring reference for kix packages. Grounded in `kix/lib/k8s.nix`, `kix/lib/eval/cluster.nix`, `kix/lib/architecture.md`.

### What kix is

- Kubernetes manifest compiler written in Nix.
- Input: resources as Nix data. Output: directory of plain YAML. Deploy: separate Rust CLI, in dependency order.
- Two file kinds per cluster:
  - **package** (`kix/packages/<name>/default.nix`) - reusable, parameterized set of related K8s resources (e.g. ConfigMap + Deployment + Service).
  - **cluster** (`clusters/<name>.nix`) - wires packages into namespaces, sets config, calls `kix.buildCluster`.

### What a package is

Function (or plain attrset "inline" form when no outer args):

```nix
{ scope, lib, kix, ... }:
{
  meta = { version = "1.27"; };
  options = { /* lib.mkOption declarations */ };
  build = { self, config, ... }: {
    root = scope.mkResource { /* ... */ };
  };
}
```

Keys:

| Key | Required | Purpose | Ref |
|-----|----------|---------|-----|
| `meta` | optional | version, description, `provides`, default aliases | 03-advanced.md#networking--package-meta |
| `options` | optional | typed config schema via `lib.mkOption` | 01-fundamentals.md#options--config |
| `deps` | optional | dependency enrichment hooks | 02-authoring.md#dependency-injection |
| `build` | required | function (or list of functions) returning "self" attrset of named resources | - |

- `build` args: `self` (lazy fixpoint of this package's resources), `config` (evaluated option values), named dependency args (e.g. `{ self, config, postgres ? null, ... }`).
- Returned attrset keys: `root` = entry point; siblings `service`, `ingress`, `configmap`, etc.
- Reference package: `kix/packages/echo-server/default.nix` returns `configmap`, `deployment`, `service`, `root = self.service`.

### Evaluation pipeline

`kix.buildCluster` (`kix/lib/eval/cluster.nix`) orchestrates. Stages:

1. **Flake to buildCluster.** `mkFlake` (or raw `buildCluster`) hands module list to cluster builder.
2. **evalModules.** `lib.evalModules` merges cluster config (instances, namespaces, `cluster.*`, scorecard, networkPolicy). Values lazy; `ref` fixpoint exposed via `specialArgs`, not forced.
3. **Auto-instantiate.** `computeAutoInstances` activates optional deps + implicit instances. Explicit instances win over auto.
4. **Resolution index.** `buildResolutionIndex` = DNS-like map of instance names + aliases for resolving dep args.
5. **Phase-1 pre-pass.** Each package called with minimal scope (naming only). kix introspects `build` signature for dep args, resolves targets, lets deps inject config (e.g. prometheus dep adds ServiceMonitor). `build` inspected, NOT executed.
6. **Per-instance fixpoint.** `lib.fix` over instances. `evaluateInstance` per instance: builds per-instance `scope`, binds resolved dep instances, runs `build()`, collects resources, derives network policies, runs scorecard rules. Fixpoint => `self.x` and cross-instance refs resolve lazily.
7. **Aggregate.** Collect all resources across active instances; build `PackageInstance` CR per instance; build one cluster-level `Activation` CR referencing every PackageInstance.
8. **YAML.** Render aggregated manifests to directory of YAML.

- Phase-2a "config-only" fixpoint between 5 and 6 resolves function-shaped config injections without build cycles. Ignore until writing a dep that projects consumer config into a dependency; see 03-advanced.md#overrides.

### Store-path = DAG edge (core idea)

- No `dependsOn` field. Dependencies fall out of how you reference other resources.
- Every resource built by `mkResource` (`kix/lib/k8s.nix`) writes manifest JSON to content-addressed store path via `builtins.toFile`.
- Resource public values (`out.name`, `out.fqdn`, `out.selector`, `out.identityHash`) = real string (e.g. `"echo-server"`) with the resource's store-path **Nix string context** attached.
- Embedding another resource's `out.name` => referencing manifest's JSON inherits that string context.
- `mkResource` reads context back off JSON:

```nix
implicitCtxPaths = builtins.filter (p: lib.hasPrefix "/nix/store/" p) (
  builtins.attrNames (builtins.getContext manifestJson)
);
```

- Stamps each referenced store hash into `kix.dev/depends-on` annotation. Referencing `self.configmap.out.name` from a volume mount => real DAG edge (Deployment depends on ConfigMap). CLI walks store DAG for deploy order + waves.
- Prefer `self.svc.out.name` (or `"${self.svc}"` interpolation, embeds store path) over hardcoded string. Hardcoded `"echo-server"` carries no context => no edge => unconstrained deploy order.

`k8s.nix` helpers:

- `attachCtxDeep ctx value` - recursively attach store-path context to every string leaf; used for `self.x.manifest` field access.
- `extractStoreHash path` - pull 32-char hash from store path for depends-on annotation.
- `requires` / `extraDeps` - explicit edges when no value flows between resources (dep contributes context without appearing in manifest body).

### Manifests keep real names; context rides alongside

- Emitted YAML contains plain K8s names (`metadata.name: echo-server`), never store paths.
- Dependency info travels next to strings via Nix string-context, not inside them.
- `mkResource` sanitizes context off store-path filename (cannot carry references) but keeps full context on file content => every dep edge survives. Manifests stay human-readable and `kubectl apply`-able while encoding full graph.
- `_kix.*` reserved keys carry internal metadata (cross-namespace validation, provenance). `stripKixMeta` removes them before serialization; no marker leaks into YAML.

### Activation CR roots the closure

- `mkActivation` (`k8s.nix`) builds single cluster-scoped `Activation` CR. `spec.instances` references every `PackageInstance` by name, each ref carrying that PI's store-path context.
- Every PI references its resources => `nix-store -q --tree` (or `exportReferencesGraph`) on Activation derivation yields entire cluster deploy DAG.
- Contract for CLI: Activation = single root, whole closure reachable. Each `PackageInstance` = per-package sub-root (stamps `kix.dev/root`, inverse-deps, package-level requires).

### End-to-end: one package, one instance

Single-resource package emitting one ConfigMap:

```nix
# kix/packages/banner/default.nix
{ scope, lib, ... }:
{
  meta = { version = "1.0.0"; };

  options = {
    message = lib.mkOption {
      type = lib.types.str;
      default = "hello from kix";
    };
  };

  build = { config, ... }: {
    root = scope.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = scope.instanceName;
      data."message.txt" = config.message;
    };
  };
}
```

Wire into a cluster instance (same shape as `clusters/example.nix`):

```nix
{ kix, packages }:
kix.buildCluster {
  name = "demo";
  modules = [{
    namespaces.apps = { };
    instances.apps.banner = {
      package = packages.banner;
      config.message = "deployed by kix";
    };
  }];
}
```

- `buildCluster` emits: `ConfigMap/banner` in ns `apps`, `PackageInstance/banner`, two kix CRDs, the namespace, one `Activation`.
- `scope.instanceName` resolves to `banner` (instance key); resource named by cluster wiring, not hardcoded.

Next:

- Package shape, `self`, `root`, warnings - 01-fundamentals.md#package-anatomy.
- Options and config flow - 01-fundamentals.md#options--config.
- `scope.mkResource` / `mkClusterResource` and `out` API - 02-authoring.md#resources-and-the-out-surface.
- Dependency injection, two-phase calling model - 02-authoring.md#dependency-injection.

### Gotchas

- **Hardcoded names break ordering.** Literal `"echo-server"` carries no store-path context => no edge. Reference `self.x.out.name` / `"${self.x}"`.
- **Non-string manifest leaves not tracked.** `attachCtxDeep` traces a warning for int/bool leaves (context cannot ride on them). Dep tracking flows only through strings; use `requires`/`extraDeps` when no string flows.
- **`extra.*` cannot shadow managed fields.** `mkResource` throws if `extra` sets `spec`, `data`, `stringData`, or `metadata.{name,namespace}` (dedicated args carry DI tracking). `extra` is only for sibling K8s fields kix does not model.
- **`_type` marks a leaf.** Resource collection stops descending at any attrset carrying `_type` (e.g. `k8s-resource`); flattens nested resources in `self` without eating into the resource.
- **Activation must reach everything.** A resource not transitively referenced from a PackageInstance (referenced by Activation) is outside the closure; CLI won't see it. Edges come from references => unreferenced resource is an orphan.

## Package anatomy

Package signature, the four top-level keys, `build` return + `self` fixpoint, `root`, consumer-view flattening, build-time warnings. Sources: `kix/lib/eval/resolve.nix` (normalize), `kix/lib/eval/instance.nix` (build call, warnings), `kix/lib/eval/view.nix` (consumer view). Examples: `reloader`, `echo-server`.

### The two package shapes

- Location: `kix/packages/<name>/default.nix`.
- Both normalize via `normalizePackage` (`kix/lib/eval/resolve.nix`).
- Detection: attrset with a `build` key taken as-is; anything else called as a function.
- Outer function invoked with `{ scope, lib }` plus `kix` only if its arg set requests it (`builtins.functionArgs`).
- "Phase 1": runs before resources are built; evaluator reads `meta`/`options`/`deps` and introspects `build` args without forcing the inner fixpoint.

Function form (most common): function taking system args, returning the package attrset.

```nix
{ scope, lib, kix }:
{
  meta = { version = "1.27"; };
  options = { /* ... */ };
  build = { self, config, clusterConfig }: { /* named resources */ };
}
```

Inline attrset form: plain attrset already having a `build` key. No outer function, so it cannot receive `scope`/`lib`/`kix` at top level (only `build` gets system args).

```nix
{
  meta = { version = "1.0"; };
  build = { self, config, scope, kix }: { /* ... */ };
}
```

### Four top-level keys

| Key | Required | Purpose |
| --- | --- | --- |
| `meta` | no | Static metadata: `version`, `description`, `owner`, `lifecycle`, `provides`, `scope`, `network` (see 03-advanced.md#networking--package-meta). |
| `options` | no | Typed configuration via `lib.mkOption` (see 01-fundamentals.md#options--config). |
| `deps` | no | Per-dependency assertions/warnings enrichment. Dep *names* come from `build` args, not here (see 02-authoring.md#dependency-injection). |
| `build` | yes | Function (or list of functions) returning the named-resource attrset. |

### Outer function args (phase 1)

System args only, never config or deps:

- `scope` - namespace-bound resource factory and helpers (`scope.instanceName`, `scope.namespaceName`, `scope.mkResource`, `scope.mkDeployment`, `scope.rbac`, `scope.selectorLabels`, ...). See 02-authoring.md#resources-and-the-out-surface.
- `lib` - nixpkgs lib (`mkOption`, `types`, `optionalAttrs`, ...).
- `kix` - composition helpers (`kix.port`, `kix.service.fromWorkload`, ...), injected only if requested. See 02-authoring.md#composition-helpers-kix.

Idiom: bind `name` and chart-derived label sets in the outer `let`, before the keys.

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

### `build` return: named resources and `self`

- Returns attrset whose values are named resources (each carries a `_type` marker, typically `"k8s-resource"`).
- Keys are conventional/human-meaningful: `serviceAccount`, `deployment`, `configmap`, `service`, and the mandatory `root`.
- `self` = lazy fixpoint of this same return attrset, wired with `lib.fix`. A resource can reference a sibling's derived surface before it is finished.

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

- `self.configmap.out.name` reads the derived name AND records a DAG edge (its Nix string context points at the ConfigMap store path), so the ConfigMap deploys before the Deployment.
- "store-path = DAG edge" rule: dependencies fall out of references, never declared as plain data (see 01-fundamentals.md#overview--mental-model, 02-authoring.md#resources-and-the-out-surface).
- `self` is lazy and recursive: read sibling `.out` freely; do not create a real cycle (A's manifest references B, B's references A) - will not terminate.

### System args injected into `build` (phase 2)

- `build` runs inside the fixpoint. Evaluator: `callBuildFn` in `kix/lib/eval/instance.nix`.
- Always passes `self`, `config`, `clusterConfig`. Conditionally passes `scope`, `lib`, `kix`, `deps` only if the arg set requests them (arg introspection).
- Reserved system arg names: `self  config  clusterConfig  scope  lib  kix  deps`.
- Any *other* arg = a dependency to resolve via DI (see 02-authoring.md#dependency-injection). `{ self, config, postgres }` = required dep `postgres`; `{ self, config, postgres ? null }` = optional.

- `config` - fully-evaluated, typed config (option defaults + cluster overrides + dep injections). See 01-fundamentals.md#options--config.
- `clusterConfig` - cluster-wide settings (`clusterDomain`, `cluster.capabilities`, `networkPolicy`, `scorecard`, ...).
- `deps` - full resolved-deps attrset (rarely needed; usually name individual deps as args instead).

### The `root` convention

- `build` return MUST include `root` (else evaluator throws `must define 'root'`).
- `root` = package entry point: the resource whose readiness means "package is up", and anchor of the forward dependency closure.
- Two accepted forms (`rawRoot` handling in `kix/lib/eval/instance.nix`).

Direct resource (most common):

```nix
root = self.service;     # echo-server: service is the entry point
root = self.deployment;  # reloader: deployment is the entry point
```

Structured form with explicit forward requirements and post-deploy hooks:

```nix
root = {
  resource = self.deployment;
  requires = [ self.serviceAccount ];   # structural forward deps (no string-context edge)
  postHooks = [ self.migrationJob ];    # deployed AFTER all package resources finish
  out = { /* extra outputs merged on top of root.out */ };
};
```

- `requires` - forward edges NOT expressed through manifest string context (e.g. a ServiceAccount a Deployment uses but does not name with context).
- `postHooks` - run after the rest of the package; gate the `PackageInstance` marker's completion (typically migration Jobs).
- `out` - extends the package's public surface beyond what is auto-derived from the root resource (see 02-authoring.md#resources-and-the-out-surface).
- Bare resource: `requires`/`postHooks`/`out` all default to empty.

### Return attrset becomes consumer view

Two collection passes over the "parts" attrset (the whole `build` return):

1. Typed resources gathered for deployment by `collectTypedAttrs` (`kix/lib/eval/helpers.nix`): walks nested attrsets up to 3 levels deep, stops at any `_type` boundary, excludes `root` and `meta`. Group resources in plain sub-attrsets (folders) and they still get collected.
2. Consumer view (`mkPackageView` in `kix/lib/eval/view.nix`): what other packages see when depending on this one. Three layers, merged with collision detection:
   - **folders** - plain attrsets in `parts` (no `_type`, excluding `root`) surfaced as nested groups.
   - **autoKeys** - everything from the root resource's `out` (`name`, `fqdn`, `selector`, ...) copied to the top of the view, so consumers write `pg.fqdn` not `pg.out.fqdn`.
   - **system** - evaluator plumbing: `_type = "k8s-instance"`, `root`, `out`, `raw` (full parts attrset), `_meta` (instanceName, namespace, aliases, packageMeta, config).

- `_type` leaf marker distinguishes resource from folder: with `_type` = typed leaf (collection stops); plain attrset without `_type` = folder to descend into.
- Two "known", content-checked folders: `secrets` and `crds` (`knownFolders`). Resource *directly* on `parts.secrets` (instead of `parts.secrets.someName`) throws; wrong `_type` inside emits a trace warning.

#### Spreading extra resources with `//`

`build` returns a plain attrset, so compute a group separately and merge it in. `reloader` builds its RBAC set in the `let` and spreads it:

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

- Resources set to `null` (e.g. optional `service`) are filtered out during collection; conditional/modal parts are fine.

### Build-time warnings (fix these)

- After the fixpoint settles, `kix/lib/eval/instance.nix` computes the forward closure from `root` (plus `requires` and `postHooks`) and emits structural warnings. Treat as errors.
- Emitted before view construction (via `builtins.seq` on `diagnostics.emitWarnings`); surface on every cluster evaluation.

- **Orphaned resource** - `resource 'Kind/name' is defined but not reachable from root`. Exists in `build` return but nothing in the forward closure (and no inverse dep) references it. Fix: reference it from a reachable resource, list it in `root.requires`, or remove it. Inverse deps (a ClusterRoleBinding referencing a reachable ServiceAccount) are not orphans.
- **Redundant requires** - `resource ... has redundant requires on ... - already tracked via store path reference`. Listed in `requires` something the manifest already references through string context. Drop it from `requires`.
- **Duplicate requires** - `resource ... requires ... multiple times`. Same resource twice in a `requires` list. De-duplicate.
- **Post-hook not ordered** - `post-hook ... does not depend on any forward-closure resource - it won't be ordered after root`. Make it depend on `root` or a descendant.

### Complete minimal example: reloader

`kix/packages/reloader/default.nix` - self-contained, no DI deps, just config and RBAC. Abridged skeleton:

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

Notes:

- Outer function takes `{ scope, lib, kix }`; `build` takes `{ self, config, clusterConfig }` (no extra args, no DI deps).
- `self.serviceAccount.out.name` referenced from Deployment's `serviceAccountName`: reads the name AND records the deploy edge (SA before Deployment).
- `service` conditional - `null` when disabled, filtered out automatically.
- ClusterRole/Binding set computed in `let`, spread with `// clusterRoles`. They reference the ServiceAccount, so reachable as inverse deps, not flagged as orphans.
- `root = self.deployment` makes the Deployment the entry point.

### Gotchas / common mistakes

- **Forgetting `root`** throws `must define 'root'`. Exactly one entry point per package.
- **`root` of wrong type** throws `root must be a resource or { resource, requires, postHooks }`. A bare config attrset is not a resource - pass a `mkResource`/`mkDeployment` output or the structured `{ resource = ...; }` form.
- **`build` arg colliding with a real dep name** - any non-system arg is a DI dependency. Typo `{ self, config, postgrs }` becomes a *required* dep `postgrs` and fails resolution, not a config error.
- **Resource directly on a known folder** (`parts.secrets = someSecret`) throws; must be `parts.secrets.<name> = someSecret`.
- **Orphaned resources** ship as warnings, not hard errors - easy to leave a half-wired resource that never deploys. Fix every structural warning.
- **Deep nesting beyond 3 levels**: `collectTypedAttrs` descends only 3 levels. Resources deeper than `parts.a.b.c` are not collected.
- **`self` cycles**: sibling `.out` references are fine and lazy; a genuine mutual manifest reference (A names B, B names A) will not terminate.

## Options & config

Package `options` + cluster instance `config` merge into the single `config` attrset `build` reads. Grounded in `kix/lib/eval/resolve.nix` (merge engine), `kix/lib/modules.nix` (cluster schema).

### Two-level model

Two scopes reach `build` as two separate args (both optional; request by name only if used, see 02-authoring.md#dependency-injection):

- **`config`** - this instance's settings. Package `options` evaluated against instance `config` block. Per-instance, package-local.
- **`clusterConfig`** - whole cluster module's evaluated config (options in `kix/lib/modules.nix`): `clusterDomain`, `cluster.capabilities.*`, `k8sVersion`, `global`, `networkPolicy`, `scorecard`. Shared across all instances.

```nix
build =
  {
    self,
    config,         # this instance's typed options, merged with cluster config
    clusterConfig,  # cluster-wide module config (domain, capabilities, ...)
    postgres ? null,
    ...
  }:
  ...
```

### Declaring options

- Declared with `lib.mkOption` (NixOS-module style). `options` is a top-level package key (alongside `meta`, `deps`, `build`).
- Every option needs `type` and (almost always) `default`. Defaults are what `build` sees when cluster sets nothing.
- Keep option keys K8s-shaped (`image`, `replicaCount`, `resources`, `ingress.host`), not invented spec keys. See DSL design principles.

Example from `immich`:

```nix
options = {
  replicaCount = lib.mkOption {
    type = lib.types.int;
    default = 1;
  };
  env = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Extra environment variables for the server container";
  };
  configuration = lib.mkOption {
    type = lib.types.nullOr lib.types.anything;
    default = null;
    description = "Immich config (immich-config.yaml content as attrset). Null to disable.";
  };
  ingress = kix.options.ingress;
};
```

### Instance config merge over defaults

Each instance can carry a `config` block (a `deferredModule`, see `instances.<ns>.<inst>.config` in `kix/lib/modules.nix`):

```nix
immich-db = {
  package = packages.stackgres-database;
  aliases = [ "database" ];
  config = {
    database = "immich";
    user = "immich";
    password = "immich-dev-password";
  };
};
```

`evaluateInstanceConfig` (`kix/lib/eval/resolve.nix`) runs `lib.evalModules` with, in order:

1. `{ options = packageOptions; }` - package's option declarations.
2. `{ config = clusterConfig.global or { }; }` - cluster-wide `global` as a config layer.
3. dep config injections (see Dep config injection below + chapter 12).
4. instance's own `config` modules.

- Instance config is a `deferredModule`: multiple cluster modules can contribute config to the same instance, merged via NixOS module system.
- Use `lib.mkDefault` / `lib.mkForce` for priority when two sources set the same field.

#### `anything`-typed deep-merge caveat

- `lib.types.anything` does NOT deep-merge a user value with a nested default. Setting `backend.image` would drop the sibling `backend.hpa` default under plain module eval.
- Fix: `evaluateInstanceConfig` collects each option's `default` and runs a final `lib.recursiveUpdate optionDefaults evaluated`, restoring nested defaults under `anything`-typed blocks.
- This is why `python-app` declares `backend = lib.mkOption { type = lib.types.anything; default = { enabled = true; image = {...}; hpa = {...}; ... }; }` and a cluster can override just `backend.replicaCount` without losing the rest.

### Option type patterns

**Scalar / structured** - precise types where shape is fixed:

```nix
replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
environment  = lib.mkOption { type = lib.types.str; default = "production"; };
```

**`anything`-typed config blocks** - whole nested tree with rich default, for large/open-ended shapes (`python-app` `backend`, `frontend`, `redis`, `ingress`, `hooks`). Deep-merge (above) makes it ergonomic; cost is no type checking inside the block.

**`attrsOf anything` for dynamic sub-services** - cluster declares an arbitrary number of named sub-resources. `python-app` workers:

```nix
cronWorkers  = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
queueWorkers = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
```

Build iterates with `lib.concatMapAttrs` to materialize one Deployment (+ optional Service/HPA) per entry.

### Shared option bundles: `kix.options`

`kix/lib/compose.nix` exposes `kix.options`, pre-built option declarations. Splice into `options`:

```nix
options = {
  # ... package-specific options ...
  ingress = kix.options.ingress;   # { host, annotations }
  metrics = kix.options.monitor;   # { enabled, interval }
};
```

Bundles today (verify exact fields in `kix/lib/compose.nix`):

- `kix.options.ingress` - `host` (`nullOr str`, default `null`, "Null = auto-derive from cluster.domain") + `annotations` (`attrsOf str`).
- `kix.options.monitor` - `enabled` (`bool`, default `true`) + `interval` (`nullOr str`, scrape interval).

Pair with `kix.expose` / `kix.monitor` build entries, which read `config.ingress.host` / `config.ingress.annotations` and `config.metrics.enabled` / `config.metrics.interval` (see 02-authoring.md#composition-helpers-kix). Use the bundle so option names line up with those helpers.

### Reading `clusterConfig`

Evaluated cluster module (schema in `kix/lib/modules.nix`). Common reads:

```nix
# Top-level DNS domain (declared in the schema, default "cluster.local"), for FQDNs:
dnsDomain = clusterConfig.clusterDomain or "cluster.local";

# Public/ingress hostname base. NOTE: `cluster.domain` is NOT a declared option
# (see the Gotcha below), so today this reads null. vaultwarden / firezone /
# kix.expose all use this exact path:
publicDomain = clusterConfig.cluster.domain or null;
```

Other queried fields:

- `clusterConfig.cluster.capabilities.*` (e.g. `loadBalancer`, `persistentStorage`, `multiNode`, `gpu`) for conditional logic.
- `clusterConfig.k8sVersion` for version-gated behavior.
- `clusterConfig.global` for cluster-wide values.
- Always read with `or` defaults; not every cluster sets every field.

`networkPolicy`, `scorecard`, `cluster.capabilities` are consumed by eval machinery in `kix/lib/eval/instance.nix`, not usually by `build`. Prefer DI (take a dependency) over branching on a capability name where a dep exists. See `TODO` notes in `kix/lib/modules.nix` - several capabilities slated to become DI deps.

### Dep config injection (preview)

A dependency can push config onto its consumer. In `immich`, `deps` declares `database.config.extensions = [...]`, which `evaluateInstanceConfig` feeds in as an injection module (priority equal to instance config; `listOf` types concatenate, scalars error on conflict). Auto-configures immich's stackgres database without cluster-side wiring. Full mechanics + `mkLocked` (block injection into a field) in 03-advanced.md#overrides.

### Gotchas

- **Defaults reach build even when an option is untouched.** `build` always sees a fully-defaulted `config`; no `config.x or default` needed for declared options. Use `or` only for keys NOT declared (e.g. optional sub-keys inside an `anything` block).
- **`anything` blocks are not type-checked.** A typo inside a `backend = { ... }` override is silently accepted, surfaces only as a wrong/missing manifest field. Trade for deep-merge ergonomics is lost validation.
- **`clusterConfig.cluster.domain` is a latent gap.** `kix/lib/modules.nix` declares `clusterDomain` at top level (default `"cluster.local"`, for FQDN construction) but does NOT declare `cluster.domain`. Yet `vaultwarden`, `firezone`, `kix.expose` read `clusterConfig.cluster.domain or null` for the user-facing ingress hostname base. Undeclared, so reading yields `null` today (`or null` guard catches the missing attr); a cluster that tries to SET `cluster.domain` makes `evalModules` throw `The option 'cluster.domain' does not exist`. Hostname path is dormant until the schema grows a `cluster.domain` option. Don't rely on it carrying a value.
- **`global` keys must be declared by every package, or eval throws.** Cluster `global` values merge into every instance's module eval via `{ config = clusterConfig.global or { }; }`. An unmatched config key against declared options is a hard error in the NixOS module system: a `global.foo` that some package does not declare as an option makes THAT instance's config eval throw `The option 'foo' does not exist` (not a silent no-op). `global` is a typed config layer (key must be a declared option on the consuming package), not a free-form bag.
- **Don't invent spec keys.** Options should map to real K8s fields or genuine behavioral toggles. Custom options that rewrite manifest semantics diverge from K8s and confuse users + diff tooling.
