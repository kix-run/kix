# Fundamentals

What a package is, its shape, and how config flows in.

Sections: [Overview & mental model](#overview--mental-model) · [Package anatomy](#package-anatomy) · [Options & config](#options--config)

## Overview & mental model

The minimum to know before authoring. kix is a Kubernetes manifest compiler: a package is Nix data, kix evaluates it to plain YAML, a separate CLI deploys in dependency order. The full eval pipeline, string-context machinery, and Activation/closure model are compiler internals - see 03-advanced.md#store-path-context-and-closure-internals (and `kix/lib/architecture.md` for the pipeline); none of it is needed to write a package.

### What a package is

- A function (or inline attrset) at `kix/packages/<name>/default.nix` returning `{ meta?, options?, deps?, build }`.
- `build` returns a "self" attrset of named resources; `root` is the entry point.
- Reusable + parameterized: one package, many instances with different `config` (see 01-fundamentals.md#options--config).

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

Full shape: 01-fundamentals.md#package-anatomy.

### The one idea: store-path = DAG edge

kix has no `dependsOn` field. Deploy ordering falls out of how you reference other resources.

- A resource's public values (`self.x.out.name`, `.out.fqdn`, `.out.selector`) are real strings carrying that resource's Nix store-path context.
- Embed one resource's `out.*` in another's manifest -> kix reads the context back off the JSON and stamps a `kix.run/depends-on` edge. The CLI walks that graph for deploy order and waves.
- A hardcoded `"echo-server"` carries no context -> no edge -> unordered deploy. Always reference `self.x.out.name` (or `"${self.x}"`), never a literal name.
- When no value flows between two resources, add the edge explicitly with `requires` / `extraDeps` (see 02-authoring.md#resources-and-the-out-surface).

That is the whole authoring model. How context is parsed and how the closure is rooted is internals (see 03-advanced.md#store-path-context-and-closure-internals).

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

Wire into a cluster instance (shape of `clusters/example.nix`):

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

- Emits `ConfigMap/banner` in ns `apps`, plus kix bookkeeping (a `PackageInstance`, the cluster `Activation`, two kix CRDs, the namespace).
- `scope.instanceName` = the instance key (`banner`); the cluster wiring names the resource, not the package.

### Gotchas

- **Hardcoded names break ordering.** Literal `"echo-server"` carries no context -> no edge. Reference `self.x.out.name` / `"${self.x}"`.
- **Non-string leaves are not tracked.** Context cannot ride on an int/bool; if a dep "should" flow through one, use `requires`/`extraDeps` instead.
- **`extra.*` cannot shadow managed fields.** `mkResource` throws if `extra` sets `spec`, `data`, `stringData`, or `metadata.{name,namespace}`. Use `extra` only for sibling K8s fields kix does not model.

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
root = { resource = self.deployment; out = { inherit withReloadOn; }; };  # reloader: the Deployment plus an out transformer
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
   - **folders** - plain attrsets in `parts` (no `_type`, excluding `root`) surfaced as nested groups. A known folder (`crds`, `secrets`) whose name `root.out` also defines is left out, so `out.crds` and a `crds` folder can coexist; emission reads parts, so its resources are still emitted.
   - **autoKeys** - everything from the root resource's `out` (`name`, `fqdn`, `selector`, ...) copied to the top of the view, so consumers write `pg.fqdn` not `pg.out.fqdn`.
   - **system** - evaluator plumbing: `_type = "k8s-instance"`, `root`, `out`, `raw` (full parts attrset), `_meta` (instanceName, namespace, aliases, packageMeta, config).

- `_type` leaf marker distinguishes resource from folder: with `_type` = typed leaf (collection stops); plain attrset without `_type` = folder to descend into.
- Two "known", content-checked folders: `secrets` and `crds` (`knownFolders`). Resource *directly* on `parts.secrets` (instead of `parts.secrets.someName`) throws; wrong `_type` inside emits a trace warning. If `root.out` defines the same key (`out.crds`, `out.secrets`), the view shows `root.out`'s value instead of the folder; the folder's resources are still emitted.

#### Spreading extra resources with `//`

`build` returns a plain attrset, so compute a group separately and merge it in. `reloader` merges its RBAC sets after the parts:

```nix
build = [
  ({ self, config, prometheus ? null, ... }:
    {
      serviceAccount = scope.mkResource { /* ... */ };
      deployment = { /* ... */ } |> scope.mkDeployment;
      service = if config.metrics.enabled && prometheus != null then /* ... */ else null;
      root = { resource = self.deployment; out = { inherit withReloadOn; }; };
    }
    // mkClusterRoleSet scope { /* ... */ }
    // mkRoleSet scope { /* ... */ })
  (kix.monitor { service = "service"; port = "http"; })
];
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

`kix/packages/reloader/default.nix`: one Deployment with derived RBAC, an optional `prometheus` dependency, and an `out` transformer. Abridged skeleton:

```nix
{ scope, lib, kix, availability }:
let
  name = scope.instanceName;
  who = "reloader ${scope.namespaceName}/${name}";
in
{
  meta = {
    version = "v1.4.22";
    defaultAliases = [ "reloader" ];
    conflictsWith = [ "cluster:reloader" ];
    annotationDomains = [ "reloader.stakater.com" "secret.reloader.stakater.com" /* ... */ ];
  };

  options = {
    image = kix.options.image { repository = "ghcr.io/stakater/reloader"; tag = "v1.4.22"; digest = "sha256:..."; };
    resources = kix.options.resources { requests = { cpu = "10m"; memory = "64Mi"; }; /* ... */ };
    extraArgs = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    env = kix.options.env;
    metrics = kix.options.monitor;
  };

  build = [
    ({ self, config, prometheus ? null, ... }:
      let
        args = [ "--log-format=json" "--enable-ha=true" /* ... */ ]
          ++ kix.guardArgs { inherit who; owned = { /* flag = reason */ }; } config.extraArgs;
        withReloadOn = refs: buildArgs: /* adds secret.reloader.stakater.com/reload */;
      in
      {
        serviceAccount = scope.mkResource { apiVersion = "v1"; kind = "ServiceAccount"; inherit name; };

        deployment = {
          inherit name;
          spec = {
            replicas = kix.availability.pick availability { none = 1; pod = 1; node = 2; zone = 2; };
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              containers = [ {
                name = "reloader";
                image = kix.image.ref config.image;
                inherit args;
                ports = [ (kix.port "http" 9090) ];
                # ...
              } ];
            };
          };
        } |> scope.mkDeployment;

        service = if config.metrics.enabled && prometheus != null then
          self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource
        else null;

        root = { resource = self.deployment; out = { inherit withReloadOn; }; };
      }
      # secrets watch, apps workloads patch, events; a Role in each
      # namespace instead when extraArgs sets --namespaces
      // mkClusterRoleSet scope { /* ... */ }
      // mkRoleSet scope { /* leader-election Lease */ })
    (kix.monitor { service = "service"; port = "http"; alerts = { /* ... */ }; })
  ];
}
```

Notes:

- The outer function takes `availability` because the replica count is `kix.availability.pick`; there is no replica option on a leader-elected controller.
- `serviceAccount = self.serviceAccount` sets `serviceAccountName` and records the dependency (ServiceAccount before Deployment).
- `service` is `null` unless metrics are on and a `prometheus` dependency resolves; null parts are filtered out.
- The RBAC sets are merged with `//`. They reference the ServiceAccount, so they are reachable as inverse dependencies, not orphans.
- `root.out.withReloadOn` is what consumers read (`reloader.out.withReloadOn`).

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
- **`clusterConfig`** - whole cluster module's evaluated config (options in `kix/lib/modules.nix`): `clusterDomain`, `cluster.domain`, `cluster.capabilities.*`, `cluster.network.*`, `k8sVersion`, `networkPolicy`, `scorecard`. Shared across all instances. Package and instance `config` modules receive it as a module argument too, so a default can derive from a cluster fact: `config = { clusterConfig, ... }: { zone = lib.mkDefault clusterConfig.clusterDomain; };`.

```nix
build =
  {
    self,
    config,         # this instance's typed options, merged with cluster config
    clusterConfig,  # cluster-wide module config (domain, capabilities, ...)
    database ? null,
    ...
  }:
  ...
```

### Declaring options

- Declared with `lib.mkOption` (NixOS-module style). `options` is a top-level package key (alongside `meta`, `deps`, `build`).
- Every option needs `type` and (almost always) `default`. Defaults are what `build` sees when cluster sets nothing.
- Keep option keys K8s-shaped (`image`, `replicas`, `resources`, `ingress.host`), not invented spec keys. See DSL design principles.

Example from `immich`:

```nix
options = {
  image = kix.options.image {
    repository = "ghcr.io/immich-app/immich-server";
    inherit (release) tag;
    digest = release.digests.server;
  };
  resources = kix.options.resources {
    requests = { cpu = "250m"; memory = "1Gi"; };
    limits = { cpu = "4"; memory = "4Gi"; };
  };
  env = kix.options.env;          # rendered through kix.mergeEnv
  settings = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Immich's configuration file. Empty leaves every setting to the admin UI.";
  };
  metrics = kix.options.monitor;
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
2. the package's own `config` module (its `lib.mkDefault`s run at priority 1250, between an instance's `mkDefault` and the declared default).
3. dep config injections (see Dep config injection below + chapter 12).
4. instance's own `config` modules.

`clusterConfig` is in `specialArgs`, so every one of these modules can take it as an argument. Module errors name the option as `instances.<ns>.<inst>.config.<option>` and the file that set it.

- Instance config is a `deferredModule`: multiple cluster modules can contribute config to the same instance, merged via NixOS module system.
- Use `lib.mkDefault` / `lib.mkForce` for priority when two sources set the same field.

#### The option contract

- An instance value replaces an option's default under the module system's own rules: `anything` and `attrsOf` replace a whole attrset default, and a submodule's own default is discarded when any field is set. Kix adds no merge of its own.
- So a package may not declare a default that a partial instance value would discard. `checkOptionContract` (`kix/lib/eval/options.nix`) refuses an untyped option (`anything`, `attrs`, `attrsOf anything`, ...) with a non-empty attrset default; an `attrsOf` option with a non-empty default; a submodule whose own default sets a key its field does not default to; and any declaration it cannot read.
- Package CI runs it once per package (`every-package-evaluates`, `kix/package-eval.nix`); evaluating a cluster does not. The `options` reference page gives the command for one package, in kixpkgs or outside it.
- Remedies: put defaults on submodule fields (`kix.options.resources` for container resources); for `attrsOf` entries an instance adds to, default to `{ }` and set each entry in the package's `config` with `lib.mkDefault`; when the instance should replace the value as a whole, default to null and apply the package's value in the build. Give the option a `defaultText` naming the package's value in the last two cases.

### Option type patterns

**Scalar / structured** - precise types where shape is fixed:

```nix
replicas    = lib.mkOption { type = lib.types.ints.positive; default = kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }; };
environment = lib.mkOption { type = lib.types.str; default = "production"; };
size        = lib.mkOption { type = kix.types.quantity; default = "10Gi"; };
```

**Submodule config blocks** - a nested shape with a default on each field (`lib.types.submodule`). An instance that sets one field keeps the defaults of its siblings, and every field is type-checked.

**`attrsOf (submodule ...)` for named sub-resources** - the cluster declares any number of named entries, each type-checked. `mayastor` `diskPools`:

```nix
diskPools = lib.mkOption { type = lib.types.attrsOf poolType; default = { }; };
```

Build iterates over the entries (`lib.mapAttrsToList`) to build one resource per entry.

**Escape hatches**, by what the package builds: `values` (Helm chart, `lib.recursiveUpdate` over the package's values), `extraSpec` (a resource or CR `spec`, through `kix.mergeGuarded`), `settings` (the program's own config file, through `kix.mergeGuarded`), `extraArgs` (`listOf str`, appended through `kix.guardArgs`), `env` (`kix.options.env`, rendered through `kix.mergeEnv`). Anything else goes through instance `partsOverlays`.

### Shared option bundles: `kix.options`

`kix/lib/compose.nix` exposes `kix.options`, pre-built option declarations. Splice into `options`:

```nix
options = {
  # ... package-specific options ...
  ingress = kix.options.ingress;   # { host, annotations }
  metrics = kix.options.monitor;   # { enabled, interval }
};
```

Bundles today (verify exact fields in `kix/lib/vocab/compose.nix`):

- `kix.options.image { repository ? null, tag ? null, digest ? null, ... }` - repository, tag, digest, pullPolicy, and the promotion fields; render with `kix.image.ref config.image`. A null `repository` or `tag` leaves that field required.
- `kix.options.resources { requests ? { }, limits ? { } }` - container resources with each default on its field; null removes a default.
- `kix.options.env` - extra env vars (`attrsOf (null or a string or a valueFrom source)`); render through `kix.mergeEnv`.
- `kix.options.ingress` - `host` (`nullOr str`, default `null`, "Null = auto-derive from cluster.domain") + `annotations` (`attrsOf str`).
- `kix.options.monitor` - `enabled` (`bool`, default `true`) + `interval` (`nullOr str`, scrape interval).
- `kix.options.healthCheck` - `enabled` (`bool`, default `false`) + `retryFor` (seconds); read by `kix.healthCheck`.

Toggles are named `enabled`.

Pair with `kix.expose` / `kix.monitor` build entries, which read `config.ingress.host` / `config.ingress.annotations` and `config.metrics.enabled` / `config.metrics.interval` (see 02-authoring.md#composition-helpers-kix). Use the bundle so option names line up with those helpers.

### Reading `clusterConfig`

Evaluated cluster module (schema in `kix/lib/modules.nix`). Common reads:

```nix
# Top-level DNS domain (declared in the schema, default "cluster.local"), for FQDNs:
dnsDomain = clusterConfig.clusterDomain or "cluster.local";

# Public base domain (`cluster.domain`, default null), from which kix.expose
# derives `<instance>.<domain>`:
publicDomain = clusterConfig.cluster.domain;
```

Other queried fields:

- `clusterConfig.cluster.capabilities.*` (e.g. `loadBalancer`, `persistentStorage`, `multiNode`, `gpu`) for conditional logic.
- `clusterConfig.k8sVersion` for version-gated behavior.
- Always read with `or` defaults; not every cluster sets every field.

`networkPolicy`, `scorecard`, `cluster.capabilities` are consumed by eval machinery in `kix/lib/eval/instance.nix`, not usually by `build`. Prefer DI (take a dependency) over branching on a capability name where a dep exists. See `TODO` notes in `kix/lib/modules.nix` - several capabilities slated to become DI deps.

### Dep config injection (preview)

A consumer can push config onto its dependency. In `immich`, `deps` declares `database.config.extensions = [...]`, which `evaluateInstanceConfig` feeds in as an injection module (priority equal to instance config; `listOf` types concatenate, scalars error on conflict). Auto-configures immich's stackgres database without cluster-side wiring. Full mechanics + `mkLocked` (block injection into a field) in 03-advanced.md#overrides.

### Gotchas

- **Defaults reach build even when an option is untouched.** `build` always sees a fully-defaulted `config`; no `config.x or default` needed for declared options. Use `or` only for keys NOT declared (e.g. optional sub-keys inside an `anything` block).
- **`anything` blocks are not type-checked.** A typo inside an `anything` value is silently accepted and surfaces only as a wrong or missing manifest field. Prefer a submodule; keep `anything` for a program config the package passes through (`settings`).
- **Don't invent spec keys.** Options should map to real K8s fields or genuine behavioral toggles. Custom options that rewrite manifest semantics diverge from K8s and confuse users + diff tooling.
