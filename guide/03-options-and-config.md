# Options & config

This chapter covers how a kix package declares its tunable surface (`options`), how a cluster
definition supplies values for those options (instance `config`), and how the two get merged into
the single `config` attrset your `build` function reads. It also distinguishes the per-instance
`config` build arg from the cluster-wide `clusterConfig` build arg, and documents the shared
option bundles `kix.options.ingress` / `kix.options.monitor`. Everything here is grounded in
`kix/lib/eval/resolve.nix` (the merge engine), `kix/lib/modules.nix` (the cluster schema), and
real packages.

## The two-level model

There are two distinct configuration scopes, and they reach your build function as two separate
arguments:

- **`config`** - this instance's settings, produced by evaluating the package's `options`
  against the instance `config` block in the cluster definition. Per-instance, package-local.
- **`clusterConfig`** - the whole cluster module's evaluated config (the options declared in
  `kix/lib/modules.nix`): `clusterDomain`, `cluster.capabilities.*`, `k8sVersion`, `global`,
  `networkPolicy`, `scorecard`, etc. Shared across every instance in the cluster.

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

Both args are optional - request them by name only if you use them (see 07-dependency-injection.md
for how build args are introspected).

## Declaring options

Options are declared with `lib.mkOption`, exactly as in a NixOS module. The `options` attrset
is a top-level key of the package (alongside `meta`, `deps`, `build`). From `immich`:

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

Every option needs a `type` and (almost always) a `default`. The defaults are what your build
function sees when the cluster sets nothing. Keep option keys K8s-shaped: model `image`,
`replicaCount`, `resources`, `ingress.host`, not invented spec keys (see the DSL design
principles - options exist to prevent mistakes and surface real K8s fields, not to invent a
parallel vocabulary).

## How instance config merges over defaults

In the cluster definition, each instance can carry a `config` block (a `deferredModule`, see
`instances.<ns>.<inst>.config` in `kix/lib/modules.nix`):

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

`evaluateInstanceConfig` in `kix/lib/eval/resolve.nix` turns this into the final `config` by
running `lib.evalModules` with, in order:

1. `{ options = packageOptions; }` - the package's option declarations.
2. `{ config = clusterConfig.global or { }; }` - cluster-wide `global` values as a config layer.
3. dep config injections (config a dependency pushed onto this instance, see below and chapter 12).
4. the instance's own `config` modules.

Because instance config is a `deferredModule`, multiple cluster modules can contribute config to
the same instance and they merge through the NixOS module system. Use `lib.mkDefault` /
`lib.mkForce` for priority control when two sources set the same field.

### The `anything`-typed deep-merge caveat

`lib.types.anything` does NOT deep-merge a user value with a nested default - if a user sets
`backend.image`, plain module evaluation would drop the sibling `backend.hpa` default. To fix
this, `evaluateInstanceConfig` collects each option's `default` and does a final
`lib.recursiveUpdate optionDefaults evaluated`. That restores nested defaults under
`anything`-typed blocks. This is why `python-app` can declare a giant `backend = lib.mkOption {
type = lib.types.anything; default = { enabled = true; image = {...}; hpa = {...}; ... }; }` and a
cluster can override just `backend.replicaCount` without losing the rest.

## Option type patterns

Three patterns recur across the package set:

**Scalar / structured options** - use precise types where the shape is fixed:

```nix
replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
environment  = lib.mkOption { type = lib.types.str; default = "production"; };
```

**`anything`-typed config blocks** - a whole nested config tree with a rich default, when the
shape is large or partly open-ended (`python-app`'s `backend`, `frontend`, `redis`, `ingress`,
`hooks`). The deep-merge behavior above makes this ergonomic; the cost is no type checking inside
the block.

**`attrsOf anything` for dynamic sub-services** - let the cluster declare an arbitrary number of
named sub-resources. `python-app` uses this for workers:

```nix
cronWorkers  = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
queueWorkers = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
```

The build then iterates with `lib.concatMapAttrs` to materialize one Deployment (and optional
Service/HPA) per named entry.

## Shared option bundles: `kix.options`

`kix/lib/compose.nix` exposes `kix.options`, a small set of pre-built option declarations so
packages agree on the shape of common config. Splice them straight into your `options`:

```nix
options = {
  # ... package-specific options ...
  ingress = kix.options.ingress;   # { host, annotations }
  metrics = kix.options.monitor;   # { enabled, interval }
};
```

The two bundles that exist today (verify the exact fields in `kix/lib/compose.nix`):

- `kix.options.ingress` - `host` (`nullOr str`, default `null`, "Null = auto-derive from
  cluster.domain") and `annotations` (`attrsOf str`).
- `kix.options.monitor` - `enabled` (`bool`, default `true`) and `interval` (`nullOr str`,
  scrape interval).

These pair with the `kix.expose` and `kix.monitor` build entries, which read `config.ingress.host`
/ `config.ingress.annotations` and `config.metrics.enabled` / `config.metrics.interval`
respectively (see 06-composition-helpers.md). Use the bundle so your option names line up with
what those helpers expect.

## Reading `clusterConfig`

`clusterConfig` is the evaluated cluster module (schema in `kix/lib/modules.nix`). Common reads:

```nix
# Top-level DNS domain (declared in the schema, default "cluster.local"), for FQDNs:
dnsDomain = clusterConfig.clusterDomain or "cluster.local";

# Public/ingress hostname base. NOTE: `cluster.domain` is NOT a declared option
# (see the Gotcha below), so today this reads null. vaultwarden / firezone /
# kix.expose all use this exact path:
publicDomain = clusterConfig.cluster.domain or null;
```

Other fields packages query: `clusterConfig.cluster.capabilities.*` (e.g. `loadBalancer`,
`persistentStorage`, `multiNode`, `gpu`) for conditional logic, `clusterConfig.k8sVersion` for
version-gated behavior, and `clusterConfig.global` for cluster-wide values. Always read with
`or` defaults - not every cluster sets every field.

Note: the cluster-wide `networkPolicy`, `scorecard`, and `cluster.capabilities` blocks are
consumed by the eval machinery in `kix/lib/eval/instance.nix`, not usually by your build function.
You rarely branch on them directly; prefer DI (taking a dependency) over branching on a capability
name where a dep exists. See the `TODO` notes in `kix/lib/modules.nix` - several capabilities are
slated to become DI deps.

## Dep config injection (preview)

A dependency can push config onto the instance that consumes it. In `immich`, the `deps` block
declares `database.config.extensions = [...]`, which `evaluateInstanceConfig` feeds in as an
injection module (priority equal to instance config; `listOf` types concatenate, scalars error on
conflict). This is how immich auto-configures its stackgres database without cluster-side wiring.
Full mechanics, including `mkLocked` to block injection into a field, are in 12-overrides.md.

## Gotchas

- **Defaults reach build even when an option is untouched.** Your build function always sees a
  fully-defaulted `config`; you do not need `config.x or default` for declared options. Use `or`
  only for keys you did NOT declare (e.g. optional sub-keys inside an `anything` block).
- **`anything` blocks are not type-checked.** A typo inside a `backend = { ... }` override is
  silently accepted and surfaces only as a wrong/missing manifest field. The trade for the
  deep-merge ergonomics is lost validation.
- **`clusterConfig.cluster.domain` is a latent gap.** `kix/lib/modules.nix` declares
  `clusterDomain` at top level (default `"cluster.local"`, for FQDN construction), but it does
  NOT declare `cluster.domain`. Yet `vaultwarden`, `firezone`, and `kix.expose` read
  `clusterConfig.cluster.domain or null` for the user-facing ingress hostname base. Because the
  option is undeclared, reading it yields `null` today (the `or null` guard catches the missing
  attribute), and a cluster that tries to SET `cluster.domain` makes `evalModules` throw
  `The option 'cluster.domain' does not exist`. So this hostname path is effectively dormant until
  the schema grows a `cluster.domain` option. Don't rely on it carrying a value.
- **`global` keys must be declared by every package, or eval throws.** Cluster `global` values are
  merged into every instance's module evaluation via `{ config = clusterConfig.global or { }; }`.
  An unmatched config key against declared options is a hard error in the NixOS module system, so a
  `global.foo` that some package does not declare as an option makes THAT instance's config
  evaluation throw `The option 'foo' does not exist` - not a silent no-op. `global` is a typed
  config layer (a key must be a declared option on the consuming package), not a free-form bag your
  build reads directly.
- **Don't invent spec keys.** Options should map to real K8s fields or genuine behavioral toggles.
  Adding a custom option that rewrites manifest semantics in surprising ways diverges from K8s
  and confuses both users and the diff tooling.
