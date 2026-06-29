# Resources and the `out` surface

This chapter covers the two primitive resource constructors a package uses to emit Kubernetes objects, `scope.mkResource` (namespaced) and `scope.mkClusterResource` (cluster-scoped), the full set of fields they accept, and the `out` attrset they return. `out` is the public face of every resource: it carries the auto-derived `name`, `fqdn`, `selector`, and `identityHash` (plus Service extras and any user-defined `outputs`), each wired with Nix string context so that referencing them creates the deploy-ordering DAG edges described in 01-overview.md. We also cover the three ways to declare dependencies (`requires`, `extraDeps`, and implicit string-context edges) and the label stack the scope pre-bakes for you.

## The two constructors

A package never calls the low-level `k8s.mkResource` directly. It calls the scope-injected wrappers (see 01-overview.md for how `scope` is built per instance):

- `scope.mkResource { ... }` - a namespaced resource. The wrapper injects the instance's namespace (`namespaceResource`) and the instance label stack, then forwards to `k8s.mkResource` (`kix/lib/eval/scope.nix`, `scopeMkResource`).
- `scope.mkClusterResource { ... }` - a cluster-scoped resource. The wrapper passes the `clusterScoped` sentinel as the namespace, so `metadata.namespace` is omitted (`scopeMkClusterResource`).

Both wrappers merge labels as `clusterLabels // instanceLabels // labels` (your `labels` arg wins) and stash your raw `labels` under a `packageLabels` field on the result for later introspection. Everything else passes straight through.

Workload kinds (Deployment, StatefulSet, DaemonSet, Job) go through the higher-level `scope.mkDeployment` / `mkStatefulSet` / `mkDaemonSet` / `mkJob` builders, which wrap `mkResource` with validation, selector handling, and netpol generation (see 05-workloads.md). This chapter is about the raw constructor underneath.

## The full field set

`k8s.mkResource` (`kix/lib/k8s.nix`) accepts these fields. Only `apiVersion`, `kind`, and `name` are mandatory (the scope supplies `namespace`):

```nix
self.configmap = scope.mkResource {
  apiVersion = "v1";
  kind = "ConfigMap";
  name = "${rName}-config";
  data = { "settings.json" = builtins.toJSON cfg; };
};
```

| Field | Purpose |
| --- | --- |
| `apiVersion`, `kind`, `name` | required; written verbatim into the manifest |
| `namespace` | injected by the scope wrapper - a namespace resource, the `clusterScoped` sentinel, or a plain string |
| `spec` | the resource `spec` sub-tree. kix manages this so it can attach DI tracking to `spec.selector` |
| `data` | ConfigMap/Secret `data` |
| `stringData` | Secret `stringData` |
| `labels`, `annotations` | merged into `metadata.labels` / `metadata.annotations` |
| `extra` | passthrough for K8s fields kix does not model (e.g. `extra.spec` on a CRD, `extra.webhooks` on a webhook config) |
| `outputs` | user-defined entries added to `out` (see below) |
| `requires` | explicit hard-ordering deps (see "Dependencies") |
| `extraDeps` | explicit soft DAG edges (see "Dependencies") |

### `extra` cannot shadow managed fields

`extra` is for sibling fields kix does not own. It must not set `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, or any path under `spec`, `data`, or `stringData` when those args are non-empty. Doing so throws at eval time:

```
k8s-resource 'Service/foo': extra.* shadows managed field(s) spec. Fields under
`spec`, `data`, `stringData`, `metadata.{name,namespace,labels,annotations}` are
set via dedicated args so kix can attach DI tracking. Move your customizations
into those args ...
```

The reason: kix attaches dependency-tracking context to `spec.selector` and derives `out` from `spec`/`metadata`. Routing those through `extra` (a plain `lib.recursiveUpdate` overlay) would silently bypass that. `metadata.labels` and `metadata.annotations` under `extra` are allowed - they merge additively (e.g. `extra.metadata.labels.grafana_datasource = "1"`).

## The `out` surface

Every resource returns a `self` attrset. The public part is `out`. kix derives these fields automatically (`autoOut` in `kix/lib/k8s.nix`):

- `out.name` - the resource's real K8s name, carrying this resource's own store-path context.
- `out.fqdn` - `"${name}.${namespace}.svc.${clusterDomain}"` for namespaced resources, or just `name` for cluster-scoped ones.
- `out.identityHash` - the 32-char base32 hash of the resource's content-addressed store path. Changes whenever the rendered manifest changes.
- `out.selector` - present when the resource has `spec.selector.matchLabels` (workloads) or, failing that, `metadata.labels`. Each value carries the resource's store-path context.

Every leaf in `out` is a string carrying Nix string context pointing at this resource's store path (`out.selector` is an attrset, but each of its values is such a string). That context is what makes consumption create a DAG edge.

### Service extras: `out.ports` and `out.url`

When `kind == "Service"` and the spec has `spec.ports`, `out` gains two more entries:

- `out.ports` - the raw `spec.ports` list (plain values, no per-leaf context - port numbers do not carry graph edges).
- `out.url` - a function `{ scheme ? "http", port ? null }: <url-string>`. It builds `"${scheme}://${name}.${ns}.svc.${clusterDomain}:${port}"` and stamps the Service's own context onto the result, so consumers wiring it into an env var get an automatic DAG (and netpol) edge. The default port is the first entry in `spec.ports`; pass `{ port = ...; }` for multi-port Services.

```nix
env = [
  { name = "API_URL"; value = self.service.out.url { port = 8080; }; }
];
```

These two match the shape of `mkServiceRef`'s `out`, so a consumer can swap between a kix-managed Service and a ServiceRef over an operator-managed one without changing how it reads the endpoint (see 06-composition-helpers.md and 08-secrets-crds-rbac.md).

### User-defined `outputs`

The `outputs` arg lets a resource publish extra named values on `out`. Each value is `toString`-ed and gets this resource's context attached, so it behaves exactly like an auto-derived output. A `null` value suppresses an auto-derived field of the same name. User outputs override auto-derived ones on key collision.

This is the channel for carrying derived facts (a computed URL, a chosen port, a config key) downstream to dependents, who then pick up the DAG edge by reading the value.

## Prefer `self.svc.out.name` over `"${self.svc}"`

Both expressions resolve to a value carrying this Service's store-path context, so both create a working DAG edge. Always prefer `out`:

- `self.svc.out.name` evaluates to the resource's real K8s name (e.g. `"my-svc"`), which is what belongs in a manifest field.
- `"${self.svc}"` interpolates the resource's store path (e.g. `"/nix/store/abc...-k8s-Service-..."`), which is a store path string, not a K8s name. It still carries context (so ordering works), but it is the wrong value to put in a manifest, and it reads as an accident.

The DSL principle (see CLAUDE.md): resources are rich objects. Query `out` for the property you need (`name`, `fqdn`, `selector`, `url`) rather than relying on interpolation. `${resource}` embedding the store path is retained only for backward compatibility.

## `out.selector` vs `rawSelector`

A Service that fronts a workload should select the workload's pods. Read `out.selector` from the workload:

```nix
# kix/packages/coredns/default.nix
self.metricsService = scope.mkResource {
  apiVersion = "v1"; kind = "Service"; name = "...";
  spec.selector = self.deployment.out.selector;
};
```

`out.selector` carries the workload's full store-path context, so the Service gets an explicit DAG edge to the Deployment. That is the intended direction: the Service deploys after the Deployment and never lands in a wave with zero endpoints behind it.

The escape hatch is `workload.rawSelector` - the same `matchLabels` attrset but with NO store-path context. Use it only to break a cycle where the workload itself `requires` the Service (e.g. ingress-nginx's `--publish-service` startup constraint forces Deployment -> Service, so the Service consuming `out.selector` would close a loop):

```nix
# kix/packages/ingress-nginx/default.nix
# rawSelector avoids an evaluation cycle: the Deployment requires this Service.
spec.selector = self.deployment.rawSelector;
```

`rawSelector` is attached as a sideband field by the workload builders, not by raw `mkResource`. It is a targeted tool, not the default.

## `identityHash` and config-checksum annotations

`out.identityHash` is the canonical way to force a pod restart when its config changes. Stamp the ConfigMap's `identityHash` into the pod template's annotations: when the ConfigMap content changes, the hash changes, the pod template changes, and K8s rolls the workload.

```nix
# kix/packages/python-app/backend.nix
template = {
  metadata = {
    labels = selectorLabels compName;
  } // lib.optionalAttrs config.useConfigMap {
    annotations = {
      "checksum/config" = self.configmap.out.identityHash;
    };
  };
  spec = ...;
};
```

This is the same idiom Helm charts implement with `sha256sum` over the rendered ConfigMap; in kix you get the content hash for free off `out`, and reading it also creates the ConfigMap -> Deployment DAG edge.

## Dependencies: three mechanisms

There are three ways an edge enters a resource's dependency set. The `mkResource` annotation logic (`kix/lib/k8s.nix`) tags each in the `kix.dev/depends-on` manifest annotation.

1. **Implicit string-context edges** (the default, "store-path = DAG edge"). Any string in `spec`/`data`/`metadata` that carries another resource's store-path context - because you wrote `self.x.out.name`, `self.x.out.fqdn`, `self.x.out.url {}`, etc. - is discovered from the manifest JSON's context and recorded as a bare-hash dep. This is how the vast majority of edges form. You never declare them as data; you just reference `out`.

2. **`requires`** - a list of resource handles, for hard ordering edges that are NOT expressed through a manifest field. The dep must be Ready before this resource deploys. Tagged `requires:<hash>`. Used for things like a CR that must wait on its CRD, or a workload that must wait on its network policies.

3. **`extraDeps`** - a list of resource handles for additional DAG edges (ordering hints) that do not rise to a hard requirement. Tagged `extra:<hash>`.

All three influence the content-addressed store path (and thus the cluster DAG that the CLI walks for wave ordering): `requires` and `extraDeps` contexts are folded into the manifest's string context before `builtins.toFile` hashes it. Prefer mechanism 1 whenever the dep is naturally expressed by a field value; reach for `requires`/`extraDeps` only for edges that have no manifest representation.

## The label stack

The scope pre-bakes three label tiers so packages stop hand-composing them (`kix/lib/eval/scope.nix`):

- `scope.labels.selector` - the pod-match labels (`app.kubernetes.io/name` + `app.kubernetes.io/instance`, or the `helm`-style `app` + `release` when `labelStyle = "helm"`). Use these for `spec.selector.matchLabels` and pod template labels.
- `scope.labels.common` - `selector` plus instance labels (`app.kubernetes.io/managed-by = "kix"` etc.). Use for non-selector labels on managed resources.
- `scope.labels.clusterScoped` - a minimal name + managed-by pair for cluster-scoped resources that cannot reference an instance hierarchy.

`scope.selectorLabels` is also exposed directly as a shorthand for the selector tier. Callers `//` additional keys on top as needed. The exact contents are driven by `labelStyle` and `selectorLabelsOverride` instance options (see 12-overrides.md).

```nix
self.deployment = scope.mkDeployment {
  name = rName;
  spec = {
    selector.matchLabels = scope.selectorLabels;
    template.metadata.labels = scope.selectorLabels;
    template.spec = { ... };
  };
};
```

## Gotchas

- **`extra` shadowing throws.** If you try to set `spec.*`, `data`, `stringData`, `apiVersion`, `kind`, or `metadata.{name,namespace}` through `extra`, eval fails. Put those in the dedicated args. Only `metadata.labels`/`metadata.annotations` are mergeable via `extra`.
- **`out.selector` only exists when there is something to derive it from.** It is present only when the resource has `spec.selector.matchLabels` or `metadata.labels`. A bare ConfigMap has no `out.selector`.
- **Use `out.name` in manifests, not `${resource}`.** The latter is a store path, not a K8s name. Both order correctly, but only the former is the right value to write.
- **`rawSelector` breaks edges on purpose.** Reaching for it when you do not have a genuine cycle drops a real ordering edge - the Service can land in a wave before its workload exists. Default to `out.selector`.
- **StatefulSet `serviceName` wants the plain `.name`, not `.out.name`.** Using the context-bearing `out.name` for `spec.serviceName` creates a Service edge that, combined with a Service that `requires` the StatefulSet, causes infinite recursion. The `headlessService = svc` shorthand in `mkStatefulSet` handles this for you (see 05-workloads.md).
- **Non-string leaves are not tracked.** If you put an int or bool that "should" carry a dep, no context attaches and you get a trace warning, not an edge. Dependency values are strings from `out`.
