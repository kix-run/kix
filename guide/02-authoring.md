# Authoring API

The day-to-day toolkit: resources, workloads, composition helpers, and dependency injection.

Sections: [Resources and the `out` surface](#resources-and-the-out-surface) · [Workloads](#workloads) · [Composition helpers (kix.*)](#composition-helpers-kix) · [Dependency injection](#dependency-injection)

## Resources and the `out` surface

Reference for `scope.mkResource` / `scope.mkClusterResource`, their fields, and the `out` attrset.

### Constructors

Packages call scope-injected wrappers, never `k8s.mkResource` directly (see `01-fundamentals.md#overview--mental-model` for scope construction).

| Constructor | Scope | Behavior |
| --- | --- | --- |
| `scope.mkResource { ... }` | namespaced | injects instance namespace (`namespaceResource`) + instance label stack, forwards to `k8s.mkResource` (`scopeMkResource` in `kix/lib/eval/scope.nix`) |
| `scope.mkClusterResource { ... }` | cluster-scoped | passes `clusterScoped` sentinel as namespace; `metadata.namespace` omitted (`scopeMkClusterResource`) |

- Both merge labels as `clusterLabels // instanceLabels // labels` (your `labels` wins).
- Both stash raw `labels` under `packageLabels` on the result.
- Workload kinds (Deployment, StatefulSet, DaemonSet, Job) go through `scope.mkDeployment` / `mkStatefulSet` / `mkDaemonSet` / `mkJob` (validation, selector handling, netpol gen) - see `02-authoring.md#workloads`. This chapter covers the raw constructor.

### Field set

`k8s.mkResource` (`kix/lib/k8s.nix`). Required: `apiVersion`, `kind`, `name` (scope supplies `namespace`).

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
| `apiVersion`, `kind`, `name` | required; verbatim into manifest |
| `namespace` | injected by scope: namespace resource, `clusterScoped` sentinel, or plain string |
| `spec` | resource `spec` sub-tree; kix manages it to attach DI tracking to `spec.selector` |
| `data` | ConfigMap/Secret `data` |
| `stringData` | Secret `stringData` |
| `labels`, `annotations` | merged into `metadata.labels` / `metadata.annotations` |
| `extra` | passthrough for fields kix does not model (e.g. `extra.spec` on a CRD, `extra.webhooks` on a webhook config) |
| `outputs` | user-defined entries added to `out` |
| `requires` | explicit hard-ordering deps (see Dependencies) |
| `extraDeps` | explicit soft DAG edges (see Dependencies) |

#### `extra` cannot shadow managed fields

- `extra` = sibling fields kix does not own.
- Must NOT set `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, or any path under `spec`/`data`/`stringData` (when those args are non-empty). Throws at eval:

```
k8s-resource 'Service/foo': extra.* shadows managed field(s) spec. Fields under
`spec`, `data`, `stringData`, `metadata.{name,namespace,labels,annotations}` are
set via dedicated args so kix can attach DI tracking. Move your customizations
into those args ...
```

- Reason: kix attaches dep-tracking context to `spec.selector` and derives `out` from `spec`/`metadata`; `extra` is a plain `lib.recursiveUpdate` overlay that bypasses that.
- Allowed via `extra`: `metadata.labels` / `metadata.annotations` (merge additively, e.g. `extra.metadata.labels.grafana_datasource = "1"`).

### `out` surface

Resource returns a `self` attrset; public part is `out`. Auto-derived (`autoOut` in `kix/lib/k8s.nix`):

| `out` field | Value |
| --- | --- |
| `out.name` | real K8s name; carries this resource's store-path context |
| `out.fqdn` | `"${name}.${namespace}.svc.${clusterDomain}"` (namespaced) or `name` (cluster-scoped) |
| `out.identityHash` | 32-char base32 hash of content-addressed store path; changes when rendered manifest changes |
| `out.selector` | present when resource has `spec.selector.matchLabels` (workloads) or else `metadata.labels`; each value carries store-path context |

Every leaf in `out` is a string carrying Nix string context pointing at this resource's store path (`out.selector` is an attrset whose values are such strings). That context creates the DAG edge on consumption.

#### Service extras: `out.ports`, `out.url`

When `kind == "Service"` and spec has `spec.ports`:

- `out.ports` - raw `spec.ports` list; plain values, NO per-leaf context (port numbers carry no graph edges).
- `out.url` - function `{ scheme ? "http", port ? null }: <url-string>`. Builds `"${scheme}://${name}.${ns}.svc.${clusterDomain}:${port}"`, stamps Service's own context onto result (so env-var consumers get an automatic DAG + netpol edge). Default port = first entry in `spec.ports`; pass `{ port = ...; }` for multi-port.

```nix
env = [
  { name = "API_URL"; value = self.service.out.url { port = 8080; }; }
];
```

`out.ports`/`out.url` match `mkServiceRef`'s `out` shape, so consumers swap a kix-managed Service for a ServiceRef over an operator-managed one without changing reads (see `02-authoring.md#composition-helpers-kix`, `03-advanced.md#secrets-crds-rbac`).

#### User-defined `outputs`

- Publishes extra named values on `out`. Each value is `toString`-ed and gets this resource's context attached (behaves like an auto-derived output).
- `null` value suppresses an auto-derived field of the same name.
- User outputs override auto-derived ones on key collision.
- Use to carry derived facts (computed URL, chosen port, config key) downstream; dependents pick up the DAG edge by reading the value.

### Prefer `self.svc.out.name` over `"${self.svc}"`

Both carry the Service's store-path context (both create a working DAG edge). Always prefer `out`:

- `self.svc.out.name` → real K8s name (e.g. `"my-svc"`); correct manifest value.
- `"${self.svc}"` → resource store path (e.g. `"/nix/store/abc...-k8s-Service-..."`); carries context (ordering works) but is the wrong value for a manifest.
- DSL principle (CLAUDE.md): resources are rich objects; query `out` (`name`, `fqdn`, `selector`, `url`). `${resource}` store-path embedding retained for backward compat only.

### `out.selector` vs `rawSelector`

Service fronting a workload reads the workload's `out.selector`:

```nix
# kix/packages/victoria-metrics-operator/operator.nix
operatorService = scope.mkResource {
  apiVersion = "v1"; kind = "Service"; name = name;
  spec.selector = self.operatorDeployment.out.selector;
};
```

- `out.selector` carries workload's full store-path context → explicit DAG edge to the Deployment. Service deploys after Deployment; never lands in a wave with zero endpoints.
- `workload.rawSelector` - same `matchLabels`, NO store-path context. Use only to break a cycle where the workload itself `requires` the Service (e.g. ingress-nginx `--publish-service` forces Deployment -> Service, so `out.selector` would close a loop):

```nix
# kix/packages/ingress-nginx/default.nix
# rawSelector avoids an evaluation cycle: the Deployment requires this Service.
spec.selector = self.deployment.rawSelector;
```

- `rawSelector` is a sideband field from the workload builders, not raw `mkResource`. Targeted tool, not default.

### `identityHash` and config-checksum annotations

`out.identityHash` forces a pod restart when config changes. Stamp the ConfigMap's `identityHash` into the pod template annotations; content change -> hash change -> template change -> K8s rolls the workload.

```nix
# kix/packages/valkey/default.nix
template = {
  metadata.annotations = {
    "checksum/configMap" = self.configMap.out.identityHash;
  }
  # A secret-ref has no identityHash.
  // lib.optionalAttrs (password.out ? identityHash) {
    "checksum/valkeyPassword" = password.out.identityHash;
  };
  spec = ...;
};
```

Same idiom as Helm's `sha256sum` over the rendered ConfigMap; here the content hash is free off `out`, and reading it also creates the ConfigMap -> Deployment DAG edge.

### Dependencies: three mechanisms

Edge sources for a resource's dependency set. `mkResource` (`kix/lib/k8s.nix`) tags each in the `kix.run/depends-on` manifest annotation.

| Mechanism | What | Tag |
| --- | --- | --- |
| Implicit string-context edges (default) | any string in `spec`/`data`/`metadata` carrying another resource's store-path context (because you wrote `self.x.out.name`, `self.x.out.fqdn`, `self.x.out.url {}`, etc.); discovered from manifest JSON context. Forms the vast majority of edges; never declared as data | bare-hash |
| `requires` | list of resource handles; hard ordering edges NOT expressed through a manifest field; dep must be Ready before deploy (e.g. CR waiting on CRD, workload waiting on netpols) | `requires:<hash>` |
| `extraDeps` | list of resource handles; additional DAG edges (ordering hints), not hard requirements | `extra:<hash>` |

- All three influence the content-addressed store path (and thus the cluster DAG the CLI walks for wave ordering): `requires` and `extraDeps` contexts are folded into manifest string context before `builtins.toFile` hashes it.
- Prefer mechanism 1 when the dep is naturally a field value; use `requires`/`extraDeps` only for edges with no manifest representation.

### Label stack

Scope pre-bakes three tiers (`kix/lib/eval/scope.nix`):

| Tier | Contents | Use |
| --- | --- | --- |
| `scope.labels.selector` | pod-match labels (`app.kubernetes.io/name` + `app.kubernetes.io/instance`, or `app` + `release` when `labelStyle = "helm"`) | `spec.selector.matchLabels`, pod template labels |
| `scope.labels.common` | `selector` plus instance labels (`app.kubernetes.io/managed-by = "kix"` etc.) | non-selector labels on managed resources |
| `scope.labels.clusterScoped` | minimal name + managed-by pair | cluster-scoped resources with no instance hierarchy |

- `scope.selectorLabels` - shorthand for the selector tier. Callers `//` extra keys on top.
- Contents driven by `labelStyle` and `selectorLabelsOverride` instance options (see `03-advanced.md#overrides`).

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

### Gotchas

- **`extra` shadowing throws.** Setting `spec.*`, `data`, `stringData`, `apiVersion`, `kind`, or `metadata.{name,namespace}` via `extra` fails eval. Only `metadata.labels`/`metadata.annotations` are mergeable via `extra`.
- **`out.selector` only exists when derivable** - present only with `spec.selector.matchLabels` or `metadata.labels`. A bare ConfigMap has none.
- **Use `out.name` in manifests, not `${resource}`** (store path, not K8s name). Both order correctly; only `out.name` is the right value.
- **`rawSelector` breaks edges on purpose.** Using it without a genuine cycle drops a real ordering edge (Service can land in a wave before its workload). Default to `out.selector`.
- **StatefulSet `serviceName` wants plain `.name`, not `.out.name`.** Context-bearing `out.name` for `spec.serviceName` + a Service that `requires` the StatefulSet -> infinite recursion. The `headlessService = svc` shorthand in `mkStatefulSet` handles this (see `02-authoring.md#workloads`).
- **Non-string leaves are not tracked.** An int/bool that "should" carry a dep attaches no context -> trace warning, not an edge. Dependency values are strings from `out`.

## Workloads

Constructors `scope.mkDeployment`, `scope.mkStatefulSet`, `scope.mkDaemonSet`, `scope.mkJob` (per-instance scope, `kix/lib/eval/scope.nix`). Plus `serviceAccount`/`headlessService` shorthands, `rawSelector`, `scope.mkOptional`, `scope.mkWebhookService`.

### Constructors

- All four share one impl. `mkDeployment`/`mkStatefulSet`/`mkDaemonSet` are partial applications of internal `mkWorkload apiVersion kind`. `mkJob` is a near-clone.

```nix
mkDeployment  = mkWorkload "apps/v1" "Deployment";
mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
mkDaemonSet   = mkWorkload "apps/v1" "DaemonSet";
# mkJob is "batch/v1" "Job"
```

- Pass an attrset shaped like a K8s workload manifest, minus `apiVersion`/`kind`. Pipe-friendly.

```nix
deployment =
  {
    inherit name;
    spec = {
      replicas = config.replicas;
      selector.matchLabels = scope.selectorLabels;
      template.spec = {
        containers = [
          {
            name = "nginx";
            image = "${config.image.repository}:${config.image.tag}";
            ports = [ (kix.port "http" 80) ];
            # ... probes, resources, volumeMounts ...
          }
        ];
        volumes = [
          { name = "config"; configMap.name = self.configmap.out.name; }
        ];
      };
    };
  }
  |> scope.mkDeployment;
```

- Returns a normal kix resource (`out.name`, `out.selector`, `out.fqdn`, ...; see `02-authoring.md#resources-and-the-out-surface`). Flows into `kix.service.fromWorkload` and composition helpers (see `02-authoring.md#composition-helpers-kix`).

### What `mkWorkload` does to the spec

- Sets `apiVersion` and `kind`. Never write them.
- Requires `spec.selector.matchLabels`. Absence throws `mkWorkload (<kind>): spec.selector.matchLabels is required - use scope.selectorLabels`. Use `scope.selectorLabels`.
- Copies selector into template labels: if `spec.template.metadata.labels` unset, sets template labels = `selector.matchLabels`. If you supply template labels, instead validates selector subset (see below) and keeps your labels.
- Expands `serviceAccount` and (StatefulSet only) `headlessService` shorthands.
- Generates per-workload CiliumNetworkPolicies + DNS/egress ordering deps via `netpol.buildWorkloadCnps`; attaches as `requires` and `_generatedNetpol` sideband (see `03-advanced.md#networking--package-meta`). At construction time, before `build` returns.

`mkJob` differs: usually omits `spec.selector` (API server generates it), so selector falls back to `spec.template.metadata.labels`; does not copy selector into labels; skips DaemonSet and selector-subset checks; only emits `selector.matchLabels` if supplied.

### Build-time validators

- Chained with `builtins.seq`; any failure throws during evaluation, before deploy. Messages prefixed with `[<instanceName>]`.
- Capability checks skipped entirely when `capabilities == {}` (e.g. standalone scope in tests). A `true` or absent capability passes.

| Validator | Applies to | Throws on |
|---|---|---|
| `checkSelectorSubset` | Deploy/StatefulSet/DaemonSet, only when you supplied template labels | Each `selector.matchLabels` key must be in `template.metadata.labels` with equal value. Missing key throws `spec.selector.matchLabels ⊄ spec.template.metadata.labels`; value mismatch throws value-mismatch error. Catches workload deploying pods it can never manage. |
| `checkNamespacedRefs` | all | Every namespaced ref (Secret volume/`secretRef`/`secretKeyRef`, ConfigMap volume/`configMapRef`/`configMapKeyRef`, PVC `claimName`, `imagePullSecrets`, `serviceAccountName`) must (1) carry Nix string context (from `resource.out.*` or `kix.untrackedRef`, not a bare literal) and (2) be same-namespace. Untracked throws `Untracked <kind> reference ...`; cross-namespace throws `Cross-namespace <kind> reference ...`. Fix: mirror into namespace or use a reflector. |
| `checkNamedPorts` | all (not mkJob) | Any named port in `livenessProbe`/`readinessProbe`/`startupProbe` (`httpGet`/`tcpSocket`/`grpc` with string `port`) must be a named `containerPort` on the same container. Integer ports pass unchecked. Suggests `ports = [ (kix.port "name" N) ]`. |
| `checkContainerResources` | all | Per container, `resources.limits.{cpu,memory}` must be `>=` matching `requests`. Quantities parsed (`100m`, `1`, `128Mi`, `1Gi`, decimals); unparseable values silently skipped. K8s rejects `limits < requests` at admission. |
| `checkDuplicateNames` | all | Container names (incl. initContainers) unique within pod; volume names unique within pod; env var names unique within each container; named ports unique within each container. Duplicate volume names often = two auto-derived mounts from same-named resources. |
| `checkFieldRefs` | all | Every `env[].valueFrom.fieldRef.fieldPath` must be supported downward-API path (`metadata.name`, `metadata.namespace`, `metadata.uid`, `metadata.labels`, `metadata.annotations`, `spec.nodeName`, `spec.serviceAccountName`, `status.hostIP`, `status.podIP`, `status.podIPs`, plus `metadata.labels['key']` / `metadata.annotations['key']`). Unsupported paths fail pod creation cryptically. |
| `checkPrivileged` (capability gate) | all | Container `securityContext.privileged = true`, or pod `hostNetwork`/`hostPID`/`hostPath` volume, while `cluster.capabilities.privilegedContainers == false`. Message names the offending feature. |
| `checkDaemonSet` (capability gate) | DaemonSet only | `cluster.capabilities.daemonSets == false` (e.g. GKE Autopilot). |
| `checkLoadBalancer` (capability gate) | any `Service` (runs inside `scopeMkResource`) | `type=LoadBalancer` Service with `cluster.capabilities.loadBalancer == false`. |

`mkJob` runs only: `checkPrivileged`, `checkNamespacedRefs`, `checkContainerResources`, `checkDuplicateNames`, `checkFieldRefs`. Skips `checkDaemonSet`, `checkSelectorSubset`, `checkNamedPorts`.

### `serviceAccount` shorthand

- Set `serviceAccount = self.serviceAccount` on `spec.template.spec` instead of `serviceAccountName = self.serviceAccount.out.name`.
- `_expandServiceAccount` rewrites to `serviceAccountName = sa.out.name`, stamps `_kix.serviceAccountNamespace` so `checkNamespacedRefs` enforces same-namespace. `serviceAccount` key removed from final spec.
- Both forms work; shorthand preferred (enables cross-namespace validation). `serviceAccount = null` drops the field.

### `headlessService` shorthand (StatefulSet)

- Set `headlessService = self.headlessService` on the spec; `_expandHeadlessService` validates it's a `Service` resource in the same namespace, sets `spec.serviceName = svc.name`.
- Uses `svc.name` (plain string), NOT `svc.out.name`. Load-bearing: `spec.serviceName` is a plain K8s name match, not a dependency. `.out.name` creates a store-path DAG edge; if the Service also `requires` the StatefulSet (common back-reference), that closes an evaluation cycle and Nix recurses infinitely.

```nix
serviceName = self.headlessService.name;   # .name, NOT .out.name
```

- Use the shorthand, or set `serviceName = self.headlessService.name` by hand. Never `.out.name` there.

### `rawSelector` (cycle escape hatch)

- Every workload resource carries extra `rawSelector` = the `selector.matchLabels` you passed. Cheap accessor that does NOT force `out` (no full-manifest hash).
- Use from a sibling resource in the same `self` fixpoint when reading `out.selector` would cycle. Classic case (`kix/packages/ingress-nginx/default.nix`): Service selector comes from Deployment, but Deployment also `requires` the Service (`--publish-service`). `self.deployment.out.selector` forces the Deployment manifest -> depends on Service -> depends back on Deployment.

```nix
# Service spec
selector = self.deployment.rawSelector;   # not .out.selector -> no cycle
```

- Default/preferred surface is still `out.selector` (carries store-path context that `kix.service.fromWorkload` consumes for ordering). Use `rawSelector` only to break a real cycle.
- `rawSelector` is a plain attrset with no store-path context, so the consuming Service trips the `selectorCoherence` scorecard rule (manifest level, severity `warning`, `kix/lib/rules/architecture.nix`), which fires on any Service whose selector has no context on any value. Intended warning surface. Keep workload+Service coupled through `rawSelector` (derived from the spec), not a hand-rolled label literal (see `03-advanced.md#scorecard--rules`).

### `scope.mkOptional`

- `mkOptional cond builder` gates a resource on `cond`, returns `null` when false. `null` resources dropped by `collectTypedAttrs`, tolerated by `root.requires`.

```nix
nodeAgent = scope.mkOptional config.nodeAgent.enabled (_: scope.mkDaemonSet { ... });
```

- `builder` may be a thunk (function of one ignored arg) or a plain value. Prefer the thunk: when `cond` is false the builder is never evaluated, so side effects (context stamping, CNP generation) stay dormant.

### `scope.mkWebhookService`

Builds an admission-webhook Service + its `Validating`/`MutatingWebhookConfiguration` in one call. Full reference (hook/rule fields, defaults, `caBundle`) in 03-advanced.md#secrets-crds-rbac. Pass `selector = self.<workload>.rawSelector` to avoid hashing the workload manifest.

### Gotchas

- `serviceName` / `spec.serviceName` must use `.name`, not `.out.name`. `.out.name` + back-referencing Service = infinite recursion. `headlessService` shorthand does this correctly.
- Selector mismatch throws, does not warn. With your own `template.metadata.labels`, every selector key must be present with equal value. When in doubt, omit template labels and let the constructor copy the selector.
- `spec.selector.matchLabels` mandatory for Deployment/StatefulSet/DaemonSet. Jobs may omit it (then template labels required).
- Bare-string refs throw. Secret/ConfigMap/PVC/SA name as plain literal (no Nix context) fails `checkNamespacedRefs`. Use `resource.out.name` or `kix.untrackedRef` for external resources.
- Cross-namespace refs throw. Mounts, env refs, SA references must be same-namespace; mirror or reflect instead.
- Capability gates depend on the cluster. `LoadBalancer` Services, DaemonSets, privileged/`hostNetwork`/`hostPath`/`hostPID` pods throw when the matching `cluster.capabilities.*` is `false`. Pass silently when capabilities unset (e.g. tests).
- Per-workload CNPs emitted by the constructor, not your `build`. With network policy enabled, workload gains `requires` edges on generated CNPs and DNS/egress deps automatically (see `03-advanced.md#networking--package-meta`).

## Composition helpers (kix.*)

`kixlib` = pure composition helpers passed as the `kix` arg. No scope dependency; operate on plain attrsets / resource objects, produce *pre-seal* attrsets. Source: `kix/lib/compose.nix` (`rec { ... }` from `{ lib }`). Pipe results into `scope.mkResource` / `scope.mkDeployment` (see `02-authoring.md#resources-and-the-out-surface`, `02-authoring.md#workloads`).

### Build-list / pipe pattern

- Helpers are transformers + derivers; none seal. Sealing is always the final `|>` step.
- Every intermediate value stays a plain attrset (inspect / merge / override).

```nix
service =
  self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;
```

### Value helpers

| Helper | Returns / behavior |
|---|---|
| `port name containerPort` | `{ name; containerPort; protocol = "TCP"; }`. Override protocol by merging. |
| `mkEnvVars attrs` | `{ KEY = "value"; }` -> `[{ name; value; }]`. Null values filtered (works with `lib.optionalAttrs` / conditional `null`). |
| `mkEnv attrs raw` | Same as `mkEnvVars`, then appends list of raw K8s env entries (e.g. `valueFrom.secretKeyRef`). Canonical way to mix named values + secret refs. |
| `parseQuantity resource q` | Kubernetes quantity -> millicores when `resource` is `"cpu"`, bytes otherwise, rounded down, as an integer; `null` when `q` is not a quantity; throws above the signed 64-bit range. Same grammar as `kix.types.quantity`. Strips Nix string context first (works on `out.*` DAG-context values). |
| `mergeEnv { who; owned ? [ ]; defaults ? { }; } env` | `defaults // env // <every owned group's vars>`, for `mkEnvVars`. `owned` is a list of `{ vars ? { }; names ? [ ]; from; fix; }`; a key in `env` that a group owns throws, also when its value is null. `defaults` may be overridden or removed with null. |
| `guardArgs { who; option ? "extraArgs"; owned; } args` | Returns `args` unless one sets an owned flag (`owned` maps flag -> reason and fix); `--flag` and `--flag=value` both match, and a one-letter flag also matches `-c<value>`. |
| `checkSecretKeys { who; arg; dep; keys ? [ ]; anyOf ? null; }` | Returns `dep` once it declares every key the package reads; read the secret through the result so the check runs before any `keyRef`. |

```nix
ports = [ (kix.port "http" 2283) ]
++ lib.optionals hasMetrics [ (kix.port "metrics-api" 8081) ];
# UDP: (kix.port "dns" 53) // { protocol = "UDP"; }
```

```nix
env = kix.mkEnvVars (kix.mergeEnv {
  inherit who;
  defaults = lib.optionalAttrs hasMetrics { IMMICH_TELEMETRY_INCLUDE = "all"; };
  owned = [
    {
      vars = {
        DB_HOSTNAME = database.out.host;
        DB_DATABASE_NAME = database.out.database;
        DB_USERNAME = database.out.credentials.out.keyRef "username";
        DB_PASSWORD = database.out.credentials.out.keyRef "password";
      };
      names = [ "DB_URL" ];
      from = "the database dependency";
      fix = "Wire a different database through deps.database.";
    }
  ];
} config.env);
```

A key in `env` that a group owns throws, also when its value is null; `defaults` may be overridden or removed with null.

```nix
storage.warnings =
  dep:
  let bytes = kix.parseQuantity "memory" (dep.out.size or "0");
  in lib.optional (bytes != null && bytes < 50 * 1024 * 1024 * 1024)
    "library storage is ${dep.out.size or "unknown"} - recommended minimum is 50Gi";
```

### `service.fromWorkload config workload`

Takes config attrset, then a workload *resource* (sealed, has `out` + `rawManifest`). Auto-derives:

- `spec.selector` from `workload.out.selector`
- `spec.ports` from container ports via `service.extractPorts`, unless you pass `ports`
- `outputs.port` from first port (so `ingress.fromService` can read `out.port`)

Consumed keys: `name`, `type` (default `"ClusterIP"`), `ports`. Everything else (`outputs`, `requires`, `labels`, `annotations`, `extra`, ...) passes through to `mkResource`.

```nix
service =
  self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;
```

- `extractPorts`: reads `spec.template.spec.containers[*].ports`, maps each to `{ port = containerPort; protocol; }`, adds `name` + `targetPort = name` when container port is named. Always consistent with container ports.

### `ingress.fromService` / `httpRoute.fromService`

Both: take config attrset, then a Service *resource*. Backend service name from `svc.out.name`, backend port from `svc.out.port` (override with `port`). If neither `port` nor `svc.out.port` available -> `throw` (specify `port`).

`ingress.fromService` consumed keys: `name`, `host`, `path` (default `"/"`), `pathType` (default `"Prefix"`), `port`, `className`, `tls` (default `[ ]`). `className` + `tls` emitted only when non-default. Passthrough: `annotations`, `labels`, `requires`, `extra`, etc.

```nix
ingress =
  self.service
  |> kix.ingress.fromService { name = "my-ing"; host = "example.com"; }
  |> clusterIssuer.out.withCert
  |> scope.mkResource;
```

`httpRoute.fromService` (Gateway API, `gateway.networking.k8s.io/v1`) consumed keys: `name`, `host`, `parentRef` (`{ name; namespace?; }`, the Gateway ref), `path` (default `"/"`), `pathType` (default `"PathPrefix"`), `port`. Note: Gateway `pathType` default is `PathPrefix`; Ingress is `Prefix`.

```nix
routeCrd = scope.mkCRDRef {
  group = "gateway.networking.k8s.io"; kind = "HTTPRoute"; plural = "httproutes"; version = "v1";
};
route =
  self.service
  |> kix.httpRoute.fromService {
       name = "my-route";
       host = "example.com";
       parentRef = gateway.out.gatewayRef;
     }
  |> scope.mkCR self.routeCrd;
```

- An HTTPRoute is a custom resource, so it is built with `scope.mkCR` from a CRD ref; the route then depends on the Gateway API CRD, and `kix deploy` waits for it (cross-resource check 21 refuses a custom resource with no such dependency).

- In app packages, prefer `kix.expose` (below) - it picks the right one by present infra dep.

### Mount helpers `mount.*`

`kix.mount.{pvc,configMap,secret,emptyDir,hostPath}` = typed volume constructors. Each returns one *mount object* `{ _type = "kix-mount"; name; mountPath; source; ... }`, NOT a `{ volume, volumeMount }` pair (split happens in `withMounts`). `name` auto-derives from resource `out.name` (context stripped) unless passed.

- Resource-backed (`pvc`, `configMap`, `secret`): take resource first, then options. **Return `null` if resource is `null`** -> optional resource flows through as null mount, filtered by `withMounts`.

```nix
libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
configMount  = kix.mount.configMap self.configMap { mountPath = "/config"; }; # null cm -> null
```

| Constructor | Options | Emits / notes |
|---|---|---|
| `pvc resource {...}` | `mountPath, name?, readOnly?, subPath?` | `persistentVolumeClaim.claimName` |
| `configMap resource {...}` | `mountPath, name?, subPath?, items?, defaultMode?` | `items` = list of `{ key, path }`; `defaultMode` int (e.g. `493` = `0755`) |
| `secret resource {...}` | `mountPath, name?, subPath?, items?, defaultMode?` | `secret.secretName` |
| `emptyDir {...}` | `mountPath, name, medium?, sizeLimit?, subPath?` | no resource -> `name` required |
| `hostPath {...}` | `mountPath, name, hostPath, type?, readOnly?, subPath?` | node-local; `type` default `DirectoryOrCreate`. Does not survive node loss; pins workload to node. |

- Namespace markers: each resource-backed mount source carries hidden `_kix.namespace` (from resource home ns `_resourceNs`; `null` for cluster-scoped). `scope.nix` `checkNamespacedRefs` enforces same-namespace mount at build time; `stripKixMeta` removes before serialization. Not set manually.

### `withMounts` / `withMountsOn`

- `withMounts mounts attrs`: injects mount list into pre-seal pod attrset. Appends `volumes` to `spec.template.spec.volumes`, `volumeMounts` to the container. Nulls filtered first. Targets the **single** container; on multi-container pod -> `throw` (use `withMountsOn`).
- `withMountsOn containerName mounts attrs`: targets container matching `containerName`.

```nix
deployment =
  { name = "${name}-server"; spec = { ... }; }
  |> kix.withMounts [ self.libraryMount self.configMount ]  # null filtered
  |> scope.mkDeployment;

# multi-container:
# |> kix.withMountsOn "registry" [ self.dataMount ]
```

- Volume entry built as `{ inherit (m) name; } // m.source` (source's `persistentVolumeClaim`/`configMap`/`secret` lands at top level). VolumeMount carries `name`, `mountPath`, optional `subPath`/`readOnly`.

#### Gotcha: duplicate volume names throw

- Names auto-derive from `out.name`; two resources with same derived name (or colliding with existing `volumes`) -> eval error `kix.withMounts: duplicate volume name(s) [...]`. Fix: pass explicit `name = "..."` to one `kix.mount.*`, or drop the dup. Without guard the API server silently drops one volume.

### `expose` - DI-driven Ingress / HTTPRoute build entry

Returns a **build-entry function** for the package `build` *list*. Declares own optional DI deps (`gateway`, `ingressNginx`, `clusterIssuer`) via function args -> auto-discovered (see `02-authoring.md#dependency-injection`). Picks resource type by present dep:

- `gateway` present (`out.gatewayRef`) -> HTTPRoute (Gateway API); TLS is Gateway's concern.
- `ingressNginx` present -> Ingress (legacy); TLS via `clusterIssuer.out.withCert` when `clusterIssuer` dep present.
- neither -> part is `null` (no exposure).
- **both** -> `throw` (wire exactly one in cluster definition).

Config args (first attrset): `service` (part name in `self`, single-backend), `paths` (list of `{ path, pathType?, service, port? }`, multi-backend, mutually exclusive with `service`), `partName` (default `"route"`, the Ingress or HTTPRoute part), `exposurePart` (default `"exposure"`, the record part), `defaultAnnotations` (Ingress mode), `port` (override auto-derived). One of `service`/`paths` required, mutually exclusive (both `throw`). A package that calls `kix.expose` twice sets `partName` and `exposurePart` on the second call; two build entries that return the same part name are an evaluation error.

```nix
build = [
  ({ self, config, ... }: {
    # ... deployment, service, root = self.service ...
  })
  (kix.expose {
    service = "service";
    defaultAnnotations = {
      "nginx.ingress.kubernetes.io/proxy-body-size" = "0";
    };
  })
];
```

- Host: from `config.ingress.host`, else `"${name}.${clusterConfig.cluster.domain}"`; if neither, no exposure. Annotations merge `defaultAnnotations // config.ingress.annotations`. Use `options.ingress = kix.options.ingress;` for standard `ingress.host` + `ingress.annotations` (see `01-fundamentals.md#options--config`).

#### TLS (Ingress mode)

- Ingress mode enables TLS when a `clusterIssuer` dependency is resolved: the issuer's `out.withCert` annotates the Ingress, and Kix adds a TLS entry for the host with the Secret `<instance>-tls` in the instance's namespace.
- Gateway mode leaves TLS to the Gateway listener. The HTTPRoute is built with `scope.mkCR` from a CRD ref part `<partName>Crd` (`routeCrd`), so the deploy waits for the Gateway API CRDs.

#### The public URL (`self.exposure`)

`self.exposure` is a record of the route the call rendered: `{ via; host; scheme; url; }`. `url` is `<scheme>://<host>`, with `:<port>` when the port is not the scheme's default, and null when no route is rendered or the scheme is unknown. In Ingress mode the scheme is `https` when a `clusterIssuer` is wired. In Gateway mode it comes from the listener the HTTPRoute attaches to (protocol, `hostname`, `allowedRoutes.namespaces.from`); no matching listener fails evaluation, and a gateway without `out.listeners` (a `kix.mkImport`) gives `url = null`. Read `self.exposure.url` (vaultwarden's `DOMAIN`, harbor's `EXT_ENDPOINT`); never re-derive it from `ingress.host`.

### `monitor` - DI-driven ServiceMonitor / PrometheusRule build entry

Returns build-entry function (append to `build` list). Declares `prometheus` as optional DI dep. Creates ServiceMonitor (+ optional PrometheusRule) **only when `prometheus` injected and metrics enabled** (`config.metrics.enabled`, default true). Builders come from the dep: `prometheus.out.mkServiceMonitor scope { ... }`, `prometheus.out.mkPrometheusRule scope { ... }` (no local CRDRef).

Config args:

- `service` - part name to monitor
- `port` - default `"metrics"`; string -> `port`, int -> `targetPort`
- `path` - default `"/metrics"`
- `scheme` - default `"http"`; `tlsConfig` - default none. Both set the primary endpoint's.
- `alerts` - attrset `alertName -> { expr, for?, severity?, description?, summary?, runbook_url?, labels?, annotations? }`; `severity` default `"warning"`
- `extraEndpoints` (each merged over `{ scheme = "http"; path = "/metrics"; }` and the instance's `metrics.interval`), `extraLabels`
- scrape interval from `config.metrics.interval`

```nix
build = [
  ({ self, ... }: { ... })
  (kix.monitor {
    service = "service";
    port = "metrics";
    alerts.highErrorRate = {
      expr = ''rate(http_requests_total{status=~"5.."}[5m]) > 0.05'';
      "for" = "5m";
      severity = "warning";
      description = "Error rate above 5%";
    };
  })
];
```

- `options.metrics = kix.options.monitor;` -> standard `metrics.enabled` + `metrics.interval`. Selector from `self.${service}.out.selector`; `namespaceSelector` pinned to `scope.namespaceName`.

#### Hand-roll instead when

- `kix.monitor` takes `extraEndpoints` for a Service with several metrics ports (immich: `metrics-api` and `metrics-ms`); each extra endpoint gets `scheme = "http"`, `path = "/metrics"` and the instance's `metrics.interval`. Call `prometheus.out.mkServiceMonitor` directly only for a selector or endpoint shape `kix.monitor` does not build.

### Gotchas

- Forgetting final `|> scope.mkResource` / `|> scope.mkDeployment`. `fromX` / `withMounts` return plain attrsets; nothing registered in DAG until sealed.
- Passing the workload/service *attrset* instead of sealed *resource* to `fromWorkload` / `fromService`. They read `out.*` + `rawManifest` (post-seal only). Pipe `self.deployment` / `self.service`.
- Expecting `kix.mount.*` to return `{ volume, volumeMount }`. It returns one mount object; `withMounts` splits.
- Wiring both `gateway` and `ingressNginx` to the same instance - `expose` fails fast; choose one.

## Dependency injection

Deps = named args of the `build` function, discovered by introspection, resolved against the cluster with DNS-like rules. See `02-authoring.md#resources-and-the-out-surface` for the `out` surface deps consume; `03-advanced.md#overrides` for cluster-side `deps` override knobs.

### Deps are build-function args

Deps = the `build` function's args minus system args. From `valkey/default.nix`:

```nix
build = [
  (
    {
      self,
      config,
      valkeyPassword,
      storageClasses ? null,
      prometheus ? null,
      ...
    }:
    ...
  )
];
```

`discoverBuildDeps` (`kix/lib/eval/resolve.nix`) reads `builtins.functionArgs build`, strips system arg names, treats the rest as deps:

```nix
systemBuildArgNames = [ "self" "config" "clusterConfig" "scope" "lib" "kix" "deps" ];
```

- `valkey` deps: `valkeyPassword` (required), `storageClasses` and `prometheus` (optional).
- No separate dependency list. Arg name = resolution key.

### Required vs optional

Encoded by the Nix default, not a flag:

- No default (`postgres`) = **required**. Unresolved -> evaluation throws.
- `? null` default (`postgres ? null`) = **optional**. Unresolved -> Nix fills `null`; package branches on presence.

`discoverBuildDeps` returns `{ <name> = { optional = <hasDefault>; }; }`. Optional usage gates on presence:

```nix
hasIngress = ingressNginx != null && config.ingress.hosts != [ ];
hasTls = hasIngress && clusterIssuer != null;

depEnv =
  { }
  // lib.optionalAttrs (postgres != null) { DATABASE_HOST = postgres.out.fqdn; }
  // lib.optionalAttrs (valkey != null) { VALKEY_HOST = valkey.out.fqdn; };
```

`firezone/default.nix` declares `postgres` with no default = hard requirement; cluster without resolvable `postgres` fails to evaluate.

### DNS-like resolution

`resolveArg` (`kix/lib/eval/resolve.nix`) maps dep arg name -> instance via priority ladder. Requester namespace matters; prefers local instances (like DNS local search domain).

1. **Explicit override** (`deps.<argName> = ...` on the instance, see `03-advanced.md#overrides`) -> returned directly (`direct = true`).
2. Same namespace, exactly one match -> use it.
3. Same namespace, multiple matches -> throw `dependency '<arg>' matches multiple instances in namespace '<ns>'`.
4. No same-ns match, exactly one cluster-wide match -> use it (cross-namespace).
5. Multiple cluster-wide matches -> throw `dependency '<arg>' matches instances in multiple namespaces`.
6. No match, dep has Nix default -> `{ found = false; }`; Nix supplies default (`null` for optionals).
7. No match, no default -> throw `dependency '<arg>' was not found for namespace '<ns>'`.

Before the ladder, candidates in another namespace whose package declares `meta.scope = "namespace"` are dropped, and managed instances shadow imports on a shared key. Every error starts with the requesting instance, `<ns>/<inst>: `, marked `(auto-instantiated)` when the shelf created it.

Candidate set = **resolution index**, built by `buildResolutionIndex` from static `_meta` (no inner fixpoint forced). Each instance contributes its name **and aliases** as keys:

```nix
keys = lib.unique ([ instName ] ++ (meta.aliases or [ ]));
```

Postgres instance `app-db` with `aliases = [ "postgres" ]` is reachable by a `postgres ? null` arg. Aliases are first-class resolution keys -> generic packages (arg `postgres`) bind to specifically-named instances.

#### Managed instances shadow imports

Shared key: managed wins.

```nix
managed = builtins.filter (c: !(c.meta.isImport or false)) candidates;
effectiveCandidates = if managed != [ ] then managed else candidates;
```

Flavor fallback imports (DNS, storage, ingress) are auto-shadowed once the cluster installs its own package on the same key.

### The combined `deps` arg

`deps` arg = whole attrset of resolved deps keyed by arg name. From `instance.nix`:

```nix
extra =
  ... // lib.optionalAttrs (args ? deps) { deps = resolvedDeps; };
depArgs = lib.intersectAttrs args resolvedDeps;
fn (base // extra // depArgs);
```

- `resolvedDeps` only contains deps that resolved (`null` optionals absent).
- Use named args normally; `deps` for iterating an unknown set.

### Two-phase calling

Two phases so deps can influence each other before any resource is built.

**Phase 1 - introspect (no fixpoint).** `normalizePackage` / `callPackagePhase1` -> `{ meta?, options?, deps?, build, ... }`. Function package called with **system args only** (`scope`, `lib`, `kix` if requested), never deps:

```nix
package ({ inherit scope lib; } // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; });
```

- Inline attrset package (has `build` key) and `kix-import` returned as-is.
- `discoverBuildDeps raw.build` learns dep names without evaluating `build`.
- Consumer's `deps.<name>.config` enrichment collected and injected into target dep's config before that dep is evaluated (see "Dep config injection").

**Phase 2 - bind (inside fixpoint).** `resolveDeclaredDeps` -> concrete instance handles (looked up from `allInstances` via resolution coordinates); build runs inside `lib.fix`:

```nix
parts = lib.fix (self:
  builtins.foldl' (acc: fn: acc // (callBuildFn self fn)) { } rawBuildEntries);
```

- `callBuildFn` passes `{ self, config, clusterConfig }` plus, by arg introspection, any of `scope`, `lib`, `kix`, `deps`, and the named resolved deps the entry requests.
- `self` = fixpoint of all parts -> a resource references siblings (`self.backendService.out.name`) and deps alike.

### `build` as a list: per-entry discovery, merged

`build` = single function or **list** of functions (or paths to functions). Each entry introspected independently; dep sets **unioned**. From `discoverBuildDeps`:

```nix
allBuildArgs = builtins.foldl' (acc: fn:
  let
    fnArgs = builtins.functionArgs fn;
    overrides = lib.mapAttrs (n: v: acc.${n} && v) (lib.intersectAttrs acc fnArgs);
  in acc // fnArgs // overrides) { } buildEntries;
```

- Optionality AND-ed across entries: dep optional only if **both** give a default (required wins).
- Each entry receives only deps it names (`lib.intersectAttrs args resolvedDeps`); returned attrsets `//`-merged into one `self`.

How composition helpers attach infra deps without the app author touching them (see `02-authoring.md#composition-helpers-kix`). `firezone/default.nix`:

```nix
build = [
  ({ self, config, clusterConfig, postgres, scope, kix, ... }: { ... app resources ... })
  (kix.expose { service = "service"; })
];
```

- `kix.expose` returns an entry declaring `gateway ? null`, `ingressNginx ? null`, `clusterIssuer ? null`.
- `kix.monitor` returns one declaring `prometheus ? null`.
- Union -> effective dep set grows by whatever helpers need; first entry never lists ingress/prometheus.

### `deps.<name>` enrichment: assertions, warnings, config

Per-dep metadata, co-located in a top-level `deps` attrset. Separate from build args (which still define the dep set); only adds diagnostics + config injection. From `immich/default.nix`:

```nix
let
  requiredExtensions = [ { name = "vchord"; version = "0.5.3"; } "uuid-ossp" "cube" "earthdistance" "unaccent" "pg_trgm" ];
  extensionName = e: if builtins.isString e then e else e.name;
in
deps = {
  database.config.extensions = requiredExtensions;
  database.assertions = dep:
    let
      published = map extensionName (dep.out.extensions or [ ]);
      missing = builtins.filter (e: !(builtins.elem e published)) (map extensionName requiredExtensions);
    in
    lib.optional (dep.out ? extensions && missing != [ ]) {
      assertion = false;
      message = "the database needs the postgres extensions ...; missing: ....";
    };
  storage.warnings = dep:
    lib.optional (kix.parseQuantity "memory" (dep.out.size or "0") < 50 * 1024 * 1024 * 1024)
      "library storage is ${dep.out.size or "unknown"}, recommended minimum is 50Gi ...";
};
```

One let-binding feeds both the injected config and the check. An assertion message starts with the constraint; the lib prefixes the instance.

- `.assertions` / `.warnings` = functions of the resolved dep instance (`dep`, with `out`), evaluated against the bound dep. Diagnostics attributed to the consumer.

#### Dep config injection

`deps.<name>.config` pushes config **into** the resolved dep.

- Phase 1: `buildConfigInjections` inverts "consumer X wants config on dep Y" -> "target Y receives injections from [X...]".
- `evaluateInstanceConfig` merges injection modules into target's `evalModules` at instance-config priority.
- Immich forwards needed postgres extensions into its `database` dep -> auto-instantiating immich pulls a fully-configured database, no cluster wiring.
- `config` = static attrset or function `consumerConfig: { ... }`, resolved lazily (consumer forwards parts of its own evaluated config into a dep).
- Injection into a `mkLocked` field = build-time error with source attribution (see `03-advanced.md#overrides`).

### Auto-instantiation

Required dep with no explicit instance -> created automatically. `auto.nix` (`computeAutoInstances`) seeds from required deps of mandatory instances, walks transitive required deps with `builtins.genericClosure`. Per unmet dep name, in order:

- **activated optionals** - instance the cluster declared `optional = true`; reaching it as a dep flips it on (recorded in `activatedOptionals`).
- **`availablePackages`** - registry keyed by name/alias; match instantiated in `avPkg.namespace`, else `autoNamespace`, else requester's namespace, with default config and `_autoInstantiated = true`.
- neither - left unresolved -> `resolveArg` errors later with missing-dep message.

- Auto-instances annotated `kix.run/auto-instantiated = "true"` (optionals: `kix.run/optional-activated`).
- `[kix] auto-instantiated: ...` trace emitted.
- Only **required** deps drive auto-instantiation; unresolved optionals become `null`.

### `mkImport`: unmanaged resources as deps

Deps that already exist (cloud DNS, managed ingress, platform CoreDNS). `mkImport` (`kix/lib/eval/import.nix`) creates a `kix-import` marker usable as an instance's `package`. Participates in resolution index like any instance (name + aliases); emits only a marker PackageInstance, no real manifests. From `kix/lib/flavors/kind.nix`:

```nix
instances.kube-system.platform-dns = {
  package = kix.mkImport {
    kind = "Deployment";
    apiVersion = "apps/v1";
    out = { name = "coredns"; fqdn = "kube-dns.kube-system.svc.${config.clusterDomain}"; };
  };
  aliases = [ "dns" ];
};
```

`mkImport` takes `{ from ? null, out ? {}, kind ? null, apiVersion ? null, roles ? [ ], crds ? [ ] }`:

- `out` only - `out` surface supplied verbatim (example above).
- `crds` - a list of `scope.mkCRDRef` argument sets without `installedBy`; each becomes `out.crds.<Kind>` and a CRD marker in the import's namespace.
- `from = <package fn>` - package's `build` runs under `mkImportScope`, swapping `mkResource`/`mkServiceRef`/`mkSecretRef` for ref constructors that compute `out` without store paths or manifests. Only `out`-relevant code forced (laziness). Deps **not** resolved in import mode: any dep access hits a proxy throwing `imports run without dependency resolution`. Use a raw `out` override, or a mixed import (`from` + `out` for dep-needing fields).

Managed instances shadow imports on shared keys -> a flavor's fallback `platform-dns` import is auto-replaced when the cluster installs its own DNS package. An optional import becomes active, and its marker is emitted, when a declared dependency of an active managed instance resolves to it; give it `kind`, `apiVersion`, and `out.name` when the deploy should wait for the object.

### Infrastructure DI patterns

`out` shape determines consumer usage. Edge created automatically: referencing `dep.out.<x>` carries the dep's string context into the consumer's manifest -> kix orders the deploy with no explicit `requires` (see `01-fundamentals.md#overview--mental-model`, "store-path = DAG edge").

| Pattern | What `out` carries | Consumer usage | Example |
| --- | --- | --- | --- |
| Plain value | string/attrset | read directly | `postgres.out.fqdn`, `ingressNginx.out.ingressClassName` |
| Transformer | function `manifest -> manifest` | pipe a resource through it | `clusterIssuer.out.withCert` (`... \|> (if hasTls then clusterIssuer.out.withCert else lib.id)`) |
| Builder | function constructing a resource | call with scope/args | `prometheus.out.mkServiceMonitor scope { ... }` (used by `kix.monitor`) |

### Gotchas

- **Arg name is the contract.** Renaming a build arg renames the dep key. `postgres ? null` resolves against instances named/aliased `postgres`; no separate mapping.
- **Ambiguity throws, does not pick.** Two same-ns matches (or two cluster-wide with none local) = hard error. Disambiguate with alias, namespace, or explicit `deps.<name>` override.
- **Missing required dep is fatal.** No default + no candidate + no auto-instantiation candidate -> throws `no '<argName>' found in cluster`. Make optional (`? null`) only if the package truly handles absence.
- **Phase 1 never sees deps.** Top-level function-package code (outside `build`) runs with system args only. Dep-needing code must live inside a `build` entry.
- **Cross-namespace restricted by `meta.scope`.** Automatic resolution never picks an instance that declares `meta.scope = "namespace"` for a consumer in another namespace; an explicit `deps.<x> = ref.<ns>.<instance>` to one throws the cross-namespace error (`instance.nix` `_crossNsCheck`). See `03-advanced.md#networking--package-meta`.
- **Optionality AND-ed across list entries.** One entry required + another optional -> required overall. Give every entry naming the dep the same default for optional.
- **Imports can't touch deps.** `mkImport { from = ...; }` reading a dep throws. Provide the dep-derived field via an `out` override.
