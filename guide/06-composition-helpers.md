# Composition helpers (kix.*)

This chapter covers `kixlib`, the pure composition helpers that every package receives as the `kix` argument. These functions have no scope dependency: they operate on plain attrsets and resource objects, producing *pre-seal* attrsets that you pipe into `scope.mkResource` / `scope.mkDeployment` (see 04-resources-and-out.md and 05-workloads.md). They live in `kix/lib/compose.nix` as a single `rec { ... }` block built from `{ lib }`. Coverage here: the small value helpers (`port`, `mkEnvVars`, `mkEnv`, `parseGi`), the `fromX` resource derivers (`service.fromWorkload`, `ingress.fromService`, `httpRoute.fromService`), the typed `mount.*` constructors with `withMounts` / `withMountsOn`, and the two DI-driven build entries `expose` and `monitor`.

## Mental model: pre-seal attrsets and pipes

A kix package builds resources by piping a plain attrset through transformer functions and finally into a sealing function (`scope.mkResource`, `scope.mkDeployment`, ...). The `kix.*` helpers are the transformers and the derivers. None of them seal; sealing is always your last `|>` step. This keeps every intermediate value a plain attrset you can inspect, merge, or override.

```nix
service =
  self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;
```

## Value helpers

### `port name containerPort`

Shorthand for a container port entry. Returns `{ name; containerPort; protocol = "TCP"; }`. Override protocol by merging.

```nix
ports = [
  (kix.port "http" 2283)
]
++ lib.optionals config.metrics.enabled [
  (kix.port "metrics-api" 8081)
];
# UDP: (kix.port "dns" 53) // { protocol = "UDP"; }
```

### `mkEnvVars attrs` and `mkEnv attrs raw`

`mkEnvVars` turns `{ KEY = "value"; }` into the K8s `[{ name; value; }]` list. Null values are filtered, so `lib.optionalAttrs` and conditional `null` assignments work naturally for optional env vars. `mkEnv attrs raw` does the same and appends a list of raw K8s env entries (e.g. `valueFrom.secretKeyRef`). This is the canonical way to mix named values with secret references.

```nix
env =
  kix.mkEnv
    {
      DB_HOSTNAME = database.out.host;
      REDIS_HOSTNAME = valkey.out.fqdn;
      # null is dropped, so disabled features just go null:
      IMMICH_MACHINE_LEARNING_URL = mlUrl;
    }
    (
      database.out.credentials.out.mkEnv {
        DB_USERNAME = "username";
        DB_PASSWORD = "password";
      }
    );
```

### `parseGi s`

Parses a K8s quantity string (`Ti`, `Gi`, `Mi` suffixes) to a number of GiB, or `null` for unrecognized formats. It strips Nix string context first, so it works on `out.*` values (which carry DAG context). Used for capacity warnings:

```nix
storage.warnings =
  dep:
  let storageSizeGi = kix.parseGi (dep.out.size or "0");
  in lib.optional (storageSizeGi != null && storageSizeGi < 50)
    "library storage is ${dep.out.size or "unknown"} - recommended minimum is 50Gi";
```

## `service.fromWorkload` - derive a Service from a workload

Takes a config attrset then a workload *resource* (the sealed object, with `out` and `rawManifest`). Auto-derives:

- `spec.selector` from `workload.out.selector`
- `spec.ports` from the workload's container ports (`service.extractPorts`), unless you pass `ports`
- `outputs.port` from the first port (so downstream `ingress.fromService` can read `out.port`)

Consumed keys: `name`, `type` (default `"ClusterIP"`), `ports`. Everything else (`outputs`, `requires`, `labels`, `annotations`, `extra`, ...) passes through to `mkResource`.

```nix
service =
  self.deployment
  |> kix.service.fromWorkload { name = "${name}-server"; }
  |> scope.mkResource;
```

`extractPorts` reads `spec.template.spec.containers[*].ports` and maps each to `{ port = containerPort; protocol; }`, adding `name` + `targetPort = name` when the container port is named. Because it derives from the container ports themselves, auto-extracted ports are always consistent.

## `ingress.fromService` and `httpRoute.fromService`

Both take a config attrset then a Service *resource*. They auto-derive the backend service name from `svc.out.name` and the backend port from `svc.out.port` (override with `port`). If neither `port` nor `svc.out.port` is available, they `throw` asking you to specify `port` explicitly.

`ingress.fromService` consumes `name`, `host`, `path` (default `"/"`), `pathType` (default `"Prefix"`), `port`, `className`, `tls` (default `[ ]`). `className` and `tls` are only emitted when non-default. Passthrough: `annotations`, `labels`, `requires`, `extra`, etc.

```nix
ingress =
  self.service
  |> kix.ingress.fromService { name = "my-ing"; host = "example.com"; }
  |> clusterIssuer.out.withCert
  |> scope.mkResource;
```

`httpRoute.fromService` (Gateway API, `gateway.networking.k8s.io/v1`) consumes `name`, `host`, `parentRef` (`{ name; namespace?; }`, the Gateway reference), `path` (default `"/"`), `pathType` (default `"PathPrefix"`), `port`. Note the different `pathType` default - Gateway uses `PathPrefix`, Ingress uses `Prefix`.

```nix
route =
  self.service
  |> kix.httpRoute.fromService {
       name = "my-route";
       host = "example.com";
       parentRef = gateway.out.gatewayRef;
     }
  |> scope.mkResource;
```

In most app packages you do not call these directly - `kix.expose` (below) picks the right one based on which infra dep is present.

## Mount helpers: `mount.*`

`kix.mount.{pvc,configMap,secret,emptyDir,hostPath}` are typed volume constructors. Each returns a single *mount object* `{ _type = "kix-mount"; name; mountPath; source; ... }`, not a `{ volume, volumeMount }` pair - the volume/volumeMount split happens later inside `withMounts`. The `name` auto-derives from the resource's `out.name` (string context stripped) unless you pass `name`.

Resource-backed constructors (`pvc`, `configMap`, `secret`) take the resource first, then an options attrset, and **return `null` if the resource is `null`**. This is the key ergonomic: an optional resource (e.g. a ConfigMap that only exists when configured) flows straight through as a `null` mount, and `withMounts` filters nulls out.

```nix
# null configMap → configMount is null → silently skipped by withMounts
libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
configMount  = kix.mount.configMap self.configMap { mountPath = "/config"; };
```

Options per constructor:

- `pvc resource { mountPath, name?, readOnly?, subPath? }` - emits `persistentVolumeClaim.claimName`.
- `configMap resource { mountPath, name?, subPath?, items?, defaultMode? }` - `items` is a list of `{ key, path }`; `defaultMode` an integer (e.g. `493` for `0755`).
- `secret resource { mountPath, name?, subPath?, items?, defaultMode? }` - emits `secret.secretName`.
- `emptyDir { mountPath, name, medium?, sizeLimit?, subPath? }` - no resource, so `name` is required.
- `hostPath { mountPath, name, hostPath, type?, readOnly?, subPath? }` - node-local; `type` defaults to `DirectoryOrCreate`. Data does not survive node loss and pins the workload to the node.

### Namespace markers

Every resource-backed mount source carries a hidden `_kix.namespace` marker extracted from the referenced resource's home namespace (`_resourceNs`, which returns `null` for cluster-scoped resources). `scope.nix`'s `checkNamespacedRefs` reads it to enforce that you only mount a ConfigMap/Secret/PVC from the same namespace at build time; `stripKixMeta` removes it before serialization. You do not set this manually.

## Injecting mounts: `withMounts` and `withMountsOn`

`withMounts mounts attrs` injects a list of mount objects into a pre-seal pod attrset: it appends `volumes` to `spec.template.spec.volumes` and `volumeMounts` to the container. Nulls in the list are filtered first. It targets the **single** container; on a multi-container pod it `throw`s, directing you to `withMountsOn`. `withMountsOn containerName mounts attrs` targets the container matching `containerName`.

```nix
deployment =
  { name = "${name}-server"; spec = { ... }; }
  |> kix.withMounts [
       self.libraryMount
       self.configMount   # may be null - filtered
     ]
  |> scope.mkDeployment;

# multi-container:
# |> kix.withMountsOn "registry" [ self.dataMount ]
```

The volume entry is built as `{ inherit (m) name; } // m.source`, so the source's `persistentVolumeClaim` / `configMap` / `secret` keys land at the volume top level. The volumeMount carries `name`, `mountPath`, and optionally `subPath` / `readOnly`.

### Gotcha: duplicate volume names throw

Because names auto-derive from `out.name`, mounting two resources with the same derived name (or colliding with an existing `volumes` entry) is caught at eval with a `kix.withMounts: duplicate volume name(s) [...]` error. Fix by passing an explicit `name = "..."` to one of the `kix.mount.*` calls, or drop the duplicate. Without this guard the API server would silently drop one volume.

## `expose` - DI-driven Ingress / HTTPRoute build entry

`kix.expose` returns a **build-entry function** you append to your package's `build` *list*. It declares its own optional DI deps (`gateway`, `ingressNginx`, `clusterIssuer`) via its function args, so they are discovered automatically (see 07-dependency-injection.md) - the app developer never wires infra deps by hand. It picks the resource type by which dep is present:

- `gateway` present (has `out.gatewayRef`) -> HTTPRoute (Gateway API). TLS is the Gateway's concern.
- `ingressNginx` present -> Ingress (legacy). TLS via `clusterIssuer.out.withCert` when a `clusterIssuer` dep is present.
- neither -> the part evaluates to `null` (no exposure).
- **both** present -> `throw`: wire exactly one in the cluster definition.

Config args (the first attrset): `service` (part name in `self`, single-backend), `paths` (list of `{ path, pathType?, service, port? }`, multi-backend, Ingress only, mutually exclusive with `service`), `partName` (default `"ingress"`, the generated part name), `defaultAnnotations` (Ingress mode), `port` (override auto-derived port), and the TLS-secret selectors `tlsSecretName` / `tlsSecret` / `tlsSecretPart`. One of `service` or `paths` is required, and they are mutually exclusive (both checks `throw`).

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

The host is resolved from `config.ingress.host`, falling back to `"${name}.${clusterConfig.cluster.domain}"`; if neither exists there is no exposure. Annotations merge `defaultAnnotations // config.ingress.annotations`. Use `options.ingress = kix.options.ingress;` to get the standard `ingress.host` + `ingress.annotations` options (see 03-options-and-config.md).

### TLS secret rules (Ingress mode)

The TLS secret name comes from one of three sources, in priority order: `tlsSecret` (a resource, enables a cross-namespace check), `tlsSecretName` (a string - must be DI-tracked, i.e. from `someSecret.out.name` or `kix.untrackedRef "..."`, a raw literal `throw`s), or auto-derived `"${name}-tls"`. `tlsSecretPart` names a part in `self` resolved lazily (avoids forward references). A `tlsSecret` whose namespace differs from the Ingress namespace `throw`s, because ingress controllers only read TLS secrets from the Ingress's own namespace.

## `monitor` - DI-driven ServiceMonitor / PrometheusRule build entry

`kix.monitor` returns a build-entry function (append to the `build` list) that declares `prometheus` as an optional DI dep. It creates a ServiceMonitor (and optional PrometheusRule) **only when `prometheus` is injected and metrics are enabled** (`config.metrics.enabled`, default true). The builders come from the prometheus dep itself: `prometheus.out.mkServiceMonitor scope { ... }` and `prometheus.out.mkPrometheusRule scope { ... }` - no local CRDRef needed.

Config args: `service` (part name to monitor), `port` (default `"metrics"`; a string -> `port`, an int -> `targetPort`), `path` (default `"/metrics"`), `alerts` (attrset `alertName -> { expr, for?, severity?, description?, summary?, runbook_url?, labels?, annotations? }`; `severity` defaults to `"warning"`), `extraEndpoints`, `extraLabels`. Scrape interval comes from `config.metrics.interval`.

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

Use `options.metrics = kix.options.monitor;` for the standard `metrics.enabled` + `metrics.interval` options. The selector is derived from `self.${service}.out.selector` and the `namespaceSelector` is pinned to `scope.namespaceName`.

### When to hand-roll instead

`kix.monitor` covers the common single-service ServiceMonitor. Immich needs two distinct metrics endpoints (`metrics-api`, `metrics-ms`) with a custom selector, so it calls `prometheus.out.mkServiceMonitor scope { ... }` directly inside its main build function instead of using `kix.monitor`. Both paths use the same prometheus-provided builder; `kix.monitor` is just the packaged shortcut.

## Common mistakes

- Forgetting the final `|> scope.mkResource` / `|> scope.mkDeployment`. The `fromX` and `withMounts` helpers return plain attrsets, not sealed resources - nothing is registered in the DAG until you seal.
- Passing the workload/service *attrset* instead of the sealed *resource* to `fromWorkload` / `fromService`. They read `out.*` and `rawManifest`, which only exist post-seal. Pipe `self.deployment` / `self.service` (the sealed parts), not the raw definition.
- Expecting `kix.mount.*` to return a `{ volume, volumeMount }` pair (the older mental model). It returns one mount object; `withMounts` does the splitting.
- Raw-string `tlsSecretName` in `kix.expose` - it must be DI-tracked or wrapped in `kix.untrackedRef`.
- Wiring both `gateway` and `ingressNginx` to the same instance - `expose` fails fast; choose one in the cluster definition.
