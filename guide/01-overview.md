# Overview & mental model

This chapter is the conceptual on-ramp for authoring kix packages. It explains what a package is, where it sits in the evaluation pipeline (flake to YAML), and the one idea that makes everything else cohere: a Nix store path *is* a dependency-graph edge. Read this first, then dive into the per-topic chapters for mechanics. Nothing here invents API; every name is grounded in `kix/lib/k8s.nix`, `kix/lib/eval/cluster.nix`, and `kix/lib/architecture.md`.

## What kix is

kix is a Kubernetes manifest *compiler* written in Nix. You describe resources as Nix data, kix evaluates them into a directory of plain YAML, and a separate Rust CLI deploys that YAML in dependency order. The compiler's job is to take rich, interconnected resource definitions and emit standard K8s objects while remembering how they depend on each other.

Two kinds of file make up a cluster:

- A **package** (`kix/packages/<name>/default.nix`) produces a set of related K8s resources (a ConfigMap + Deployment + Service, say). It is reusable and parameterized.
- A **cluster** (`clusters/<name>.nix`) wires packages into namespaces, sets their config, and calls `kix.buildCluster`.

## What a package is

A package is a function:

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

It can also be a plain attrset with the same keys (the "inline" form) when it takes no outer arguments. The keys:

- `meta` (optional) - version, description, `provides`, default aliases. See (09-networking-and-meta.md).
- `options` (optional) - typed config schema via `lib.mkOption`. See (03-options-and-config.md).
- `deps` (optional) - dependency enrichment hooks. See (07-dependency-injection.md).
- `build` - a function (or a *list* of functions) returning a "self" attrset of named resources.

`build` receives `self` (the lazy fixpoint of this package's own resources), `config` (the evaluated option values), and any **dependency arguments** it names (e.g. `{ self, config, postgres ? null, ... }`). The returned attrset uses conventional keys: `root` is the entry point; siblings like `service`, `ingress`, `configmap` are the other resources. The echo-server package (`kix/packages/echo-server/default.nix`) is a clean reference: it returns `configmap`, `deployment`, `service`, and sets `root = self.service`.

## The evaluation pipeline

`kix.buildCluster` in `kix/lib/eval/cluster.nix` is the orchestrator. The stages, in order:

1. **Flake to buildCluster.** `mkFlake` (or a raw `buildCluster` call) hands a list of modules to the cluster builder.
2. **evalModules.** `lib.evalModules` merges the cluster config (instances, namespaces, `cluster.*`, scorecard, networkPolicy). Config values are stored lazily; `ref` (the eventual fixpoint) is exposed via `specialArgs` but not forced yet.
3. **Auto-instantiate.** `computeAutoInstances` activates optional deps and implicit instances that another instance needs. Explicit instances always win over auto-instances.
4. **Resolution index.** `buildResolutionIndex` builds a DNS-like map of instance names + aliases used to resolve dependency arguments.
5. **Phase-1 pre-pass.** Each package is called with a *minimal* scope (naming only). kix introspects the `build` function signature to discover its dep arguments, resolves their targets, and lets deps inject config (e.g. a prometheus dep adding a ServiceMonitor). `build` is **not** executed here, only inspected.
6. **Per-instance fixpoint.** `lib.fix` over all instances. For each, `evaluateInstance` builds a per-instance `scope`, binds resolved dep instances, runs `build()`, collects the resources, derives network policies, and runs scorecard rules. Because it is a fixpoint, `self.x` and cross-instance references resolve lazily.
7. **Aggregate.** All resources across all active instances are collected, a `PackageInstance` CR is built per instance, and a single cluster-level `Activation` CR is built referencing every PackageInstance.
8. **YAML.** The aggregated manifests are rendered to a directory of YAML files.

(There is a smaller phase-2a "config-only" fixpoint between 5 and 6 that resolves function-shaped config injections without triggering build cycles. You can ignore it until you write a dep that projects consumer config into a dependency; see 12-overrides.md.)

## Store-path = DAG edge (the core idea)

Resources never declare their dependencies as plain data. There is no `dependsOn: ["configmap"]` field. Instead, dependencies fall out of *how you reference other resources*.

Every resource is built by `mkResource` (`kix/lib/k8s.nix`), which writes the manifest JSON to a content-addressed Nix store path via `builtins.toFile`. The resource's public values - `out.name`, `out.fqdn`, `out.selector`, `out.identityHash` - are that real string (e.g. `"echo-server"`) with the resource's store-path **Nix string context** attached. When one resource embeds another's `out.name`, the referencing manifest's JSON inherits that string context. `mkResource` reads the context back off the JSON:

```nix
implicitCtxPaths = builtins.filter (p: lib.hasPrefix "/nix/store/" p) (
  builtins.attrNames (builtins.getContext manifestJson)
);
```

and stamps each referenced store hash into a `kix.dev/depends-on` annotation on the manifest. So referencing `self.configmap.out.name` from a volume mount creates a real DAG edge: the Deployment now depends on the ConfigMap. The CLI later walks this store DAG to compute deploy order and waves.

This is why you should always prefer `self.svc.out.name` (or `"${self.svc}"` interpolation, which embeds the store path) over a hardcoded string. A hardcoded `"echo-server"` carries no context, so kix sees no edge, and the deploy order is unconstrained.

Helpers in `k8s.nix` make this work:

- `attachCtxDeep ctx value` - recursively attach a store-path context to every string leaf, used for `self.x.manifest` field access.
- `extractStoreHash path` - pull the 32-char hash out of a store path for the depends-on annotation.
- `requires` / `extraDeps` - explicit edges for cases where no value flows between resources (the dep contributes context to the store path without appearing in the manifest body).

## Manifests keep real names; context rides alongside

A subtle but important property: the YAML kix emits contains plain Kubernetes names (`metadata.name: echo-server`), never store paths. The dependency information travels *next to* the strings via Nix's string-context system, not *inside* them. `mkResource` deliberately sanitizes context off the store-path *filename* (it cannot carry references) while keeping full context on the file *content*, so every dep edge survives. This is what lets the manifests stay human-readable and `kubectl apply`-able while still encoding the full graph.

`_kix.*` reserved keys carry other internal metadata (cross-namespace validation, provenance). `stripKixMeta` removes them right before serialization, so no marker leaks into the rendered YAML.

## The Activation CR roots the closure

`mkActivation` (`k8s.nix`) builds a single cluster-scoped `Activation` custom resource whose `spec.instances` references every `PackageInstance` by name - each reference carrying that PI's store-path context. Because every PI in turn references its resources, running `nix-store -q --tree` (or `exportReferencesGraph`) on the Activation derivation yields the entire cluster's deploy DAG. This is the contract the CLI relies on: the Activation is the single root from which the whole closure is reachable. Each `PackageInstance` is the per-package sub-root (it stamps `kix.dev/root`, inverse-deps, and package-level requires).

## End-to-end: one package, one instance

A minimal single-resource package that emits one ConfigMap:

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

Wiring it into a cluster instance (the same shape as `clusters/example.nix`):

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

`buildCluster` evaluates this into a `ConfigMap/banner` in namespace `apps`, a `PackageInstance/banner`, the two kix CRDs, the namespace, and one `Activation` rooting it all. `scope.instanceName` resolves to `banner` (the instance key), so the resource is named after how the cluster wired it - not hardcoded in the package.

From here:

- Package shape, `self`, `root`, warnings - (02-package-anatomy.md).
- Options and config flow - (03-options-and-config.md).
- `scope.mkResource` / `mkClusterResource` and the `out` API - (04-resources-and-out.md).
- Dependency injection and the two-phase calling model - (07-dependency-injection.md).

## Gotchas

- **Hardcoded names break ordering.** A literal `"echo-server"` string carries no store-path context, so kix infers no edge. Always reference `self.x.out.name` / `"${self.x}"` so the DAG edge is created.
- **Non-string manifest leaves are not tracked.** `attachCtxDeep` traces a warning for int/bool leaves because context cannot ride on them. Dep tracking flows only through string values; use `requires`/`extraDeps` when no string flows between resources.
- **`extra.*` cannot shadow managed fields.** `mkResource` throws if `extra` sets `spec`, `data`, `stringData`, or `metadata.{name,namespace}` - those go through dedicated args so kix can attach DI tracking. `extra` is only for sibling K8s fields kix does not model.
- **`_type` marks a leaf.** Resource collection stops descending at any attrset carrying `_type` (e.g. `k8s-resource`). That is how nested resources in `self` get flattened without the collector eating into the resource itself.
- **The Activation must reach everything.** If a resource is not transitively referenced from a PackageInstance (which the Activation references), it is outside the closure and the CLI will not see it. Edges come from references, so an unreferenced resource is an orphan.
