---
name: kix-migration
description: Guide for migrating Kubernetes services into kix packages. Use this skill when creating new kix packages, migrating services from Ansible/Helm to kix, writing cluster definitions, or debugging kix-diff output. Also use when the user asks about kix APIs, package structure, or how to use kix functions like mkResource, mkEnv, mergeFragments, etc.
---

# kix Migration Guide

> This is a living document. Keep it current: `CLAUDE.md` makes updating it
> part of any change to kix APIs, package conventions or the diff tooling.
> Edit it in the same change, without asking first.

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
- **Helm's values.yaml layering** — Helm has a complex values merge hierarchy. kix uses typed `options` with `lib.mkOption` defaults, evaluated via the NixOS module system. Cluster-level `config` overrides are deep-merged on top of option defaults.
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

- **Config values differ** (image tags, replica counts, resource limits) → update `options` defaults or cluster config overrides
- **Naming mismatch** → adjust resource names in the package to match what's deployed
- **Extra labels/annotations on cluster side** → usually harmless (operator-injected), ignore via `--ignore-path`
- **Missing fields in kix** → add them to the package

## Package Anatomy

A function `{ scope, lib, kix }: ...` that returns `{ meta?, options?, deps?, build }`. **Dependencies are declared as build function args**, not package function args.

```nix
{ scope, lib, kix }:
let
  name = scope.instanceName;
in
{
  # Optional: package metadata — see "Package Meta" section below for all fields
  meta = {
    lifecycle = "stateless";  # "stateless" (default) | "stateful"
    scope = "cluster";        # "cluster" (default) | "namespace"
    description = "My package";
    maintainer = "team-name";
  };

  # Optional: per-dep diagnostics (assertions/warnings co-located with the dep)
  deps = {
    postgres.assertions = dep:
      lib.optional (!(builtins.elem "vectors" (dep.out.extensionNames or []))) {
        assertion = false;
        message = "requires pgvecto.rs extension";
      };
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = { repository = "myapp/server"; tag = "v1.0.0"; pullPolicy = "IfNotPresent"; };
    };
    replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
    ingress = kix.options.ingress;  # standardized { host, annotations } options
  };

  # build can be a function or a list of functions.
  # As a list, each entry's deps are discovered independently and results are merged.
  # This is how composable entries like kix.expose and kix.monitor work — they're
  # just functions that declare their own DI deps and return resources.
  # Deps are build function args: required = no default, optional = ? null.
  build = [
    # self: lazy-recursive ref to this build entry's return attrset (use self.x to reference sibling resources)
    # config: this instance's evaluated options
    # clusterConfig: cluster-wide module config (e.g. clusterConfig.cluster.domain)
    ({ self, config, clusterConfig, postgres, storage, scope, kix, ... }:
    let
      healthCheck = { httpGet = { path = "/health"; port = "http"; }; periodSeconds = 10; };
    in
    {
      dataMount = kix.mount.pvc storage { mountPath = "/data"; };

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
              });
              ports = [ (kix.port "http" 8080) ];
              livenessProbe = healthCheck;
              readinessProbe = healthCheck;
            }];
          };
        }
        |> kix.withMounts [ self.dataMount ]
        |> scope.mkDeployment;

      service = self.deployment
        |> kix.service.fromWorkload { name = "${name}-server"; }
        |> scope.mkResource;

      # root — entry point. Resources reachable via self.* refs are auto-tracked.
      # Note root *aliases* a named part; it never constructs a resource
      # itself. See "root must alias a named part" below.
      root = self.service;
    })

    # Composable build entries declare their own DI deps:
    (kix.expose { service = "service"; })
    (kix.monitor { service = "service"; port = "metrics"; })
  ];
}
```

**Inline attrset package** (for test fixtures and simple inline definitions in cluster files): a plain attrset `{ build, meta?, options?, deps? }` — no function wrapper needed. Use function packages for `packages/` directory files.

### `root` must alias a named part

**Every resource must live under its own key. `root` only ever points at one — it never constructs a resource itself.**

```nix
# Right
claim = scope.mkResource { apiVersion = "v1"; kind = "PersistentVolumeClaim"; ... };
root  = claim;                      # same store path → dedup'd by the manifest writer

# Wrong — renders nothing
root = scope.mkResource { apiVersion = "v1"; kind = "PersistentVolumeClaim"; ... };
```

Why: `collectResources` gathers renderable resources from the package's parts with `excludeKeys = [ "root" "meta" ]`. A resource reachable *only* through `root` is therefore never collected — the package emits its `PackageInstance` marker and nothing else. The cluster builds green and the resource simply does not exist.

kix now throws at eval time when `root`'s store path appears under no other part, so this fails the build rather than shipping (kixpkgs#25). The rule is worth knowing anyway: the error tells you at the end, the convention costs nothing at the start.

Both forms of `root` are fine as long as the resource itself is a named part:

```nix
root = self.service;                                   # bare alias
root = { resource = self.deployment; requires = [ self.sa ]; out = { ... }; };  # wrapper
```

This bit `persistent-volume-claim` (it shipped root-only and rendered no PVC), and later a package that produced zero CustomResources with no error. Both fixed by naming the part.

### Reserved part names

`secrets` and `crds` are folders (`knownFolders` in `kix/lib/eval/helpers.nix`): the view expects `secrets.<name> = ...` under them and refuses a resource assigned directly (`'secrets' must be an attrset of resources`). Call a single Secret part something else, e.g. `credentials`.

### `self` and dependency tracking

A name kix does not render is wrapped in `kix.untrackedRef`. When something in the package creates it (a Job minting a Secret, an operator), use the attrset form `kix.untrackedRef { kind = "Secret"; name = "..."; by = self.thatJob; }`: the referrer then depends on the creator and deploy waits for the object (`ingress-nginx`'s admission Secret). Do not also list the creator in `requires`. Never point `by` at the resource that holds the reference.

`self` is a lazy-recursive reference to the build function's return attrset. Use `"${self.resourceName}"` to reference another resource — this creates a Nix store-path dependency that kix tracks automatically. For label-based selectors (Services, PDBs), use `scope.selectorLabels` and `requires`:

```nix
service = scope.mkResource {
  apiVersion = "v1"; kind = "Service"; name = "web";
  requires = [ self.deployment ];  # explicit dep — not reachable via string interpolation
  spec.selector = scope.selectorLabels;
  spec.ports = [{ port = 80; }];
};
```

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
| `scope.mkResource { ... }` | Create a namespaced K8s resource that is not a workload. A Deployment, StatefulSet, DaemonSet or Job through it is an eval error: only the typed builders below seal a workload (validators, derived spread and PDB, netpol edges) |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource |
| `scope.mkDeployment` | Create a Deployment — auto-sets apiVersion/kind, copies `selector.matchLabels` to template labels |
| `scope.mkStatefulSet` | Same as mkDeployment but for StatefulSets |
| `scope.mkDaemonSet` | Same as mkDeployment but for DaemonSets |
| `scope.mkJob` | Same for Jobs; the selector may be omitted (template labels are used) |
| `scope.selectorLabels` | Default selector labels for this instance. Overridable per-instance via `selectorLabels` in cluster config. |
| `scope.mkSecret`, `scope.mkSecretRef` | Secret primitives with enriched `out` API. **Read `SECRETS.md` for the full API, gotchas, and usage patterns.** |
| `scope.forNamespace nsName` | Get a scope for a different namespace (cross-namespace resources) |
| `scope.rbac` | RBAC DSL. **Read `docs/RBAC_DSL.md`** for the full API (`group`, `core`, intents like `watch`/`reconcile`/`own`/`full`, `grant`, `mkClusterRoleSet`/`mkRoleSet`). |
| `scope.mkCRD`, `scope.mkCRDRef`, `scope.mkCR` | CRD resource builders. A package that wraps an upstream operator vendors the real CRDs under `<pkg>/crds/` from the URLs in `crds/sources.txt` and loads each with `scope.mkCRD { spec = (builtins.fromJSON (builtins.readFile ./crds/<name>.json)).spec; }`; use the `crd-vendoring` skill for that. `fromKind \|> clusterScoped \|> ...` (`kix/lib/vocab/crd.nix`) builds stubs for kinds kix invents. |
| `scope.instanceName` | The instance name from the cluster definition |
| `scope.namespaceName` | The namespace this instance lives in |
| `scope.namespace` | The Namespace resource itself (for deps) |

Workload constructors (`mkDeployment`, `mkStatefulSet`, `mkDaemonSet`, `mkJob`) are pipe-friendly — use at the end of a `|>` chain. They auto-set `apiVersion`/`kind` and copy `spec.selector.matchLabels` to `spec.template.metadata.labels` (preventing selector mismatch). The `name` field is required. They are the only way to build a workload: `scope.mkResource { kind = "Deployment"; ... }` is refused at eval, because a workload that skips `sealWorkload` gets no pod-spec validation, no derived spread or PodDisruptionBudget and no network-policy edges. Inside `spec.template.spec` write `serviceAccount = self.sa;` (not `serviceAccountName`), and in a StatefulSet `headlessService = self.svc;` (not `serviceName`).

### mkResource / mkClusterResource fields

`ownership.cede = [ "spec.versions" "webhooks[*].rules" ]` names fields an operator takes over after creation (also on `scope.mkCRD`): deploy applies without them when a 409 is confined to those paths, and fails any other conflict. cdi and stackgres-operator use it; never reach for `--force-conflicts` in a package.

A CRD an operator installs at runtime is a `scope.mkCRDRef { ...; installedBy = self.operatorDeployment; }`; CRs of that kind are built with `scope.mkCR self.thatRef { ... }` (openebs DiskPool).

| Field | Description |
|-------|-------------|
| `apiVersion` | Required. e.g. `"apps/v1"` |
| `kind` | Required. e.g. `"Deployment"` |
| `name` | Required. Resource name |
| `spec` | Resource spec (most resources) |
| `data` | For ConfigMaps |
| `stringData` | For Secrets (prefer `scope.mkSecret` — see `SECRETS.md`) |
| `labels` | Merged into `metadata.labels` (cluster labels + managed-by added automatically) |
| `annotations` | Merged into `metadata.annotations` |
| `extra` | Top-level fields merged outside metadata (e.g. `rules` for ClusterRole, `type` for Secrets) |
| `outputs` | Named values with dependency context. `name`, `fqdn`, `identityHash`, `selector` are auto-derived. |
| `requires` | Resources that must exist but aren't referenced via `"${self.x}"` |
| `extraDeps` | Additional dependency edges that don't fit `requires` or string interpolation |

### Resource outputs

Every resource exposes:
- `"${resource}"` — the resource name (string interpolation creates a dependency edge)
- `resource.out.name` — the resource name as a string (with dependency context)
- `resource.out.selector` — the resource's labels (for ServiceMonitor selectors etc.)
- `resource.out.fqdn` — full DNS name (e.g. `my-svc.my-ns.svc.cluster.local`). Domain suffix configurable via `clusterDomain` cluster option.
- `resource.out.<key>` — named outputs from the `outputs` field, with dependency context

**Naming vs. dialing (typed facts).** Address-shaped outputs (`out.fqdn`,
`out.url`, `outputs.*`) additionally carry an *endpoint fact*: using them in a
workload means "my pods dial this Service", which is what derives the netpol
edge and DNS ordering. `out.name` is structural — it creates the dependency
edge but NO netpol hole. Consequences when authoring:

- To **connect** to a Service, wire `out.fqdn`/`out.url` into the workload
  (directly or via a ConfigMap/Secret — the fact conducts through carriers,
  so indirection works).
- Referencing a Service's identity without any address flowing produces a
  lint (`workload references Service X by identity but no address value
  flowed`). If the use is genuinely structural (label, display string), wrap
  it: `kix.facts.refOnly svc.out.fqdn` (available as `k8s.facts.refOnly`).
- Dialing by bare `out.name` (intra-namespace short name) will NOT open a
  netpol hole — use `out.fqdn`, or stamp intent with
  `k8s.facts.connect svc.factTokens.endpoint value`.
- A producer that exposes a fact about itself rather than an address (a
  replica count, the scrape job label its operator will give it) wraps it:
  `outputs.replicas = kix.facts.structural (toString n);`. Consumers read
  `out.replicas` and get the ordering edge with no dial claim and no
  `refOnly` at the use site. The VictoriaMetrics operator's `mkVMAgent`,
  `mkVMAlert` and `mkVMAlertmanager` state `out.scrapeJob` and
  `out.replicas` this way; the probes read them instead of retyping the
  operator's naming.
- **Operator packages that own CRDs** get them from upstream, not from
  `fromKind` stubs: the `crd-vendoring` skill covers the route choice
  (vendor, or `mkCRDRef` markers when the operator installs its own),
  the `crds/sources.txt` file, and what to read in a refresh diff at a
  version bump. Design: `v2_discussions/146_crd_vendoring_and_upgrades.md`.
- **Operator packages that own CRDs** declare per-kind fact behavior on the
  CRD itself when their controller dials endpoints embedded in CR specs
  (e.g. a database operator connecting operand pods to an address in the
  CR). The declaration rides the typed builder chain — consumers building
  CRs via `scope.mkCR owner.out.crds.<kind>` get it automatically:

  ```nix
  # in the CRD-owning package (mkCRD works the same way)
  crdRef = scope.mkCRDRef {
    group = "my.io"; kind = "MyCluster"; plural = "myclusters";
    factBehavior = {
      endpoint = "terminate";          # controller dials; "conduct" = CR merely carries
      podSelector = cr: { "my.io/cluster" = cr.metadata.name; };  # the OPERAND pods
    };
  };
  ```

  netpol then opens egress for the operand pods + caller-ingress into the
  target namespace. Undeclared CR kinds absorbing an endpoint fact warn at
  eval time (conduct is assumed). For CRs not built via the typed builder
  (helm-rendered, raw kind strings) — or to fix a broken upstream
  declaration — cluster operators set
  `cluster.factBehavior."<group>/<Kind>"` (it wins over CRD declarations).

- **Readiness rides the same chain.** If the operator never stamps
  Ready/Available conditions, declare its health convention on the CRD
  builder (mkCRD and mkCRDRef both accept it). Two shapes: `readiness =
  { path = "/status/updateStatus"; equals = "operational"; }` compares one
  status field with a string (`victoria-metrics-operator/crds.nix`);
  `readiness = { condition = { type = "Bootstrapped"; status = "True"; }; }`
  looks for that entry in `status.conditions` (`stackgres-operator`,
  `envoy-gateway`, `cilium-external/netpol-rules.nix`). kix stamps the
  declaration on every typed-chain CR as the `kix.run/readiness`
  annotation and `kix deploy` evaluates it instead of the generic
  condition check. The CLI keeps no per-operator kind list: a new
  operator's convention goes in its package, never in `readiness.rs`.
  Without a declaration, deploys time out waiting on healthy CRs.

### Composition helpers (kix.*)

#### Mount helpers

Create `{ volume, volumeMount }` pairs from resources. Returns null when resource is null (disabled features silently skip).

| Function | Description |
|----------|-------------|
| `kix.mount.pvc resource { mountPath, name?, readOnly?, subPath? }` | PVC mount |
| `kix.mount.configMap resource { mountPath, name?, readOnly?, subPath?, items?, defaultMode? }` | ConfigMap mount |
| `kix.mount.secret resource { mountPath, name?, subPath?, items?, defaultMode? }` | Secret mount |
| `kix.mount.emptyDir { mountPath, name, medium?, sizeLimit?, subPath? }` | Ephemeral mount (no resource arg) |

Names auto-derive from `resource.out.name` when not specified.

#### Empty values and `kix.keep`

Rendering follows the collapse rule: literal empties (`emptyDir = { };`, `ingress = [ ];`) survive to the output, while a container whose members are all null (the shape merged unset options produce) collapses and the field is omitted. When migrating a manifest, paste `emptyDir: {}` and similar as-is; they render correctly. The one trap is a constructor that builds a presence-meaningful container from optional arguments: if all of them are null, the container collapses and the field silently disappears. Filter nulls with `lib.optionalAttrs`, or wrap the result:

| Function | Description |
|----------|-------------|
| `kix.keep container` | Attrset: never collapses to absent, renders `{}` even when every member is null; survives later merges. List: normalized eagerly to `[ ]`. |

The `volumeHasSource` scorecard rule (severity error) fails the build on any volume that would render without a source.

| Function | Description |
|----------|-------------|
| `kix.withMounts [ mount1 mount2 ... ]` | Inject mounts into a single-container pod spec. Nulls filtered. Errors if multiple containers. |
| `kix.withMountsOn "containerName" [ ... ]` | Inject mounts into a specific container by name (multi-container pods). |

#### Service helpers

| Function | Description |
|----------|-------------|
| `kix.service.fromWorkload { name, type?, ports?, outputs? } workload` | Auto-derive Service from a workload. Reads selector and ports from the container spec; a named `targetPort` you pass is checked against the container ports and written as the number (cilium drops egress on a named port, so hand-written Services must use numbers too). Pipe to `scope.mkResource`. |

#### Exposure & monitoring

**`kix.expose`** — composable build entry. Auto-detects whether the cluster uses Gateway API or Ingress:
- `gateway` DI dep present → emits `HTTPRoute`
- `ingressNginx` DI dep present → emits `Ingress` with optional TLS
- Neither present → no exposure resource

Parameters: `service` (string key in self) or `paths` (a list of `{ path, pathType?, service, port? }` for several backends behind one host, rendered as an Ingress with a rule per path or one HTTPRoute with a rule per path), `partName`, `defaultAnnotations` (Ingress only), `port`, `tlsSecretName` (Ingress only). Build for Gateway API first: Ingress stays supported, but every cluster is moving off it.

Use `options.ingress = kix.options.ingress;` for standardized `{ host, annotations }` options.

For routing `paths` cannot express, build HTTPRoute/Ingress manually via `kix.httpRoute.fromService` / `kix.httpRoute.fromPaths` / `kix.ingress.fromService` or raw `scope.mkResource`.

**`kix.monitor`** — composable build entry. Creates ServiceMonitor + optional PrometheusRule when `prometheus` DI dep is present, emits nothing otherwise.

Parameters: `service` (string key in self), `port` (default "metrics"), `path` (default "/metrics"), `alerts` (attrset of alert definitions), `extraEndpoints`, `extraLabels`. A package with several metrics Services calls it once per Service and sets `name` (resource name, default the instance name), `monitorPart` and `rulesPart` (part names, default `serviceMonitor` / `prometheusRules`) so the entries do not collide; `packages/harbor/` does this four times.

Use `options.metrics = kix.options.monitor;` for standardized metrics options.

**`kix.healthCheck`**: composable build entry. Renders a post-deploy probe Job (plus a ConfigMap holding the script) that runs after the things it checks are ready; a failing probe fails the deploy. Addresses come in as env vars from `out.*` values, which is what gives the Job its dependency edges and netpol egress.

Parameters, every callback taking `{ self, config, deps }` (`deps` is every DI package some other entry of the package declares): `script` (usually `builtins.readFile ./health-check.py`), `env` (`-> attrset`; the helper adds `RETRY_FOR`), `when` (`-> bool`, default `config.healthCheck.enable or true`), `retryFor` (`-> int`, default `config.healthCheck.retryFor or 90`), `requires` (`-> [ resources ]`, on top of the package root, which the Job always waits for), `partName`, `runtime` (`kix.healthCheck.runtimes.python` by default, `runtimes.shell` on curl, or your own `{ image = { repository; tag; digest; }; file; interpreter; env; }`), `activeDeadlineSeconds` (null: `retryFor` plus `kix.healthCheck.roundBudget`, 90 s; a given value must leave that room or the build fails), `ttlSecondsAfterFinished`. Declare `options.healthCheck = kix.options.healthCheck;` (`enable`, `retryFor`) and the defaults read it.

The script gives up once `RETRY_FOR` seconds have passed and keeps one round of checks under the round budget. It reads what it expects off resources (`self.vmAgent.out.replicas`, a structural output), never off the option that produced them. The Job carries `kix.run/rerun: on-change` (`kix/lib/core/annotations.nix`): the deploy engine recreates it when its identity hash changed or the last run failed, so the probe runs again when it, or anything upstream of what it checks, changes. Keep the script a file next to `default.nix` so it can be linted and run from a laptop through `kubectl proxy`. Example: `packages/victoria-metrics-agent/`. A probe that must log in takes the credential the same way a container does: `env = { self, ... }: { CLICKHOUSE_PASSWORD = self.credentials.out.keyRef "password"; ... }` (see `SECRETS.md`). Example: `packages/clickhouse/`.

**Cluster-side wiring:**
- Gateway API: instantiate `packages/envoy-gateway` with alias `"gateway"`
- Ingress: instantiate `packages/ingress-nginx` with alias `"ingressNginx"`

#### Utility helpers

| Function | Description |
|----------|-------------|
| `kix.port name containerPort` | `→ { name, containerPort, protocol = "TCP" }` |
| `kix.mkEnvVars { KEY = "val"; OPT = null; }` | `→ [{ name, value }]`. Nulls filtered. A value that is a `valueFrom` source (`secret.out.keyRef "password"`) renders as one, with the env name winning; any other attrset throws. |
| `kix.mkEnv { KEY = "val"; } [ rawEntries ]` | Combine named env vars with raw K8s env entries (e.g. `valueFrom.secretKeyRef`). |
| `kix.mergeGuarded { who; locked; } base overrides` | `lib.recursiveUpdate` for an `extraSpec` escape hatch that throws when `overrides` touches a path in `locked` (a list of attribute paths the package computed for correctness). Use it for every `extraSpec`. |
| `kix.parseGi "50Gi"` | `→ 50`. Supports Ti/Gi/Mi. |

A port name is unique per pod in Kubernetes, but `architecture.consistentPortNames` asks for one meaning per instance: if a package's main workload calls 5678 `http`, its worker's own port needs a different name (`health`, `metrics`), not the same one on another number. Resolvers that are handed a name without a workload cannot tell the two apart.

#### Writing one of Kix's own annotations

Kix stamps its own keys under a domain it owns. **Never spell that domain in a
package.** Use `kix.keys.<name>`, which comes from `kix/lib/core/annotations.nix`:

```nix
annotations.${kix.keys.hook} = "post-deploy";
annotations.${kix.keys.hookDeletePolicy} = "before-hook-creation,hook-succeeded";
annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Prometheus/${name}";
labels.${kix.keys.derived} = "true";
```

Common names: `hook`, `hookDeletePolicy`, `operandOf`, `monitorsExternalService`,
`derived`, `policyType`, `role`, `dbCluster`, `rerun`, `sopsSource`. The full set
is the `keys` attribute in `kix/lib/core/annotations.nix`.

The domain is spelled exactly once per language, there and in
`cli/kix/src/manifest/keys.rs`. A test fails the build if any other file in
`kix/` or `cli/` puts a Kix domain in a string literal, so a package that
hardcodes one will not merge. A package that needs these takes `kix` as an
argument.

### Top-level kix functions

| Function | When to use | Description |
|----------|-------------|-------------|
| `kix.buildCluster { ... }` | Every cluster definition. | Takes `name`, `modules`, optional `specialArgs`. Returns `{ activation, instances, namespaces, rawManifests }`. |
| `kix.mkEnv envName envConfig instanceSets` | Same services in multiple environments. | Stamps instance sets into `{envName}-{setName}` namespaces with per-env config overrides. |
| `kix.mergeFragments { fragments; namespacePolicies; }` | Multiple teams own different parts of a cluster. | Deep-merges namespaces, detects instance collisions across fragments. |
| `kix.helmChart { repo; name; version; hash; }` | **Tier 1:** inline Helm chart in cluster definitions. | Quick one-off, no package file needed. Auto-selects root, exposes `config.values`. |
| `scope.helm.importChart { chart; scope; values; ... }` | **Tier 2:** inside a package's `build` function. | Full control. Returns resource collection: `get kind name`, `find kind predicate`, `byKind kind`, `workloads`, `mkParts { root }`. |
| `scope.helm.fetchHelmChart { repo; name; version; hash; }` | Inside packages. | Fetches and pins a Helm chart by content hash. |
| `kix.mkImport { from?; out?; }` | Resource exists in cluster but not managed by kix. | Import marker for DI. DI resolution prefers managed instances over imports. |

### Useful `lib` functions for packages

| Function | Use case |
|----------|----------|
| `lib.optionalAttrs condition { ... }` | Conditionally include an attrset |
| `lib.optional condition value` | Conditionally include a list element |
| `lib.optionals condition list` | Conditionally include multiple list elements |
| `lib.mapAttrs fn attrset` | Transform attrset values (e.g. generate resources from a config map) |
| `lib.filterAttrs predicate attrset` | Filter attrset entries |
| `lib.recursiveUpdate base overlay` | Deep-merge two attrsets |
| `lib.id` | Identity function — useful as no-op in conditional pipes: `\|> (if cond then transform else lib.id)` |

## Cluster Definition

Cluster definitions can be **single-file** (one `{ kix, packages }:` function calling `kix.buildCluster` with a single module) or **module-based** (split into NixOS-style modules in `clusters/<name>/`).

### Module-based (production clusters)

Each module file receives `{ config, lib, ref, packages, ... }` and can declare `options` and set `config.instances`.

```nix
# clusters/nw1/platform.nix — declares cluster-wide options
{ config, lib, ref, packages, ... }:
{
  options.cluster.domain = lib.mkOption { type = lib.types.str; };
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

### Instance-level options

- **`aliases`** — DI resolution matches arg names to instance names *or* aliases. Packages that fill an infrastructure role (`meta.roles = [ "storageClasses" ]`, validated against the registry in `kix/lib/eval/roles.nix`) get the role name as an alias automatically — no instance-level alias needed.
- **`labelStyle = "helm"`** — emit Helm-compatible labels (for migration).
- **`selectorLabels`** — override auto-generated selector labels per-instance. Use when the cluster has immutable selectors (e.g. StatefulSet).
- **`optional = true`** — instance only activates if something depends on it.
- **`partsOverlays`** — per-instance post-build transforms on the parts attrset. `globalPartsOverlays` applies to all instances. Read `kix/lib/eval/instance.nix`.

### Cluster-level options

- **`clusterDomain`** — DNS domain (default `"cluster.local"`). Affects all `resource.out.fqdn` values.
- **`availablePackages`** — package registry for auto-instantiation into `autoNamespace` when transitively required.
- **`namespaces`** — per-namespace `labels`, `annotations`, `resourceQuota`, `networkPolicies` (directions, defaultDeny).
- **`cluster.roles`** — binding modes for environment-owned roles (`cni`, `dns`, `storageClasses`, `loadBalancer`, `network-policy-enforcer`): `absent` (vacant, a managed instance fills it), `shadowable` (environment default, managed instance overrides), `exclusive` (environment owns it — a managed instance claiming it is an eval error). Set by flavors; override per-cluster (e.g. `cluster.roles.cni.binding = "absent"` on kind created with `disableDefaultCNI`).
- **`cluster.capabilities`** — substrate axioms (`multiNode`, `privilegedContainers`, `daemonSets`, `gpu`, ...), three-valued: `null` = unknown (relying workloads warn), `false` = hard error, `true` = pass. Read `kix/lib/modules.nix` for the full list. The old role-backed bools (`cni`, `networkPolicyAPI`, `loadBalancer`, `persistentStorage`, `rwxStorage`, `volumeSnapshots`, `ingressController`) no longer exist — role providers are derived from `meta.roles`; rwx/snapshot facts live on the storage provider's `out`.
- **`cluster.network`** — `podCidr`, `serviceCidr`, `dnsUpstream`.
- **`cluster.availability`** — `none | pod | node | zone`, the largest failure a workload must survive; derived from the capabilities when unset, capped by them, overridable with `instances.<ns>.<inst>.availability`. Every package takes an `availability` argument and maps it in every replica-shaped default: `default = kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }` (a literal replica default is wrong; an explicit instance value still wins). A package that cannot run more than one replica declares `meta.availability.max = "none"` (or `"pod"` if it cannot fail over) with a reason. Do not write `topologySpreadConstraints` or pod anti-affinity in a package: any Deployment/StatefulSet with `replicas > 1` gets spread across `cluster.topology.failureDomainKeys` (zone, then hostname, from `cluster.topology.zoneKey` and `hostKey`, which default to the well-known labels; nothing on `multiNode = false`) and a PDB, derived at build time, with strictness lowered from the level. Author-written constraints switch both derivations off for that workload. On a single-node cluster a hand-written `requiredDuringScheduling` anti-affinity with `replicas > 1` is an eval error. Operator-CR packages (VMCluster) read `clusterConfig.cluster.topology.failureDomainKeys`. Read `kix/lib/plugins/availability/module.nix` and `kix/lib/core/availability.nix`.
- **`ref`** — module arg, `ref.<namespace>.<instance>`, a pointer to another instance for `deps.<arg> = ref.kube-system.coredns`. The wired dep resolves like an auto-resolved one (config injection lands on it, meta checks apply).
- **`mkLocked`** — marks a config field as immutable; blocks dep injection overrides.
- **Monitoring module** — declarative Prometheus/Grafana/Loki stack. Read `kix/lib/modules/monitoring.nix`.

**Network policy:** CiliumNetworkPolicy is auto-derived from endpoint facts — no package authoring needed. Egress rules for API server access, DNS, and cross-package services are generated automatically; a workload gets an edge to exactly the Services whose *address values* (`out.fqdn`/`out.url`, possibly via ConfigMap/Secret indirection) reached its manifest. Default-deny is per-namespace. Edges the graph cannot see (an ingress controller's backends, a component that dials something it was not handed facts for) are declared as `meta.network.intents` (HANDBOOK §16.5) or by repeating the dep's `out.*` facts in the workload's env. Use container port numbers as `targetPort` in hand-written Services: cilium drops egress on a named port. Read `kix/lib/plugins/netpol/` and `kix/lib/core/facts.nix` for details. If hitting blindspots (Helm chart opacity, operator-managed pods), see `v2_discussions/96_netpol_autogeneration_blindspots.md`.

### Flavors (target presets)

Flavors set `cluster.provider`, `cluster.roles` bindings, `cluster.capabilities` substrate axioms, and platform-provided DI imports. Use as the first module in `buildCluster`:

```nix
kix.buildCluster {
  name = "my-cluster";
  modules = [ kix.flavors.gke  ./platform.nix  ./apps.nix ];
}
```

Available: `k3s`, `kind`, `kubeadm`, `eks`, `gke`, `gke-autopilot`, `aks`, `openshift`, `ovh`, `scaleway`, `rke2`, `lithus`, `talos`.

Flavors provide `optional = true` imports for platform-managed services, declared via `kix.mkImport { roles = [ ... ]; out = { ... }; }`:
- **DNS** (`platform-dns`, role `dns`) — all flavors.
- **Storage** (`platform-storage`, role `storageClasses`, with `rwx`/`snapshots` facts on `out`) — flavors with built-in storage.

If the cluster installs its own managed package (e.g. `storage-classes`), it automatically takes priority over the flavor import (managed shadows import) — unless the flavor declares the role binding `exclusive`, in which case the managed instance is refused at eval (e.g. a managed CNI on stock kind/k3s; override the binding to `"absent"` when the cluster genuinely runs without the environment's default).

### Helm charts — three tiers

**Tier 1: Inline** (no package file): `package = kix.helmChart { repo; name; version; hash; }; config.values = { ... };`

**Tier 2: Real package with `importChart`** (full control — DI, CRD refs, custom root):
```nix
{ scope, lib }:
let chart = scope.helm.fetchHelmChart { repo = "oci://..."; name = "x"; version = "1.0"; hash = "sha256-..."; };
in {
  meta.version = "1.0.0";
  build = { config, scope, ... }:
    let resources = scope.helm.importChart { inherit chart scope; values = config.values or {}; releaseName = "x"; };
    in resources.mkParts { root = resources.get "Deployment" "x"; };
}
```

`mkParts` auto-derives a public `out`:
- `out.byKind.<Kind>.<name>` — flat lookup of every wrapped chart resource. Consumers reach non-root chart resources via `pkg.out.byKind.Service.foo.out.fqdn` instead of forcing the producer to hand-roll overrides.
- For a workload root (Deployment/StatefulSet/DaemonSet/Job) with exactly one Service that selects it, that Service's `out.{name, fqdn, selector, ports, url}` is promoted onto `pkg.out` so consumers reading `pkg.out.fqdn` get the public Service FQDN. Skipped silently when 0 or >1 Services match — pass `out = { fqdn = ...; }` explicitly to override.
- For Service roots, no promotion is needed (`k8s.mkResource` already auto-derives correct outs); only `byKind` is added.
- `out.crds.<Kind> = { cr, mkCR }` for every CRD the chart ships in its `helm template --include-crds` output. Builders inject the CRD plus all chart workloads as `requires`, so a consumer's CR waits for both Establishment and controller readiness. Charts that install CRDs at runtime (like cilium's `INSTALL_CRDS`) won't expose anything here — fall back to `scope.mkCRDRef`.

`importChart` parameters worth knowing:
- `deps = [ depA depB ];` — auto-collects every context-carrying string at `dep.out.*` and threads them through netpol generation (replaces the manual `networkDeps = [ dep.out.fqdn ]` plumbing). Use `networkDeps` only for context buried in nested values like `dep.out.byKind.Service.x.out.fqdn`.
- `replaceResource` (method on the returned collection) — substitute a chart resource with a kix-native one: `resources.replaceResource "Ingress" "foo" myKixIngress`. Use when a chart ships e.g. an Ingress but you want `kix.expose` to decide per-cluster how to materialize it. The replacement must declare its own `requires` if it needs to wait for chart resources; edges INTO the original are dropped.

**Tier 3: Native package** (no Helm, full DSL control).

### Dependency Injection (DI)

Packages declare dependencies as **build function args**. Required deps have no default, optional deps get `? null`. The eval system discovers deps by introspecting build function args (stripping system args: `self`, `config`, `scope`, `lib`, `kix`, `clusterConfig`, `deps`).

DI resolution priority: (1) explicit dep overrides, (2) same-namespace match, (3) cluster-wide match (must be unambiguous). **Managed instances take priority over imports.** The resolved deps attrset is also available as a single `deps` arg.

**Infrastructure DI patterns:**

| Pattern | Example | When to use |
|---------|---------|-------------|
| Plain value on `out` | `storageClasses.out.storageClassName` | Single field the consumer needs |
| Transformer on `root.out` | `clusterIssuer.out.withCert` | Adding annotations/fields the consumer would forget |
| Builder on parts | `clusterIssuer.mkCertificate { ... }` | Creating CRD instances for the consumer |

**Storage DI:** Persistent storage uses first-class PVC instances, not config-based `existingClaim` strings. Short version: `storage` is a DI dep, use `kix.mount.pvc storage { mountPath = ...; }`. **Read `STORAGE.md` for the full pattern, cluster definition example, and design rationale.**

**Illegal object names are an evaluation error.** Kix applies Kubernetes' naming rule for each resource kind: an RFC 1035 label for a Service, a DNS-1123 label for a Namespace, and a DNS-1123 subdomain for other resources. RBAC resources are exempt because the API server validates their names as path segments. Schema validation cannot catch these errors because the OpenAPI schema leaves `metadata.name` unconstrained. During a migration, the usual cause is a camel-case instance name copied from a build argument. Packages normally derive resource names from `scope.instanceName`, so rename the instance with a lowercase name. Preserve the build argument as a DI name with `meta.defaultAliases = [ "thatCamelCaseName" ]`, as `ingress-nginx` does for `ingressNginx`.

**Raw PVCs are an eval error.** A package building `kind: PersistentVolumeClaim` directly throws at build time — including PVCs emitted by an imported helm chart with persistence enabled. The escape is an explicit grant in package meta: `meta.unsafe = [ "raw-pvc" ]` (closed vocabulary, `kix/lib/unsafe.nix`; every grant is listed by the `architecture.unsafeGrants` scorecard audit). Prefer restructuring to the `storage` DI dep; grant `raw-pvc` only for chart-emitted claims or genuinely inline multi-component claims.

**A package that cannot pass a structural security rule declares why.** Three more grants exist for the cases where the rule is right and the package is still correct: `host-network` (pods on the host network, PID or IPC namespace), `privileged` (privileged containers) and `run-as-root` (containers as uid 0). Each switches its rule off for that package alone and is listed by `unsafeGrants` in every build. `kix/packages/cilium` holds all three, because programming the node's networking is what a CNI does. Reach for one only for a CNI, a CSI node plugin or a node-level agent — an application package that trips these rules has a bug. The alternative they replace, a per-namespace severity override in the cluster definition, exempts everything else in that namespace too.

### Package Meta

- **`meta.podSecurity`** — `"privileged" | "baseline" | "restricted"`, the Pod Security level the package's pods need (kubevirt: privileged). The namespace carries `pod-security.kubernetes.io/enforce` at the most permissive level any of its instances needs.
- **`meta.availability.max`** caps the whole instance; a package where only some workloads cannot reach the level puts `availability.max = "pod"` on those builder calls (`scope.mkDeployment { availability.max = "pod"; ... }`) so a quorum store beside a single-replica controller keeps hard spread (openebs).

```nix
meta = {
  lifecycle = "stateful";   # "stateless" (default) | "stateful"
  scope = "namespace";      # "cluster" (default) | "namespace"
  version = "1.2.0";        # package version (used for version constraint checks)
  description = "...";      # required: governance.hasDescription warns without it
  owner = "platform";       # required: "platform" or "app-team"
  maintainer = "team-name";
  conflictsWith = [ "other-pkg" ];          # same-namespace mutual exclusion
  "cluster:conflictsWith" = [ "alt-cni" ];  # cluster-wide mutual exclusion
};
```

- `lifecycle = "stateful"` — this package **provides state that other packages depend on**. Triggers kix-diff protection (PVC deletion = error) and migration pair detection. Examples: `persistent-volume-claim`, `stackgres-cluster`, `valkey`. A package that merely *consumes* stateful services is **not** stateful.
- `scope = "namespace"` — DI resolution errors if a consumer in a different namespace depends on this package.
- `version` — enables dependency version compatibility checks via `checkMetaStatic`. Read `kix/lib/meta.nix` for `parseVersion`, `versionAtLeast`, `versionAtMost`.
- `owner` — every package in the tree declares one, `"platform"` for infrastructure and `"app-team"` for user-facing applications. `governance.hasOwner` warns without it.
- `conflictsWith` / `cluster:conflictsWith` — build-time error if conflicting packages are co-instantiated.
- All enforced by `kix/lib/eval.nix` at build time.

**Every workload kind has a typed builder, and `scope.mkResource` refuses all of them.** `mkDeployment`, `mkStatefulSet`, `mkDaemonSet`, `mkJob`, `mkCronJob` and `mkHelmWorkload`. A CronJob's pod template sits one level deeper, under `spec.jobTemplate.spec.template`, and `mkCronJob` needs `spec.jobTemplate.spec.template.metadata.labels`, because a CronJob has no selector of its own and those labels are the only identity its pods carry.

**Workload labels.** The typed workload builders stamp the workload's own selector labels onto its `metadata.labels`, on top of the cluster and instance labels, so `app.kubernetes.io/name` is on the object and not only in the selector and the pod template. When the selector has no `app.kubernetes.io/name` (an upstream `app` or `name` selector), `mkDeployment`, `mkStatefulSet` and `mkDaemonSet` set it to the instance name on the object and the pod template, so `kubectl get pods -l app.kubernetes.io/name=<instance>` finds the pods. The immutable selector is left as written. A package's explicit `labels` argument still wins, and its value is what the pod template gets; an `app.kubernetes.io/name` in the pod template's own labels wins there. Helm-parity packages (`labelStyle = "helm"`) keep the chart's `app`/`release` labels.

**Scorecard:** on by default with the full built-in rule set, every finding capped at `scorecard.maxSeverity = "warning"` for users; this repository's flakes raise the cap to `error` for every cluster (`mkFlake { clusterModules }`), so a package that trips an error-severity rule fails every test cluster it is in. Rules score what ships, derived resources included. Rules check for: resource requests/limits, liveness+readiness probes, non-root containers (`security.nonRoot`: set `runAsNonRoot = true` when the image runs as a non-root user, numeric `runAsUser` when the image names its user by name, and hold `meta.unsafe = [ "run-as-root" ]` with a comment saying why only when the image needs root), no `:latest` tags, `meta.owner`, `meta.description`, network policies, a source on every volume (`emptyDir = kix.keep { }` for an empty one), distinct labels on same-kind resources, and more. A cluster changes one rule with `scorecard.ruleOverrides`, never by copying `rules`. Read `kix/lib/rules/` and `kix/lib/scorecard.nix`.

**Annotation domains (v2_discussions/128):** operator packages declare the annotation prefixes they manage via `meta.annotationDomains = [ "reflector.v1.k8s.emberstack.com" ]` (reflector, prometheus-operator do). The `architecture.annotationDomainOwnership` rule warns when a package's resources carry `metadata.annotations` keys under a declared domain without a DI dep on the declarer, and when a domain-shaped annotation has no declarer anywhere (dead annotation — the operator is probably missing). Reserved suffixes (`kubernetes.io`, `k8s.io`, `kix.run`, `helm.sh`, `kubebuilder.io`) are exempt; by-convention domains consumed outside kix (e.g. `prometheus.io` scrape annotations) go in the cluster's `scorecard.knownAnnotationDomains`. There is no `kix.run/capability` stamping anymore — the dep edge is the legitimacy marker.

## Multi-Component Packages

For packages with multiple sub-services (harbor-style), keep everything in **one package** — not split into separate packages. **Read `MULTI_COMPONENT.md` for patterns**: shared let bindings, per-component selectors and Service labels, fact-carrying internal URLs, breaking a mutual-dial cycle, one `kix.monitor` per metrics Service, `root.requires`, `root.postHooks`. Reference: `packages/harbor/`.

## Operator-Managed Stacks (VictoriaMetrics reference)

Some stacks are not Deployments you render but custom resources an operator
turns into pods at runtime. The VictoriaMetrics packages are the reference
for that shape (design: `v2_discussions/133`, shipped 2026-09-07):

- `packages/victoria-metrics-operator/` owns the CRDs (`crds.nix`, typed
  builder chain with `readiness` and `factBehavior`), the kinds table
  (`kinds.nix`) and the controller (`operator.nix`). It answers the
  `prometheus` alias and ships the prometheus-operator compat CRDs
  (ServiceMonitor, PodMonitor, PrometheusRule, Probe) with the same
  builder surface (`out.mkServiceMonitor`, `out.mkPrometheusRule`, ...),
  so every `kix.monitor` call and app-package ServiceMonitor works
  unchanged; the operator converts them. It also exposes CR builders such
  as `out.mkVMCluster scope { ... }`.
- `packages/victoria-metrics-cluster/` (VMCluster, aliases
  `prometheusServer` and `vmCluster`), `victoria-metrics-agent/` (VMAgent)
  and `victoria-metrics-alert/` (VMAlert + VMAlertmanager) each build one CR
  through the operator's builder, never a raw kind string. The cluster
  package does not render Services over the operator's pods. It uses
  `scope.mkServiceRef` for the Services the operator creates
  (`vmselect-<name>`, `vminsert-<name>`), and builds `out.serviceUrl` /
  `out.insertUrl` on the ref's `out.fqdn` so consumers keep dependency
  context. Same pattern as `packages/prometheus` (`prometheus-operated`)
  and `packages/alertmanager` (`alertmanager-operated`). A Service kix must
  render itself over operator pods (the Thanos sidecar) declares the CR with
  `metadata.annotations."kix.run/operand-of" = "<group>/<Kind>/<name>"`;
  otherwise the cross-resource check refuses a selector that matches no pod
  template in the build. There is no list of operator kinds anywhere.
- Trial posture: `lifecycle = "ephemeral"` on the cluster package means
  historical metrics are expendable on a storage swap. Revisit before VM
  becomes a long-term store.
- The StorageClass arrives as an import marker (`kix.mkImport { out.storageClassName = ...; }`
  under the `storageClasses` alias), so the substrate stays outside kix.

When migrating a cluster from kube-prometheus-stack: keep the
`prometheus` alias on the operator package and the `prometheusServer` alias
on the cluster package, and existing packages (grafana datasource,
`kix.monitor` users) rewire themselves. A whole-stack example with an
optional node-pin module lives in the lithus monorepo at
`client/lithus/clusters/shared/monitoring-stack.nix`.

## Two Implementations, One Alias (ClickHouse reference)

When a service has a small form and an operator form, build both as separate packages that answer one alias with one `out` contract, so a consumer is wired once and the cluster picks the implementation. The ClickHouse packages are the reference (design: `v2_discussions/148`):

- `packages/clickhouse/` renders a single StatefulSet with embedded Keeper. `packages/clickhouse-cluster/` builds a ClickHouseInstallation through `packages/clickhouse-operator/` and `packages/clickhouse-keeper/`. Both carry `defaultAliases = [ "clickhouse" ]` and the `out` that `packages/clickhouse/contract.nix` defines (`httpUrl`, `nativeEndpoint`, `host`, `ports`, `username`, `authSecret`, `authPasswordKey`, `clusterName`, `version`).
- The contract is a file, imported by both implementations (`root.out = contract.check "clickhouse (${name})" { ... }`) and by the facade (`deps.clickhouse.assertions = dep: contract.assertions who dep.out`), so a missing or misshapen field fails at eval and names the package. Keep it small. A field one implementation cannot honour means a different alias, not a `null`.
- `version` is a contract field (the server release as `YY.M`). A consumer states a requirement as an assertion on the dep: `lib.optional (lib.versionOlder dep.out.version "25.3") { assertion = false; message = ...; }`, as `clickhouse-database` does. Selection among several instances stays explicit (`deps.clickhouse = ref.<ns>.<inst>`).
- An operator package exposes the selectors of the pods it creates (`out.operandSelector.<kind> name`) from its kinds table, and the CR packages read them for the policies they write over operator pods. Their `extraSpec` goes through `kix.mergeGuarded` with the computed paths locked.
- Consumers go through a facade, `packages/clickhouse-database/` (the `stackgres-database` shape), which owns the credentials in the consumer's namespace and forwards the server's `out`. No consumer touches the server package.
- Share what is genuinely the same: `clickhouse-cluster` runs the probe script from `packages/clickhouse/health-check.py`, with an env var for what differs (the replica count).
- Prove the contract with a build: `clusters/test-clickhouse-swap/` builds one consumer on each implementation and the `clickhouse-swap` flake check diffs the rendered manifests, allowing only the hostname to differ.
- Upstream vocabulary, not a Kix dialect: server config is ClickHouse YAML fragments as Nix attrsets, merged with `null` deleting a key, so anything in the ClickHouse docs can be set without a new option.

## Migration Tips

- **Read the Ansible role first.** Understand what the role creates — which Deployments, Services, ConfigMaps, RBAC, etc. Don't reverse-engineer from the cluster dump alone.
- **Ansible vars → `options`.** Anything variable in the Ansible role → `lib.mkOption` default. Anything hardcoded → hardcoded in the package.
- **Match the cluster, not the Ansible.** If Ansible says `replicas: 2` but the cluster has `3`, use `3` as the cluster definition override.
- **Start rough, diff, fix.** Write a first pass, build, diff against the cluster dump, iterate. The diff tool tells you exactly what's wrong.
- **Match names exactly.** If the diff shows a kix-only resource with a fuzzy match to a cluster resource, rename it.
- **Don't over-specify.** K8s defaults (e.g. `strategy: RollingUpdate`) are stripped by the diff tool automatically.
- **Cluster-only resources are fine.** Many cluster resources (operator CRDs, auto-generated secrets) are not kix-managed. Focus on the **Modified** section.
- **A new package is evaluated by `nix build .#checks.x86_64-linux.every-package-evaluates`** without being named by any cluster. If it has options with no default, or needs an instance the catalog cannot auto-instantiate (a `credentials` secret), add them to the `settings` table in `kix/package-eval.nix`.
- **Pipe the diff to an LLM.** `./scripts/kix-diff.py ./result cluster-dump/ | pbcopy`
- **Look at existing packages for patterns:**
  - `packages/reloader/` — clean simple package (single Deployment + Service)
  - `packages/immich/` — mid-complexity with DI storage, `kix.expose`, `kix.mount.*` + `kix.withMounts` + composable build list
  - `packages/harbor/` — complex multi-component (read `MULTI_COMPONENT.md`)
  - `packages/valkey/` — complex multi-resource package
  - `packages/storage-classes/` — `lib.mapAttrs` to generate resources from config
  - `packages/victoria-metrics-*/` — operator + operand CRs, compat CRDs behind an alias (see "Operator-Managed Stacks")
  - `packages/clickhouse*/` — one alias and contract served by a bare package and an operator stack, with a facade for consumers (see "Two Implementations, One Alias")
