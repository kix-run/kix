# Dependency injection

This chapter covers how a kix package declares and receives its dependencies. Deps are not config
fields and not import statements: they are the named arguments of the `build` function, discovered
by introspection and resolved against the cluster with DNS-like rules. This chapter explains how
discovery works, the resolution priority, the difference between required and optional deps, the
two-phase calling protocol (introspect, then bind), how a list-valued `build` merges deps across
entries, co-located `deps.<name>` diagnostics and config injection, auto-instantiation of missing
deps, and `mkImport` for unmanaged resources. See `04-resources-and-out.md` for the `out` surface
that deps consume, and `12-overrides.md` for the cluster-side `deps` override knobs.

## Deps are build-function args

A package's dependencies are exactly the arguments its `build` function declares, minus the
arguments the eval system always supplies. From `python-app/default.nix`:

```nix
build =
  {
    self,
    config,
    clusterConfig,
    postgres ? null,
    valkey ? null,
    ingressNginx ? null,
    clusterIssuer ? null,
  }:
  ...
```

`discoverBuildDeps` (in `kix/lib/eval/resolve.nix`) reads `builtins.functionArgs build`, removes the
system arg names, and treats whatever remains as deps:

```nix
systemBuildArgNames = [ "self" "config" "clusterConfig" "scope" "lib" "kix" "deps" ];
```

So `postgres`, `valkey`, `ingressNginx`, `clusterIssuer` are the four deps of `python-app`. Nothing
else declares them - there is no separate dependency list. The arg name is the resolution key.

## Required vs optional

Optionality is encoded by the Nix default, not a flag:

- No default (`postgres`) - **required**. If the cluster can't supply it, evaluation throws.
- `? null` default (`postgres ? null`) - **optional**. If unresolved, Nix fills in `null` and the
  package branches on presence.

`discoverBuildDeps` returns `{ <name> = { optional = <hasDefault>; }; }`. In `python-app` every dep
is optional, and the build gates behavior on presence:

```nix
hasIngress = ingressNginx != null && config.ingress.hosts != [ ];
hasTls = hasIngress && clusterIssuer != null;

depEnv =
  { }
  // lib.optionalAttrs (postgres != null) { DATABASE_HOST = postgres.out.fqdn; }
  // lib.optionalAttrs (valkey != null) { VALKEY_HOST = valkey.out.fqdn; };
```

`firezone/default.nix` instead declares `postgres` with no default - it is a hard requirement, and a
cluster without a resolvable `postgres` fails to evaluate.

## DNS-like resolution

`resolveArg` (in `kix/lib/eval/resolve.nix`) maps a dep arg name to a concrete instance using a
priority ladder. The requester's namespace matters - resolution prefers local instances, exactly
like DNS prefers the local search domain.

1. **Explicit override wins.** A cluster author can pin a dep with `deps.<argName> = ...` on the
   instance (see `12-overrides.md`). `resolveArg` returns it directly (`direct = true`).
2. **Same namespace, exactly one match** - use it.
3. **Same namespace, multiple matches** - throw `ambiguous auto-resolution ... multiple matches`.
4. **No same-namespace match, exactly one cluster-wide match** - use it (cross-namespace).
5. **Multiple cluster-wide matches** - throw `ambiguous ... specify explicitly`.
6. **No match, dep has a Nix default** - return `{ found = false; }`; Nix supplies the default
   (`null` for optionals).
7. **No match, no default** - throw `no '<argName>' found in cluster for namespace '<ns>'`.

The candidate set comes from the **resolution index**, built by `buildResolutionIndex` purely from
static `_meta` (no inner fixpoint forced). Each instance contributes its instance name **and its
aliases** as keys:

```nix
keys = lib.unique ([ instName ] ++ (meta.aliases or [ ]));
```

So a postgres instance named `app-db` with `aliases = [ "postgres" ]` is reachable by a `postgres ?
null` build arg. Aliases are first-class resolution keys, which is how generic packages (a build arg
called `postgres`) bind to specifically-named instances.

### Managed instances shadow imports

When both a managed instance and an import share a key, the managed one wins:

```nix
managed = builtins.filter (c: !(c.meta.isImport or false)) candidates;
effectiveCandidates = if managed != [ ] then managed else candidates;
```

This lets a cluster flavor provide fallback imports for platform services (DNS, storage, ingress)
that are automatically shadowed once the cluster installs its own package providing the same key.

## The combined `deps` arg

Besides receiving each dep by name, a build entry may request a `deps` arg, which is the whole
attrset of resolved deps keyed by arg name. From `instance.nix`:

```nix
extra =
  ... // lib.optionalAttrs (args ? deps) { deps = resolvedDeps; };
depArgs = lib.intersectAttrs args resolvedDeps;
fn (base // extra // depArgs);
```

`resolvedDeps` only contains deps that resolved (optionals that came back `null` are absent). Use
named args for the common case; `deps` is handy when iterating over an unknown set.

## Two-phase calling

A package is evaluated in two phases so that deps can influence each other before any resource is
built.

**Phase 1 - introspect (no fixpoint).** `normalizePackage` / `callPackagePhase1` turns the package
value into `{ meta?, options?, deps?, build, ... }`. A function package is called with **system args
only** (`scope`, `lib`, and `kix` if requested) - never with deps:

```nix
package ({ inherit scope lib; } // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; });
```

An inline attrset package (one that already has a `build` key) and a `kix-import` are returned
as-is. From the result, `discoverBuildDeps raw.build` learns the dep names without evaluating
`build`. In this phase, a consumer's `deps.<name>.config` enrichment is collected and **injected
into the target dep's config** before that dep is evaluated (see "Dep config injection" below).

**Phase 2 - bind (inside the fixpoint).** `resolveDeclaredDeps` turns each discovered dep into a
concrete instance handle (looked up from `allInstances` via the resolution coordinates), then the
build runs inside `lib.fix`:

```nix
parts = lib.fix (self:
  builtins.foldl' (acc: fn: acc // (callBuildFn self fn)) { } rawBuildEntries);
```

`callBuildFn` passes `{ self, config, clusterConfig }` plus, by arg introspection, any of `scope`,
`lib`, `kix`, `deps`, and the named resolved deps the entry actually requests. `self` is the
fixpoint of all parts, so a resource can reference a sibling (`self.backendService.out.name`) and a
dep alike.

## `build` as a list: per-entry discovery, merged

`build` may be a single function or a **list** of functions (or paths to functions). Each entry is
introspected independently and the dep sets are **unioned**. From `discoverBuildDeps`:

```nix
allBuildArgs = builtins.foldl' (acc: fn:
  let
    fnArgs = builtins.functionArgs fn;
    overrides = lib.mapAttrs (n: v: acc.${n} && v) (lib.intersectAttrs acc fnArgs);
  in acc // fnArgs // overrides) { } buildEntries;
```

Optionality is AND-ed across entries: a dep declared by two entries is optional only if **both**
give it a default (required wins). Each entry receives only the deps it names (`lib.intersectAttrs
args resolvedDeps`), and the returned attrsets are `//`-merged into one `self`.

This is exactly how the composition helpers attach infrastructure deps without the app author
touching them (see `06-composition-helpers.md`). `firezone/default.nix`:

```nix
build = [
  ({ self, config, clusterConfig, postgres, scope, kix, ... }: { ... app resources ... })
  (kix.expose { service = "service"; })
];
```

`kix.expose` returns a build entry that declares `gateway ? null`, `ingressNginx ? null`,
`clusterIssuer ? null` as its own args; `kix.monitor` returns one that declares `prometheus ? null`.
The union means the package's effective dep set grows by whatever its helpers need - the first entry
never has to list ingress or prometheus.

## `deps.<name>` enrichment: assertions, warnings, config

A package can attach per-dep metadata, co-located with the dep, in a top-level `deps` attrset. This
is separate from the build args (which still define the dep set); enrichment only adds diagnostics
and config injection. From `immich/default.nix`:

```nix
deps = {
  database.config = { extensions = [ { name = "vchord"; version = "0.5.3"; } "uuid-ossp" ... ]; };

  database.assertions = dep:
    let extensions = dep.out.extensions or null; ... in
    lib.optional (extensions != null && missing != [ ]) {
      assertion = false;
      message = "immich requires the following postgres extensions ...";
    };

  storage.warnings = dep:
    lib.optional (kix.parseGi (dep.out.size or "0") < 50)
      "library storage is ${dep.out.size or "unknown"}, recommended minimum is 50Gi ...";
};
```

`deps.<name>.assertions` / `.warnings` are functions of the resolved dep instance (`dep`, with its
`out`), evaluated against the actually-bound dep. They produce diagnostics attributed to the
consumer - a clean way to validate that a dep was configured the way this consumer needs.

### Dep config injection

`deps.<name>.config` lets a consumer push config **into** the dep it resolves to. During phase 1,
`buildConfigInjections` inverts "consumer X wants config on dep Y" into "target Y receives
injections from [X...]", and `evaluateInstanceConfig` merges those injection modules into the
target's `evalModules` at the same priority as instance config. In the immich example, immich
forwards the postgres extensions it needs into its `database` dep, so auto-instantiating immich pulls
a fully-configured database with no cluster-side wiring.

`config` may be a static attrset or a function `consumerConfig: { ... }`, resolved lazily so a
consumer can forward parts of its own evaluated config into a dep. Injection into a field wrapped by
`mkLocked` is a build-time error with source attribution (see `12-overrides.md`).

## Auto-instantiation

A required dep that no explicit instance satisfies can be created automatically. `auto.nix`
(`computeAutoInstances`) seeds from the required deps of mandatory instances, then walks transitive
required deps with `builtins.genericClosure`. For each unmet dep name it checks, in order:

- **activated optionals** - an instance the cluster declared `optional = true`; reaching it as a dep
  flips it on (recorded in `activatedOptionals`),
- **`availablePackages`** - a registry of packages keyed by name/alias; a match is instantiated in
  `avPkg.namespace`, else `autoNamespace`, else the requester's namespace, with default config and
  `_autoInstantiated = true`,
- neither - left unresolved, so `resolveArg` errors later with the missing-dep message.

Auto-instances carry the annotation `kix.dev/auto-instantiated = "true"` (optionals get
`kix.dev/optional-activated`). A `[kix] auto-instantiated: ...` trace is emitted. Only **required**
deps drive auto-instantiation - optionals left unresolved simply become `null`.

## `mkImport`: unmanaged resources as deps

Some deps are not packages kix deploys but resources that already exist (cloud DNS, a managed
ingress, a platform CoreDNS). `mkImport` (in `kix/lib/eval/import.nix`) creates a `kix-import`
marker usable as an instance's `package`. It participates in the resolution index like any instance
(by name and aliases) so consumers resolve it normally, but it emits only a marker PackageInstance,
not real manifests. From `kix/lib/flavors/kind.nix`:

```nix
instances.kube-system.platform-dns = {
  package = kix.mkImport {
    kind = "Deployment";
    apiVersion = "apps/v1";
    out = { name = "coredns"; fqdn = "kube-dns.kube-system.svc.cluster.local"; };
  };
  aliases = [ "dns" ];
};
```

`mkImport` takes `{ from ? null, out ? {}, kind ? null, apiVersion ? null }`:

- `out` only - the `out` surface is supplied verbatim (the example above).
- `from = <package fn>` - the package's `build` runs under a lightweight import scope
  (`mkImportScope`) that swaps `mkResource`/`mkServiceRef`/`mkSecretRef` for ref constructors which
  compute `out` without store paths or manifests. Only `out`-relevant code is forced via laziness.
  Deps are **not** resolved in import mode: any dep access hits a proxy that throws a clear error
  ("imports run without dependency resolution"). Use a raw `out` override, or a mixed import
  (`from` plus `out` for the fields that would need a dep).

Because managed instances shadow imports on shared keys, a flavor can declare a fallback
`platform-dns` import that is automatically replaced when the cluster installs its own DNS package.

## Infrastructure DI patterns

What a dep exposes through `out` shapes how the consumer uses it. Three patterns recur:

| Pattern | What `out` carries | Consumer usage | Example |
| --- | --- | --- | --- |
| Plain value | a string/attrset | read it directly | `postgres.out.fqdn`, `ingressNginx.out.ingressClassName` |
| Transformer | a function `manifest -> manifest` | pipe a resource through it | `clusterIssuer.out.withCert` (`... \|> (if hasTls then clusterIssuer.out.withCert else lib.id)`) |
| Builder | a function that constructs a resource | call it with scope/args | `prometheus.out.mkServiceMonitor scope { ... }` (used by `kix.monitor`) |

All three create the store-path DAG edge automatically: referencing `dep.out.<x>` carries the dep's
string context into the consumer's manifest, so kix orders the deploy without any explicit `requires`
(see `01-overview.md` on "store-path = DAG edge").

## Gotchas

- **The arg name is the contract.** Renaming a build arg renames the dep key. `postgres ? null`
  resolves against instances named or aliased `postgres`; there is no separate mapping.
- **Ambiguity throws, it does not pick.** Two same-namespace matches (or two cluster-wide matches
  with none local) is a hard error. Disambiguate with an alias, a namespace, or an explicit
  `deps.<name>` override.
- **A missing required dep is fatal.** No default plus no candidate plus no auto-instantiation candidate
  throws `no '<argName>' found in cluster`. Make a dep optional (`? null`) only if the package truly
  handles its absence.
- **Phase 1 never sees deps.** Code at the top level of a function package (outside `build`) runs
  with system args only. Anything that needs a dep must live inside a `build` entry, or it will see
  the dep as undefined.
- **Cross-namespace is restricted by `meta.scope`.** Depending on an instance in another namespace
  that declares `meta.scope = "namespace"` throws a cross-namespace error (`instance.nix`
  `_crossNsCheck`). See `09-networking-and-meta.md`.
- **Optionality is AND-ed across list entries.** If one `build` entry declares a dep required and
  another optional, the dep is required overall. Give every entry that names a dep the same default
  if you want it optional.
- **Imports can't touch deps.** A package evaluated via `mkImport { from = ...; }` that reads a dep
  throws. Provide the dep-derived field via an `out` override instead.
