---
name: kix-migration
description: Guide for migrating Kubernetes services into kix packages. Use this skill when creating new kix packages, migrating services from Ansible/Helm to kix, writing cluster definitions, or debugging kix-diff output. Also use when the user asks about kix APIs, package structure, or how to use kix functions like mkResource, mkEnv, mergeFragments, etc.
---

# kix Migration Guide

> This is a living document. Update it as we learn new patterns during migrations.
> **Before modifying this document, ask the user for confirmation using the AskUserQuestion tool.** Do not silently update it.

## Source Material

When creating a kix package, the primary sources are:

1. **Existing config management** — often Ansible roles in the Lithus monorepo, but could also be Helm charts, raw manifests, or Terraform. These contain the K8s manifests, config defaults, and deployment logic. Read these first to understand what should exist.
2. **Cluster dump** — what's actually running. May have drifted from the source config.
3. **Upstream docs / charts** — for understanding what fields mean and what the defaults are.

If migrating from Ansible, the Lithus monorepo is available on disk (ask the user for the path if you don't know it). The typical mapping is:
- Ansible role → kix package (`packages/<name>/default.nix`)
- Ansible group_vars / host_vars → cluster definition overrides (`clusters/<name>.nix`)
- Ansible `templates/*.yaml.j2` → `scope.mkResource { ... }` calls

When translating, read the source config first to understand intent, then check the cluster dump to see what's actually deployed. Where they disagree, match the cluster dump (it's what's running) and note the discrepancy.

**Do not blindly transliterate.** Ansible, Helm, and kix have fundamentally different models. Patterns that make sense in the source may be wrong in kix:

- **Helm's release-name prefixing** — Helm prepends the release name to everything. kix uses `scope.instanceName` and explicit naming. Don't cargo-cult the prefix pattern.
- **Ansible's imperative ordering** — Ansible tasks run in order. kix tracks dependencies via store-path references (`"${self.x}"`). You don't need to think about ordering — just reference what you depend on.
- **Helm's values.yaml layering** — Helm has a complex values merge hierarchy. kix has `scope.defaults` (one level) with cluster definition overrides. Keep it flat.
- **Ansible's `when:` conditionals** — Use `lib.optionalAttrs` / `lib.optional` for conditional resources, or `if/then/else` with `null` for optional parts of the attrset.
- **Helm's template helpers (`_helpers.tpl`)** — Use `let` bindings in Nix. Define shared values (labels, selectors, names) once in the `let` block and reference them.
- **Multiple instances of the same service** — Don't duplicate package code. Write one package with config, instantiate it multiple times in the cluster definition with different configs. Use `kix.mkEnv` when the pattern is environment-based (prod/stage/demo).
- **Ansible's `with_items` / `loop`** — Use `lib.mapAttrs` or `map` to generate resources from a config attrset (see `packages/storage-classes/` for an example).

Take time to understand what kix gives you before implementing. The right approach in kix is often simpler than a direct translation.

## Workflow

```
1. Read the source config        →  understand what resources are needed
2. Ensure a cluster dump exists  →  cluster-dump/
3. Write the kix package         →  packages/<name>/default.nix
4. Wire into cluster definition  →  clusters/<name>.nix
5. Build + diff                  →  identify gaps
6. Iterate until diff is clean
```

### 1. Cluster dump

A cluster dump must exist at `cluster-dump/` before diffing. If one isn't already present, ask the user to create it — do not assume you have cluster access. The user can run:

```bash
./scripts/kix-dump.py --all [--context <context>] cluster-dump/
```

This produces `cluster-dump/{namespace}/{name}-{kind}.yaml` with server-side fields stripped. Secret data is removed. Ephemeral resources (pods, replicasets, jobs, events, etc.) are excluded automatically.

### 2. Build + Diff

```bash
nix build .#cluster-<name> --extra-experimental-features pipe-operators
./scripts/kix-diff.py ./result ./cluster-dump/
```

The diff report shows: identical, modified (with JSON-path diffs), kix-only, cluster-only, and probable renames.

### 3. Iterate

Focus on the **Modified** section. Each entry shows exactly which fields differ and where. Common patterns:

- **Config values differ** (image tags, replica counts, resource limits) → update `scope.defaults` or cluster config overrides
- **Naming mismatch** → adjust resource names in the package to match what's deployed
- **Extra labels/annotations on cluster side** → usually harmless (operator-injected), ignore via `--ignore-path`
- **Missing fields in kix** → add them to the package

## Package Anatomy

Every package is a function `{ scope, lib, kix, ...deps }: ...` that returns `{ meta?, options, build }`.

```nix
{ scope, lib, kix, postgres, storage, ingressNginx ? null, clusterIssuer ? null }:
let
  name = scope.instanceName;
in
{
  # Optional: package metadata for lifecycle and scoping rules
  meta = {
    lifecycle = "stateless";  # "stateless" (default) | "stateful"
    scope = "cluster";        # "cluster" (default) | "namespace"
    description = "My package";
    maintainer = "team-name";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = { repository = "myapp/server"; tag = "v1.0.0"; pullPolicy = "IfNotPresent"; };
    };
    replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
    env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
    ingress = lib.mkOption {
      type = lib.types.anything;
      default = { enabled = false; host = ""; };
    };
  };

  build = { self, config, clusterConfig }:
  let
    # Shared values in let block
    healthCheck = { httpGet = { path = "/health"; port = "http"; }; periodSeconds = 10; };
  in
  {
    # --- Mounts (declare separately, inject via withMounts) ---
    dataMount = kix.mount.pvc storage { mountPath = "/data"; };

    # --- Workloads (pipe-friendly composition) ---
    deployment =
      {
        name = "${name}-server";
        spec = {
          replicas = config.replicaCount;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [{
            name = "server";
            image = "${config.image.repository}:${config.image.tag}";
            env = kix.mkEnvVars ({
              DB_HOST = postgres.out.fqdn;
              DB_PORT = postgres.out.port;
            } // config.env);
            ports = [ (kix.port "http" 8080) ];
            livenessProbe = healthCheck;
            readinessProbe = healthCheck;
          }];
        };
      }
      |> kix.withMounts [ self.dataMount ]
      |> scope.mkDeployment;

    # --- Services (auto-derive from workload) ---
    service = self.deployment
      |> kix.service.fromWorkload { name = "${name}-server"; }
      |> scope.mkResource;

    # --- Ingress (optional, pipe-friendly) ---
    ingress =
      if config.ingress.enabled then
        self.service
        |> kix.ingress.fromService {
          inherit name;
          host = config.ingress.host;
          className = if ingressNginx != null then ingressNginx.out.ingressClassName else "public";
        }
        |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
        |> scope.mkResource
      else null;

    # root — entry point. Resources reachable via self.* refs are auto-tracked.
    root = if config.ingress.enabled then self.ingress else self.service;
  };
}
```

### Self-references for dependency tracking

Use `"${self.resourceName}"` to reference another resource's name. This creates a Nix store-path dependency that kix tracks automatically:

```nix
serviceAccountName = "${self.serviceAccount}";
```

### Label selectors with `scope.selectWorkload` and `scope.selectByLabels`

For Services, PDBs, and other resources that select pods via labels, use
`scope.selectWorkload` to derive the selector from the target workload:

```nix
service = scope.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "web";
  spec.selector = scope.selectWorkload self.deployment;  # derives matchLabels + tracks dependency
  spec.ports = [{ port = 80; }];
};
```

`scope.selectWorkload target` reads `spec.selector.matchLabels` from the target and
returns those labels with the target's store path attached as Nix string context.

For selecting a resource by its package-provided labels (e.g., a ServiceMonitor
matching a Service), use `scope.selectByLabels`:

```nix
serviceMonitor = scope.mkClusterResource {
  apiVersion = "monitoring.coreos.com/v1";
  kind = "ServiceMonitor";
  name = "my-monitor";
  spec.selector.matchLabels = scope.selectByLabels self.metricsService;
  spec.endpoints = [{ port = "metrics"; }];
};
```

Both functions:
- Return correct labels by construction (no shared variable to desync)
- Track dependencies automatically (no `requires` needed)

### Explicit `requires`

The `root.requires` list (or per-resource `requires`) is for resources that are **not** referenced via string interpolation or `selectWorkload`/`selectByLabels` but still need to be included. The most common case is HPA `scaleTargetRef` (a name-based reference, not a label selector).

### Warning system

The build emits `builtins.trace` warnings for:
- **Redundant requires** — resource already referenced via `"${self.x}"`, no need to also list in `requires`
- **Duplicate requires** — same resource listed twice
- **Orphaned resources** — defined in the package but unreachable from `root`

Fix all warnings before committing.

## kix API Reference

### scope (available in every package)

| API | Description |
|-----|-------------|
| `scope.mkResource { ... }` | Create a namespaced K8s resource |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource |
| `scope.mkDeployment` | Create a Deployment — auto-sets apiVersion/kind, copies `selector.matchLabels` to template labels |
| `scope.mkStatefulSet` | Same as mkDeployment but for StatefulSets |
| `scope.mkDaemonSet` | Same as mkDeployment but for DaemonSets |
| `scope.selectWorkload target` | Derive selector labels from target's `spec.selector.matchLabels` with automatic dependency tracking |
| `scope.selectByLabels target` | Select a resource by its package-provided labels (before scope injection) with dependency tracking |
| `scope.selectorLabels` | Default selector labels for this instance (used as `selector.matchLabels`). Overridable per-instance via `selectorLabels` in cluster config. |
| `scope.defaults config { defaults }` | Deep-merge user config over package defaults. Warns on unknown keys. |
| `scope.instanceName` | The instance name from the cluster definition |
| `scope.namespaceName` | The namespace this instance lives in |
| `scope.namespace` | The Namespace resource itself (for deps) |

### Workload constructors (scope.mkDeployment etc.)

These are pipe-friendly — use them at the end of a `|>` chain:

```nix
deployment =
  {
    name = "${name}-server";
    spec = {
      replicas = config.replicaCount;
      selector.matchLabels = scope.selectorLabels;
      template.spec.containers = [ { ... } ];
    };
  }
  |> kix.withMounts [ self.dataMount self.configMount ]
  |> scope.mkDeployment;
```

They auto-set `apiVersion`/`kind` and copy `spec.selector.matchLabels` to `spec.template.metadata.labels` (preventing selector mismatch). The `name` field is required in the input attrset.

### mkResource / mkClusterResource fields

| Field | Description |
|-------|-------------|
| `apiVersion` | Required. e.g. `"apps/v1"` |
| `kind` | Required. e.g. `"Deployment"` |
| `name` | Required. Resource name |
| `spec` | Resource spec (most resources) |
| `data` | For ConfigMaps |
| `stringData` | For Secrets |
| `labels` | Merged into `metadata.labels` (cluster labels + managed-by added automatically) |
| `annotations` | Merged into `metadata.annotations` |
| `extra` | Top-level fields merged outside metadata (e.g. `rules` for ClusterRole, `type` for Secrets, `webhooks` for webhook configs) |
| `outputs` | Named values that carry this resource's dependency context (e.g. `{ metricsPort = "9090"; }` → accessible via `resource.out.metricsPort`) |
| `requires` | Resources that must exist but aren't referenced via `"${self.x}"` |

### Resource outputs

Every resource exposes:
- `"${resource}"` — the resource name (string interpolation creates a dependency edge)
- `resource.out.name` — the resource name as a string (use in `envFrom`, `secretKeyRef`, etc.)
- `resource.out.selector` — the resource's labels (for ServiceMonitor selectors etc.)
- `resource.out.fqdn` — full DNS name (e.g. `my-svc.my-ns.svc.cluster.local`) with dependency context. Domain suffix configurable via `clusterDomain` cluster option.
- `resource.out.<key>` — named outputs from the `outputs` field, with dependency context

### Composition helpers (kix.*)

#### Mount helpers

Create `{ volume, volumeMount }` pairs from resources. Returns null when resource is null (disabled features silently skip).

| Function | Signature | Description |
|----------|-----------|-------------|
| `kix.mount.pvc` | `resource: { mountPath, name?, readOnly?, subPath? }` | PVC mount |
| `kix.mount.configMap` | `resource: { mountPath, name?, subPath?, items?, defaultMode? }` | ConfigMap mount. `items` selects specific keys: `[{ key = "app.conf"; path = "app.conf"; }]` |
| `kix.mount.secret` | `resource: { mountPath, name?, subPath?, items?, defaultMode? }` | Secret mount (same options as configMap) |
| `kix.mount.emptyDir` | `{ mountPath, name, medium?, sizeLimit?, subPath? }` | Ephemeral mount (no resource arg) |

Names auto-derive from `resource.out.name` when not specified.

```nix
# Examples from immich:
libraryMount = kix.mount.pvc storage { mountPath = "/usr/src/app/upload"; };
configMount = kix.mount.configMap self.configMap { mountPath = "/config"; };

# Examples from harbor — subPath + items for selective key mounting:
coreConfigMount = kix.mount.configMap self.coreConfigMap {
  name = "config"; mountPath = "/etc/core/app.conf"; subPath = "app.conf";
  items = [{ key = "app.conf"; path = "app.conf"; }];
};
coreSecretKeyMount = kix.mount.secret self.coreSecret {
  name = "secret-key"; mountPath = "/etc/core/key"; subPath = "key";
  items = [{ key = "secretKey"; path = "key"; }]; defaultMode = 420;
};
```

#### Mount injection

| Function | Description |
|----------|-------------|
| `kix.withMounts [ mount1 mount2 ... ]` | Inject mounts into a single-container pod spec (pre-seal). Nulls filtered automatically. Errors if multiple containers. |
| `kix.withMountsOn "containerName" [ ... ]` | Inject mounts into a specific container by name (multi-container pods). |

```nix
deployment =
  { name = "my-app"; spec = { ... }; }
  |> kix.withMounts [
    self.libraryMount
    self.configMount            # null if config disabled → silently skipped
    (kix.mount.emptyDir { name = "tmp"; mountPath = "/tmp"; })
  ]
  |> scope.mkDeployment;
```

For multi-container pods where `kix.withMounts` can't auto-target, either use `kix.withMountsOn` or wire volumes/volumeMounts manually (as harbor's registry does for its 2-container pod).

#### Service helpers

| Function | Description |
|----------|-------------|
| `kix.service.fromWorkload { name, type?, ports?, outputs?, ... } workload` | Auto-derive Service from a workload. Reads selector and ports from the workload's container spec. Pipe to `scope.mkResource`. |

```nix
# Simple — auto-derive everything:
service = self.deployment |> kix.service.fromWorkload { name = "my-svc"; } |> scope.mkResource;

# Override ports (harbor pattern — remap container port 8080 → service port 80):
coreService = self.coreDeployment
  |> kix.service.fromWorkload {
    name = "${name}-core";
    ports = [
      { name = "http-web"; port = 80; targetPort = 8080; protocol = "TCP"; }
    ] ++ lib.optionals config.metrics.enabled [
      { name = "http-metrics"; port = config.metrics.port; targetPort = config.metrics.port; protocol = "TCP"; }
    ];
    outputs.port = "80";
  }
  |> scope.mkResource;
```

#### Ingress helpers

| Function | Description |
|----------|-------------|
| `kix.ingress.fromService { name, host, path?, pathType?, port?, className?, tls?, annotations?, ... } service` | Auto-derive Ingress from a Service. Reads backend name and port from `service.out`. |

```nix
# Simple ingress (from immich):
ingress = self.service
  |> kix.ingress.fromService {
    inherit name;
    host = config.ingress.host;
    className = if ingressNginx != null then ingressNginx.out.ingressClassName else "public";
    tls = lib.optional (config.ingress.tls.enabled or false) {
      hosts = [ config.ingress.host ];
      secretName = config.ingress.tls.secretName;
    };
    annotations = { "nginx.ingress.kubernetes.io/proxy-body-size" = "0"; };
  }
  |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id)
  |> scope.mkResource;
```

For complex ingresses with multiple backends/paths (like harbor), build the Ingress manually with `scope.mkResource` and reference services via `self.coreService.out.name`.

#### Utility helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `kix.port` | `name: containerPort → { name, containerPort, protocol = "TCP" }` | Container port shorthand. Override protocol with `// { protocol = "UDP"; }` |
| `kix.mkEnvVars` | `{ KEY = "val"; OPT = null; } → [{ name = "KEY"; value = "val"; }]` | Env attrset → K8s env list. Nulls filtered — use for conditional features. |
| `kix.mkEnv` | `{ KEY = "val"; } → [rawEntry ...] → [{ name, value }, rawEntry ...]` | Combine named env vars with raw K8s env entries (e.g. `valueFrom.secretKeyRef`). |
| `kix.parseGi` | `"50Gi" → 50` | Parse K8s quantity to GiB number. Supports Ti/Gi/Mi. Returns null for unknown. |

```nix
# kix.port — container port declarations:
ports = [ (kix.port "http" 8080) (kix.port "metrics" 9090) ];

# kix.mkEnvVars — null-safe env var conversion:
env = kix.mkEnvVars ({
  DB_HOSTNAME = postgres.out.fqdn;
  REDIS_HOSTNAME = valkey.out.fqdn;
  ML_URL = if hasMl then "http://${machineLearning.out.fqdn}:${machineLearning.out.port}" else null;
} // config.env);

# kix.mkEnv — combine plain vars with secret refs:
env = kix.mkEnv {
  DB_HOSTNAME = postgres.out.fqdn;
  APP_NAME = "myapp";
} [
  { name = "DB_PASSWORD"; valueFrom.secretKeyRef = { name = "db-creds"; key = "password"; }; }
];

# kix.parseGi — storage validation:
storageSizeGi = kix.parseGi storage.out.size;
_warn = if storageSizeGi != null && storageSizeGi < 50 then
  builtins.trace "warning: storage undersized" null
else null;
```

### Top-level kix functions

| Function | When to use | Description |
|----------|-------------|-------------|
| `kix.buildCluster { ... }` | **Always.** Every cluster definition uses this. | Takes `name`, `clusterLabels`, `namespaces`, and `instances`. Returns `{ activation, instances, namespaces, rawManifests }`. The `activation` is the cluster root store path — pipeline derivations in flake.nix use `exportReferencesGraph` on it to produce annotated manifests and deploy graphs. |
| `kix.mkEnv envName envConfig instanceSets` | **When the same services run in multiple environments** (e.g. myapp-prod, myapp-stage, myapp-demo). Instead of duplicating instance blocks, define the service stack once and stamp it into env-prefixed namespaces with per-env config overrides. | Stamps instance sets into `{envName}-{setName}` namespaces. |
| `kix.mergeFragments { fragments; namespacePolicies; }` | **When multiple teams own different parts of a cluster.** Each team produces a fragment `{ namespaces, instances }` and `mergeFragments` combines them with collision detection. Don't manually merge attrsets — use this. | Deep-merges namespaces, detects instance collisions across fragments. |
| `kix.fromHelmChart { chart; values; releaseName; includeCrds; }` | **When migrating a Helm-managed service that you don't want to rewrite in pure kix yet.** Wraps a Helm chart so its output is tracked like any other kix package. Use this as a stepping stone — pure kix packages are preferred for full control. | Renders a Helm chart and wraps each resource as a kix resource. |
| `kix.fetchHelmChart { repo; name; version; hash; }` | **Always paired with `fromHelmChart`.** Fetches and pins a Helm chart by content hash. To get the hash, run the build once with a fake hash and Nix will tell you the correct one. | Returns a pinned chart path for `fromHelmChart`. |

### Useful `lib` functions for packages

| Function | Use case |
|----------|----------|
| `lib.optionalAttrs condition { ... }` | Conditionally include an attrset (e.g. HPA only if autoscaling enabled) |
| `lib.optional condition value` | Conditionally include a list element |
| `lib.optionals condition list` | Conditionally include multiple list elements |
| `lib.mapAttrs fn attrset` | Transform attrset values (e.g. generate resources from a config map) |
| `lib.filterAttrs predicate attrset` | Filter attrset entries |
| `lib.concatStringsSep sep list` | Join strings |
| `lib.mapAttrsToList fn attrset` | Convert attrset to list |
| `lib.attrValues attrset` | Get all values from an attrset |
| `lib.recursiveUpdate base overlay` | Deep-merge two attrsets (useful for probe/config variants) |
| `lib.id` | Identity function — useful as no-op in conditional pipes: `\|> (if cond then transform else lib.id)` |

## Cluster Definition

Cluster definitions can be **single-file** or **module-based**.

### Single-file (simple clusters)

```nix
# clusters/<name>.nix
{ kix, packages }:
kix.buildCluster {
  name = "my-cluster";
  clusterLabels = { cluster = "my-cluster"; team = "platform"; };
  namespaces = {
    kube-system = { };
    my-namespace = { };
  };
  instances = { ref, ... }: {
    kube-system = {
      coredns = { package = packages.coredns; };
      reloader = { package = packages.reloader; };
    };
    my-namespace = {
      my-app = {
        package = packages.my-app;
        config = {
          image.tag = "v2.0.0";  # override package defaults
          replicaCount = 3;
        };
      };
    };
  };
}
```

### Module-based (production clusters)

For larger clusters, split into NixOS-style modules in `clusters/<name>/`. Each module file receives `{ config, lib, ref, packages, ... }` and can declare `options` and set `config.instances`.

```nix
# clusters/nw1/platform.nix — declares cluster-wide options
{ config, lib, ref, packages, ... }:
{
  options = {
    cluster.domain = lib.mkOption { type = lib.types.str; };
    # ... other cluster-wide config
  };
  config.instances.kube-system = {
    ingress-nginx = { package = packages.ingress-nginx; };
  };
}
```

```nix
# clusters/nw1/harbor.nix — uses cluster options, defines instances
{ config, lib, packages, ... }:
{
  config.instances.harbor-system = {
    harbor = {
      package = packages.harbor;
      config = {
        externalURL = "https://harbor.${config.cluster.domain}";
        ingress.host = "harbor.${config.cluster.domain}";
        # ...
      };
    };
    harbor-redis = {
      package = packages.valkey;
      aliases = [ "redis" ];        # DI: harbor depends on "redis" → resolves here
      labelStyle = "helm";
      config = { ... };
    };
    system-harbor-db-1 = {
      package = packages.stackgres-cluster;
      aliases = [ "postgres" ];     # DI: harbor depends on "postgres" → resolves here
      config = { ... };
    };
  };
}
```

Key patterns in module-based clusters:
- **`aliases`** — DI resolution matches arg names to instance names *or* aliases. Harbor's package takes `redis` and `postgres` as args; the cluster wires them via aliases.
- **`labelStyle = "helm"`** — tells kix to emit Helm-compatible labels (for packages that need to match Helm-deployed resources during migration).
- **`selectorLabels`** — override auto-generated selector labels per-instance. Use when the cluster has immutable selectors (e.g. StatefulSet) that don't match the kix/Helm naming convention: `selectorLabels = { "app.kubernetes.io/instance" = "n8n"; "app.kubernetes.io/name" = "valkey"; };`
- **`clusterDomain`** — set the cluster DNS domain (default `"cluster.local"`). Affects all `resource.out.fqdn` values: `clusterDomain = "nw1.example.net";`
- **Cluster-wide options** — declared in one module (e.g., `platform.nix`), consumed by others via `config.cluster.domain` etc.

### Helm charts in cluster definitions

For apps you don't want to rewrite in pure kix:

```nix
my-helm-app = {
  package = kix.fromHelmChart {
    chart = kix.fetchHelmChart {
      repo = "oci://registry/charts";
      name = "chart-name";
      version = "1.0.0";
      hash = "sha256-...";  # use nix-prefetch or let it fail once
    };
    values = { ... };
    releaseName = "my-release";
    includeCrds = true;
  };
};
```

### Dependency Injection (DI)

Packages declare dependencies as function args. Hard deps are required args, optional features get `? null`:

```nix
{ scope, lib, valkey, postgres, storage, machineLearning ? null, ingressNginx ? null }:
```

DI resolution finds instances by matching arg names to instance names or `aliases` in the cluster definition. Same-namespace matches first, then cluster-wide (must be unambiguous).

**Infrastructure DI patterns:**

| Pattern | Example | When to use |
|---------|---------|-------------|
| Plain value on `out` | `storageClasses.out.storageClassName`, `ingressNginx.out.ingressClassName` | Single field the consumer needs |
| Transformer on `root.out` | `clusterIssuer.out.withCert` — modifies mkResource args | Adding annotations/fields the consumer would forget |
| Builder on parts | `clusterIssuer.mkCertificate { name, hosts, secretName }` | Creating CRD instances for the consumer |

### Storage DI

Persistent storage uses first-class PVC instances, not config-based `existingClaim` strings.

**The dependency chain:** `app → PVC → StorageClass`

```nix
# Cluster definition:
instances = {
  kube-system = {
    storage-classes = {
      package = packages.storage-classes;
      aliases = [ "storageClasses" ];
    };
  };
  my-app = {
    storage = {
      package = packages."persistent-volume-claim";
      config = {
        size = "500Gi";
        accessModes = [ "ReadWriteOnce" ];
      };
    };
    app = {
      package = packages.my-app;
      # storage resolves via DI to the PVC instance above
    };
  };
};
```

**In the consuming package (modern — kix.mount.pvc):**

```nix
{ scope, lib, kix, storage }:  # storage is a hard dep
# ...
build = { self, config, clusterConfig }: {
  dataMount = kix.mount.pvc storage { mountPath = "/data"; };

  deployment =
    { name = "my-app"; spec = { ... }; }
    |> kix.withMounts [ self.dataMount ]
    |> scope.mkDeployment;
};
```

`kix.mount.pvc` + `kix.withMounts` is preferred over manual volume/volumeMount wiring. It auto-derives the volume name, handles null resources, and keeps mount logic separate from the deployment spec.

**Manual approach (for complex cases):**

```nix
# When you need custom volume options or multi-container pods:
volumes = [{ name = "data"; persistentVolumeClaim.claimName = storage.out.name; }];
containers = [{ volumeMounts = [{ name = "data"; mountPath = "/data"; }]; }];
```

**Why PVCs are instances, not internal resources:**
- The cluster operator owns storage (size, class, backup) — not the app
- PVCs outlive apps — removing/upgrading the app doesn't touch storage
- Cross-namespace safety: `meta.scope = "namespace"` prevents mounting PVCs across namespaces (build-time error)
- Visible in the cluster definition — no hidden state

**Consumer-side validation:** Packages can validate their DI deps using `builtins.trace` warnings:

```nix
_storageWarning =
  if storageSizeGi < 50 then
    builtins.trace "warning: recommended minimum is 50Gi"
      null
  else null;
```

### Package Meta

Packages can declare a `meta` attrset for lifecycle and scoping rules:

```nix
meta = {
  lifecycle = "stateful";   # "stateful" triggers kix-diff protection rules
  scope = "namespace";      # "namespace" prevents cross-namespace DI references
  description = "...";
  maintainer = "team-name";
};
```

- `lifecycle = "stateful"` — flags the package for special kix-diff treatment (PVC deletion = error, not just warning)
- `scope = "namespace"` — DI resolution errors if a consumer in a different namespace depends on this package
- Both are enforced by `lib/eval.nix` at build time

## Multi-Component Packages

Complex applications like Harbor have multiple sub-services (core, portal, registry, jobservice, exporter). These are all defined in **one package** — not split into separate packages — because they share config, secrets, and internal URLs.

**Key patterns from `packages/harbor/`:**

1. **Shared let bindings** — define common values (selector labels, security contexts, probe bases, internal URLs) once in the `let` block:
   ```nix
   let
     selectorLabels = { app = "harbor"; release = name; };
     harborPodDefaults = { securityContext = { runAsUser = 10000; ... }; ... };
     probeBase = { httpGet = { scheme = "HTTP"; port = 8080; }; ... };
     coreProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v2.0/ping"; };
   ```

2. **Per-component selectors** — add a `component` label to distinguish pods:
   ```nix
   selector.matchLabels = selectorLabels // { component = "core"; };
   ```

3. **Cross-resource references via `self.*.out.name`** — use for envFrom, secretKeyRef, etc.:
   ```nix
   envFrom = [
     { configMapRef.name = self.coreConfigMap.out.name; }
     { secretRef.name = self.coreSecret.out.name; }
   ];
   env = [
     { name = "CORE_SECRET"; valueFrom.secretKeyRef = { name = self.coreSecret.out.name; key = "secret"; }; }
   ];
   ```

4. **Inline PVCs** — when storage is owned by the package (not the cluster operator), define PVCs as resources within the package rather than using DI:
   ```nix
   registryPVC = scope.mkResource {
     apiVersion = "v1"; kind = "PersistentVolumeClaim";
     name = "${name}-registry";
     spec = {
       accessModes = [ "ReadWriteOnce" ];
       resources.requests.storage = config.persistence.registry.size;
     } // lib.optionalAttrs (config.persistence.registry.storageClass != null) {
       storageClassName = config.persistence.registry.storageClass;
     };
   };
   ```
   Use DI PVCs (via `storage` arg) when the cluster operator should own storage lifecycle. Use inline PVCs when the package owns them.

5. **Manual volumes for multi-container pods** — when two containers share volumes (harbor's registry + registryctl), wire volumes manually instead of using `kix.withMounts` (which only works for single-container pods unless you use `kix.withMountsOn`).

6. **`root` with explicit `requires`** — in multi-component packages, many resources aren't reachable via transitive `self.*` references from the entry point. List them in `root.requires`:
   ```nix
   root = {
     resource = if config.ingress.enabled then self.ingress else self.coreService;
     requires = [
       self.coreDeployment self.coreService
       self.portalDeployment self.portalService
       self.registryDeployment self.registryService
       # ... all resources that must exist
     ];
   };
   ```

## Migration Tips

- **Read the Ansible role first.** Understand what the role creates — which Deployments, Services, ConfigMaps, RBAC, etc. This tells you what your package needs. Don't reverse-engineer from the cluster dump alone.
- **Ansible vars → `scope.defaults`.** Anything that's a variable in the Ansible role (image tags, replica counts, domain names) should be a config key in `scope.defaults`. Anything hardcoded in the Ansible templates can be hardcoded in the package.
- **Match the cluster, not the Ansible.** If the Ansible code says `replicas: 2` but the cluster has `replicas: 3`, use `3` as the cluster definition override. The cluster is the source of truth for current state.
- **Start rough, diff, fix.** Write a first pass of the package from the Ansible role, build, diff against the cluster dump, and iterate. The diff tool tells you exactly what's wrong.
- **Match names exactly.** If the diff shows a resource as kix-only with a fuzzy match to a cluster resource, rename it to match what's deployed.
- **Don't over-specify.** If a field is a K8s default (e.g. `strategy: RollingUpdate`, `dnsPolicy: ClusterFirst`), don't include it — the diff tool strips these automatically.
- **Cluster-only resources are fine.** Many cluster resources (operator CRDs, auto-generated secrets, controller resources) are not kix-managed. Focus on the **Modified** section.
- **Pipe the diff to an LLM.** The JSON-path format is designed for LLM consumption: `./scripts/kix-diff.py ./result cluster-dump/ | pbcopy`
- **Look at existing packages for patterns:**
  - `packages/reloader/` — clean simple package (single Deployment + Service)
  - `packages/immich/` — mid-complexity with DI storage, optional ML, conditional ingress, `kix.mount.*` + `kix.withMounts` + `kix.mkEnvVars` + `kix.service.fromWorkload` + `kix.ingress.fromService` patterns
  - `packages/harbor/` — complex multi-component package (core, portal, registry, jobservice, exporter) with shared let bindings, per-component selectors, inline PVCs, manual multi-container volumes
  - `packages/valkey/` — complex multi-resource package
  - `packages/storage-classes/` — `lib.mapAttrs` to generate resources from config
