# Overrides (the capstone)

This chapter covers every lever for changing a package's behavior from the cluster definition, without editing the package's `default.nix`. Packages are reusable; clusters customize. The instance submodule in `kix/lib/modules.nix` exposes the per-instance knobs (aliases, config, labelStyle, selectorLabels, optional, partsOverlays), the cluster exposes `globalPartsOverlays`, and `kix/lib/eval/resolve.nix` adds two more tools: `mkLocked` (freeze a field against dep injection) and dep `config` injection. `kix.mkEnv` (`kix/lib/env.nix`) stamps the same instances into per-environment namespaces. The earlier chapters explain the underlying mechanisms; this one is the operator's index of how to reach each one.

## The instance submodule

Every entry under `instances.<namespace>.<instanceName>` is a submodule with these fields (see `kix/lib/modules.nix`):

```nix
instances.media.immich = {
  package = packages.immich;          # required: the package function/attrset
  aliases = [ "photos" ];             # DI resolution keys (replaces meta.defaultAliases)
  config = { /* deep-merged options */ };
  deps = { storageClasses = ref.kube-system.platform-storage; };  # explicit DI overrides
  partsOverlays = [ /* post-build transforms */ ];
  labelStyle = "kix";                 # or "helm"
  selectorLabels = null;              # or an explicit { } to override auto labels
  optional = false;                   # dormant-until-depended-upon
  extraDeps = [ ];                    # extra ordering edges on the PackageInstance marker
  version = null;                     # overrides packageMeta.version on the marker
};
```

Multiple cluster modules can contribute to the same instance: `config` (a `deferredModule`) and `partsOverlays` (a list) merge across modules; `deps` collisions are an error you must resolve explicitly.

## config: deep-merge option overrides

`config` is the primary lever. It feeds the package's typed options through `evaluateInstanceConfig` (`kix/lib/eval/resolve.nix`), which runs `lib.evalModules` over `{ options = packageOptions; }` plus the cluster `global`, dep injections, and your instance config, then deep-merges the evaluated result on top of the option defaults with `lib.recursiveUpdate optionDefaults evaluated` (evaluated values win, the defaults fill the gaps). The deep-merge step means setting one nested field does not drop sibling defaults.

```nix
instances.immich.storage.config.size = lib.mkForce "200Gi";
instances.immich.valkey.config.auth = {
  secretSource = null;
  password = "dev-password";
};
```

Because `config` is a `deferredModule`, use `lib.mkDefault` / `lib.mkForce` for priority control when several modules set the same field (see 03-options-and-config.md). A cluster base module can set a default that a variant module forces.

## aliases: rename the DI key

`aliases` are the keys other instances resolve this one by (in addition to the instance name). The resolution index (`kix/lib/eval/resolve.nix` `buildResolutionIndex`) unions `[ instName ] ++ aliases`. When you set `aliases` non-empty it *replaces* the package's `meta.defaultAliases`; leaving it `[ ]` keeps the package defaults.

```nix
instances.kube-system.platform-storage = {
  package = kix.mkImport { out = { storageClassName = "kind-fast"; }; };
  aliases = [ "storageClasses" ];   # consumers requesting `storageClasses` resolve here
};
```

Aliases are how a package can be slotted into a DI role it does not name itself (an import standing in for `dns`, `storageClasses`, `database`). For disambiguating multiple instances of the same role, prefer an explicit `deps.<argName> = ref.<ns>.<inst>` at the consumer instead of aliases (see 07-dependency-injection.md).

## labelStyle: kix vs helm labels

`labelStyle` (`"kix"` | `"helm"`, passed to `mkScope` as `labelStyle`) controls the selector and instance label keys a workload emits. `"kix"` uses `app.kubernetes.io/*` keys; `"helm"` uses `app` / `release` keys (both set to the instance name) for Helm compatibility. Use `"helm"` when adopting resources a Helm release already owns, so `kubectl apply` matches on selectors instead of creating duplicates.

```nix
# A small cluster-wide helper, from nw1-luca/cluster.nix:
helmInstance = cfg: { labelStyle = "helm"; } // cfg;
```

Note `labelStyle = "helm"` covers selector/instance labels only, not Helm's ownership annotations (`meta.helm.sh/release-*`) - see `ROADMAP.md`.

## selectorLabels: pin immutable selectors

`selectorLabels` (default `null`, passed to `mkScope` as `selectorLabelsOverride`) replaces the auto-generated selector labels entirely. Use it when a live cluster has an immutable selector (a StatefulSet's `spec.selector` is immutable after creation) that matches neither the kix nor the Helm convention. Set it to the exact label map the running resource already uses, so kix's render matches and the apply is a no-op rather than a rejected mutation.

```nix
instances.data.postgres.selectorLabels = {
  "app.kubernetes.io/name" = "postgres";
  "statefulset.kubernetes.io/pod-name" = "postgres-0";
};
```

## optional: dormant instances

`optional = true` includes the instance in DI resolution but only deploys it if a non-optional instance transitively depends on it. This lets a cluster operator pre-configure a fully-specified instance (right aliases, right config) that only materializes when something needs it. Activated optionals get the annotation `kix.dev/optional-activated = "true"` (see `kix/lib/eval/instance.nix`).

```nix
# A platform storage import that only ships if a PVC actually consumes it.
instances.kube-system.platform-storage = lib.mkForce {
  package = kix.mkImport { out = { storageClassName = "kind-fast"; }; };
  aliases = [ "storageClasses" ];
  optional = true;
};
```

## partsOverlays: post-build resource transforms

A `partsOverlay` is a function with signature `scope: self: base: attrset` that runs after the package's `build` produces the parts attrset. In `kix/lib/eval/instance.nix` the overlays are bound to the scope (`map (o: o scope') allOverlays`) and then folded into the fixpoint:

```nix
allOverlays  = globalPartsOverlays ++ (instCfg.partsOverlays or [ ]);
parts = lib.fix (self:
  let merged = /* build output */; in
  builtins.foldl' (acc: overlay: acc // (overlay self acc)) merged boundOverlays);
```

So each overlay receives `scope` (already applied), the fixpoint `self`, and `base` (the accumulated parts so far), and returns an attrset that is `//`-merged onto `base`. Three operations:

- **Mutate** a rendered resource: return the key with a modified value, e.g. `root = base.root // { out = (base.root.out or {}) // { ... }; };`.
- **Add** a resource: return a new key not present in `base`.
- **Remove** a resource: return the key set to `null`. The parts collector filters to `(v._type or "") == "k8s-resource"`, so a `null` part drops out of the resource pool. (`root` must always remain a resource.)

Real example, exposing CRD builders on a Helm package's `out` (`clusters/test-monitoring-helm.nix`):

```nix
partsOverlays = [
  (scope: self: base:
    let smRef = scope.mkCRDRef {
          group = "monitoring.coreos.com";
          kind = "ServiceMonitor";
          plural = "servicemonitors";
        };
    in {
      root = base.root // {
        out = (base.root.out or { }) // {
          mkServiceMonitor = smRef.out.mkCR;
        };
      };
    })
];
```

Because the overlay runs inside the fixpoint with `self`, it can reference other (overlaid) parts. Because it gets `scope`, it can mint new resources with `scope.mkResource` / `scope.mkCRDRef` (see 04-resources-and-out.md, 08-secrets-crds-rbac.md).

## globalPartsOverlays: transform every instance

`globalPartsOverlays` (top-level cluster option, `kix/lib/modules.nix`) is a list of overlays with the *same* `scope: self: base: attrset` signature, applied to **every** instance and ordered *before* each instance's own `partsOverlays`. Use it for cluster-wide post-processing (inject a label, add a sidecar annotation, strip a field). The overlay must decide per-instance whether to act by inspecting `base` (and `scope` for the instance/namespace name); a no-op is just returning `{ }`.

```nix
globalPartsOverlays = [
  (scope: self: base:
    if base ? deployment
    then { deployment = base.deployment // { /* ... */ }; }
    else { })
];
```

## mkLocked: freeze a field against dep injection

A consumer package can inject config into a dep it depends on (next section). `kix.mkLocked` lets the cluster operator forbid that for a specific field. `mkLocked value` wraps the value as `{ _type = "locked"; value; }` (`kix/lib/eval/resolve.nix`). During config evaluation, kix scans the instance config for locked **top-level** fields; any dep injection targeting a locked key throws with source attribution:

```
dep config injection blocked by locked fields: 'extensions' (injected by media/immich)
```

The locked wrapper is unwrapped before `evalModules`, so the value still applies normally; it only blocks injections. Lock is top-level only - nested locking is not scanned.

```nix
instances.data.postgres.config.extensions = kix.mkLocked [ "pg_stat_statements" ];
# Now no consumer's deps.postgres.config.extensions can override this.
```

## Dep config injection (the thing mkLocked guards)

This lever lives in the *package*, not the instance, but it is an override mechanism so it belongs here. A package declares `deps.<argName>.config` to forward config into whatever instance resolves that dep. The value can be a static attrset or a function `consumerConfig: { ... }` that receives the consumer's own evaluated config (`kix/packages/stackgres-database/default.nix`):

```nix
deps.postgres.config = consumerConfig: {
  extensions = map (e: if builtins.isString e then { name = e; } else e)
                   consumerConfig.extensions;
};
```

`buildConfigInjections` inverts these into per-target injection lists; `evaluateInstanceConfig` merges them at the same priority as instance config (list-typed options concatenate, scalars error on conflict). A cluster operator overrides the *injecting* behavior by setting the dep target's field explicitly (highest priority via `lib.mkForce`) or by `mkLocked`-ing it. See 07-dependency-injection.md for the two-phase mechanics.

## mkEnv: same instances, many environments

`kix.mkEnv` (`kix/lib/env.nix`) stamps named instance sets into namespaces prefixed by environment name. Signature `mkEnv envName envConfig instanceSets`:

```nix
instances = kix.mkEnv "dev" {
  config = { /* env-wide values exposed to set functions via env.config */ };
  overrides = {
    app.api.config = { replicas = 1; };   # per-set, per-instance override
  };
} {
  app  = { ref, env }: { api = { package = packages.api; config = { }; }; };
  data = { ref, env }: { postgres = { package = packages.postgres; }; };
};
# => instances."dev-app".api, instances."dev-data".postgres
```

Each set function is called with `{ ref = { }; env = { name; config; }; }`. For every instance, `overrides.<set>.<inst>.config` is **shallow-merged** (`//`, not deep) onto the instance's `config`, and `overrides.<set>.<inst>.parts` replaces `parts` if present. Each stamped instance gains `_envScope = envName`. Call `mkEnv` once per environment (`"prod"`, `"stage"`, `"demo"`) and merge the results into `instances`; the DI graph is independent per env because namespaces differ and resolution is namespace-scoped (see 07-dependency-injection.md).

Gotcha: the override merge is shallow `//`, unlike the instance `config` deep-merge. A nested `overrides.app.api.config.resources = { cpu = ...; }` replaces the whole `resources` block, dropping sibling defaults. For deep semantics, prefer plain `instances."dev-app"` definitions with `lib.mkDefault` over `mkEnv` overrides. (You can also skip `mkEnv` entirely and write `instances."dev-vaultwarden"`, `instances."staging-vaultwarden"` by hand, as `ludo/variants/cluster-kind-env-stamped.nix` does.)

## Common mistakes

- **partsOverlay can't delete via `//`.** The fold is `acc // (overlay self acc)`; merging never removes keys. To drop a resource, return the key set to `null` so the `k8s-resource` filter discards it. You cannot remove `root`.
- **`aliases` replaces, not extends, `meta.defaultAliases`.** Setting `aliases = [ "x" ]` on a package whose default aliases include `"y"` loses `"y"`. Re-list everything you still need.
- **mkLocked is top-level only.** Locking `config.foo` protects `foo`; it does not protect `config.foo.bar` against an injection that targets `foo` wholesale - and nested keys aren't scanned.
- **`deps` collisions error.** Two modules setting `deps.<arg>` for the same instance is a hard error; resolve it in one place.
- **Cross-namespace + `meta.scope = "namespace"` throws.** An instance depending on a `namespace`-scoped dep in another namespace fails at eval (`kix/lib/eval/instance.nix` `_crossNsCheck`). mkEnv's per-env namespaces keep deps in-env to avoid this.
- **`selectorLabels` must match reality exactly.** A partial map produces a selector that matches nothing (or the wrong pods); copy the live resource's selector verbatim.

## Decision guide: I want to change X, use lever Y

| Goal | Lever |
|------|-------|
| Change a config value (size, replicas, image, host) | `instances.<ns>.<inst>.config` (with `mkDefault`/`mkForce`) |
| Make a package resolve under a different DI name | `aliases` (or `deps.<arg>` at the consumer) |
| Pin a dep to a specific instance | `deps.<argName> = ref.<ns>.<inst>` |
| Adopt Helm-managed resources on a live cluster | `labelStyle = "helm"` |
| Match an immutable StatefulSet selector | `selectorLabels = { ... }` |
| Pre-stage an instance that ships only when used | `optional = true` |
| Mutate / add / remove a rendered resource on one instance | `partsOverlays` |
| Apply a transform to every instance | `globalPartsOverlays` |
| Forbid a consumer from injecting into a field | `kix.mkLocked value` |
| Forward config from a consumer into its dep | `deps.<arg>.config` (in the package) |
| Run the same stack in dev/stage/prod namespaces | `kix.mkEnv` (or hand-written prefixed instances) |
| Add an extra ordering edge to the deploy graph | `extraDeps` |
| Override the version on the PackageInstance marker | `version` |
