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

Every package is a function `{ scope, config, lib }: ...` that returns a self-referential attrset.

```nix
{ scope, config, lib }:
let
  cfg = scope.defaults config {
    # Default config — overridable from cluster definition
    image.tag = "v1.0.0";
    replicaCount = 1;
  };
in
self: {
  # Resources as attrs — names become the keys used for `self.` references
  serviceAccount = scope.mkResource { ... };
  deployment = scope.mkResource { ... };
  clusterRole = scope.mkClusterResource { ... };

  # main defines the entry point and dependency graph
  main = {
    resource = self.deployment;
    requires = [ self.serviceAccount self.clusterRole ];
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

The `main.requires` list (or per-resource `requires`) is for resources that are **not** referenced via string interpolation or `selectWorkload`/`selectByLabels` but still need to be included. The most common case is HPA `scaleTargetRef` (a name-based reference, not a label selector).

### Warning system

The build emits `builtins.trace` warnings for:
- **Redundant requires** — resource already referenced via `"${self.x}"`, no need to also list in `requires`
- **Duplicate requires** — same resource listed twice
- **Orphaned resources** — defined in the package but unreachable from `main`

Fix all warnings before committing.

## kix API Reference

### scope (available in every package)

| API | Description |
|-----|-------------|
| `scope.mkResource { ... }` | Create a namespaced K8s resource |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource |
| `scope.selectWorkload target` | Derive selector labels from target's `spec.selector.matchLabels` with automatic dependency tracking |
| `scope.selectByLabels target` | Select a resource by its package-provided labels (before scope injection) with dependency tracking |
| `scope.defaults config { defaults }` | Deep-merge user config over package defaults. Warns on unknown keys. |
| `scope.instanceName` | The instance name from the cluster definition |
| `scope.namespaceName` | The namespace this instance lives in |
| `scope.namespace` | The Namespace resource itself (for deps) |

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
| `extra` | Top-level fields merged outside metadata (e.g. `rules` for ClusterRole, `provisioner` for StorageClass, `webhooks` for webhook configs) |
| `outputs` | Named values that carry this resource's dependency context (e.g. `{ metricsPort = "9090"; }` → accessible via `resource.out.metricsPort`) |
| `requires` | Resources that must exist but aren't referenced via `"${self.x}"` |

### Resource outputs

Every resource exposes:
- `"${resource}"` — the resource name (string interpolation creates a dependency edge)
- `resource.fqdn` — full DNS name (e.g. `my-svc.my-ns.svc.cluster.local`) with dependency context
- `resource.out.<key>` — named outputs from the `outputs` field, with dependency context

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

## Cluster Definition

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

## Migration Tips

- **Read the Ansible role first.** Understand what the role creates — which Deployments, Services, ConfigMaps, RBAC, etc. This tells you what your package needs. Don't reverse-engineer from the cluster dump alone.
- **Ansible vars → `scope.defaults`.** Anything that's a variable in the Ansible role (image tags, replica counts, domain names) should be a config key in `scope.defaults`. Anything hardcoded in the Ansible templates can be hardcoded in the package.
- **Match the cluster, not the Ansible.** If the Ansible code says `replicas: 2` but the cluster has `replicas: 3`, use `3` as the cluster definition override. The cluster is the source of truth for current state.
- **Start rough, diff, fix.** Write a first pass of the package from the Ansible role, build, diff against the cluster dump, and iterate. The diff tool tells you exactly what's wrong.
- **Match names exactly.** If the diff shows a resource as kix-only with a fuzzy match to a cluster resource, rename it to match what's deployed.
- **Don't over-specify.** If a field is a K8s default (e.g. `strategy: RollingUpdate`, `dnsPolicy: ClusterFirst`), don't include it — the diff tool strips these automatically.
- **Cluster-only resources are fine.** Many cluster resources (operator CRDs, auto-generated secrets, controller resources) are not kix-managed. Focus on the **Modified** section.
- **Pipe the diff to an LLM.** The JSON-path format is designed for LLM consumption: `./scripts/kix-diff.py ./result cluster-dump/ | pbcopy`
- **Look at existing packages for patterns.** `packages/reloader/` is a clean simple example. `packages/valkey/` shows a complex multi-resource package. `packages/storage-classes/` shows `lib.mapAttrs` to generate resources from config.
