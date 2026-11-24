---
name: kix-migration
description: Guide for migrating Kubernetes services into Kix packages. Use this skill when creating new Kix packages, migrating services from Ansible/Helm to Kix, writing cluster definitions, or debugging cluster-dump diff output. Also use when the user asks about Kix APIs, package structure, or how to use Kix functions like mkResource, mkEnv, mergeFragments, etc.
---

# Kix Migration Guide

> This is a living document. Keep it current: `CLAUDE.md` makes updating it
> part of any change to Kix APIs, package conventions, or the diff tooling.
> Edit it in the same change, without asking first.

## Source Material

When creating a Kix package, the primary sources are:

1. **Existing config management**: often Ansible roles, but could also be Helm charts, raw manifests, or Terraform. These contain the K8s manifests, config defaults, and deployment logic. Read these first to understand what should exist.
2. **Cluster dump**: what's actually running. May have drifted from the source config.
3. **Upstream docs / charts**: for understanding what fields mean and what the defaults are.

If migrating from Ansible, ask the user where the roles are on disk. The typical mapping is:
- Ansible role → Kix package (`kix/packages/experimental/<name>/default.nix`, since new packages start experimental)
- Ansible group_vars / host_vars → cluster definition overrides (`clusters/<name>.nix`)
- Ansible `templates/*.yaml.j2` → `scope.mkResource { ... }` calls

When translating, read the source config first to understand intent, then check the cluster dump to see what's actually deployed. Where they disagree, match the cluster dump (it's what's running) and note the discrepancy.

**Do not blindly transliterate.** Ansible, Helm, and Kix have fundamentally different models. Patterns that make sense in the source may be wrong in Kix:

- **Helm's release-name prefixing:** Helm prepends the release name to everything. Kix uses `scope.instanceName` and explicit naming. Don't cargo-cult the prefix pattern.
- **Ansible's imperative ordering:** Ansible tasks run in order. Kix tracks dependencies via store-path references (`"${self.x}"`). You don't need to think about ordering; just reference what you depend on.
- **Helm's values.yaml layering**: Helm has a complex values merge hierarchy. Kix uses typed `options` with `lib.mkOption` defaults, evaluated by the NixOS module system. An instance that sets one field of a submodule keeps the defaults of its other fields, but an attrset default is replaced as a whole, so put defaults on submodule fields (the option contract, `kix/lib/eval/options.nix`, refuses a non-empty attrset default). `every-package-evaluates` checks it for every package in this repository; cluster evaluation does not, so check a package kept outside this repository with `kix.checkPackageOptions { package; who; }` (every availability level the package can run at), or list it under `mkFlake { packages.<name> = ./path; }` for an `option-contract-<name>` flake check (`docs/src/content/docs/reference/package-anatomy.mdx`).
- **Ansible's `when:` conditionals:** Use `lib.optionalAttrs` / `lib.optional` for conditional resources, or `if/then/else` with `null` for optional parts of the attrset.
- **Helm's template helpers (`_helpers.tpl`):** Use `let` bindings in Nix. Define shared values (labels, selectors, names) once in the `let` block and reference them.
- **Multiple instances of the same service:** Don't duplicate package code. Write one package with config, instantiate it multiple times in the cluster definition with different configs. Use `kix.mkEnv` when the pattern is environment-based (prod/stage/demo).
- **Ansible's `with_items` / `loop`**: use `lib.mapAttrs` or `map` to generate resources from a config attrset (`kix/packages/stable/storage-classes/` maps a typed `classes` attrset through `kix.storage.mkClasses`).

Take time to understand what Kix gives you before implementing. The right approach in Kix is often simpler than a direct translation.

## Workflow

```
1. Read the source config        →  understand what resources are needed
2. Ensure a cluster dump exists  →  cluster-dump/
3. Write the Kix package         →  kix/packages/experimental/<name>/default.nix
4. Wire into cluster definition  →  clusters/<name>.nix
5. Build + diff                  →  identify gaps
6. Iterate until diff is clean
```

### 1. Cluster dump

A cluster dump must exist at `cluster-dump/` before diffing. If one isn't already present, ask the user to create it; do not assume you have cluster access. The user can run:

```bash
./scripts/kix-dump.py --all [--context <context>] cluster-dump/
```

This produces `cluster-dump/{namespace}/{name}-{kind}.yaml` with server-side fields stripped. Secret data is removed. Ephemeral resources (pods, replicasets, jobs, events, etc.) are excluded automatically.

### 2. Build + Diff

```bash
./scripts/kix-manifests.sh . <name> ./result
./scripts/compare-cluster-dump.py ./result ./cluster-dump/
```

The diff report shows: identical, modified (with JSON-path diffs), kix-only, cluster-only, and probable renames.

### 3. Iterate

Focus on the **Modified** section. Each entry shows exactly which fields differ and where. Common patterns:

- **Config values differ** (image tags, replica counts, resource limits) → update `options` defaults or cluster config overrides
- **Naming mismatch** → adjust resource names in the package to match what's deployed
- **Extra labels/annotations on cluster side** → usually harmless (operator-injected), ignore via `--ignore-path`
- **Missing fields in Kix** → add them to the package

## Package Anatomy

A function `{ scope, lib, kix, availability }: ...` that returns `{ meta?, options?, config?, deps?, build }`. The lib passes only the arguments the function names, so leave out `availability` when nothing maps it. **Dependencies are declared as build function args**, not package function args. Built-in packages (`packages.<name>` and `packages.experimental.<name>`) are callable attribute sets that also carry `id` (such as `"harbor"` or `"experimental/coredns"`), which Kix writes to `spec.package` on the instance's `PackageInstance`. Because `builtins.isFunction` and `builtins.functionArgs` reject callable attribute sets, call packages with `eval.callPackagePhase1 { package; scope; }` in tests and inspect or call them via `kix/lib/core/package.nix` in library code. Kix evaluates Nix expressions in its local store and writes files with `builtins.toFile` (and renders Helm charts via `scope.helm.*`), but cannot run Nix derivation builds (`pkgs.runCommand`, `pkgs.writeText`, `pkgs.stdenv.mkDerivation`).

```nix
{ scope, lib, kix, availability }:
let
  name = scope.instanceName;
  requiredExtensions = [ "vchord" "cube" ];
in
{
  # Optional: package metadata. See "Package Meta" below for all fields.
  meta = {
    description = "My package";
    owner = "app-team";       # "platform" | "app-team"
    version = "1.0.0";        # the upstream release the package deploys
  };

  # Optional: per-dep diagnostics (assertions/warnings co-located with the dep).
  # A message starts with the constraint; the lib prefixes the instance.
  deps = {
    database.config.extensions = requiredExtensions;   # injected into the provider
    database.assertions = dep:
      let missing = lib.subtractLists (dep.out.extensions or [ ]) requiredExtensions;
      in lib.optional (dep.out ? extensions && missing != [ ]) {
        assertion = false;
        message = "the database needs the postgres extensions ${lib.concatStringsSep ", " missing}";
      };
  };

  options = {
    # One kix.options.image per image the package runs (sidecars and init
    # containers included), so a pin can supply a digest for each: an
    # instance pin (`instances` in pins.json) sets one by option path, with
    # no code reading it, and `kix-image-sources.json` reports each one.
    # A `digest` given here is kept while an instance leaves `image.tag` at
    # this tag and dropped when the tag changes; other field overrides keep it.
    image = kix.options.image { repository = "docker.io/myapp/server"; tag = "1.0.0"; };
    # An image from the same release: its tag follows `image.tag` through
    # `config` below. `tagText` is what the option reference shows as the default.
    # Declare both tags from one `let` binding (e.g. `release = "1.0.0";`) so a
    # bump cannot leave the follower's declared tag, and its digest, behind.
    worker.image = kix.options.image {
      repository = "docker.io/myapp/worker";
      tag = "1.0.0";
      tagText = "config.image.tag";
    };
    # Only on a workload whose count serves load; a leader-elected controller
    # takes its count from the instance's availability and has no option.
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; };
    };
    resources = kix.options.resources { requests = { cpu = "100m"; memory = "128Mi"; }; };
    env = kix.options.env;          # rendered through kix.mergeEnv below
    extraArgs = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    ingress = kix.options.ingress;  # standardized { host, annotations } options
    metrics = kix.options.monitor;  # { enabled, interval }
  };

  # Optional: the package's own config module, evaluated with `options` and the
  # instance config like a NixOS module (an attrset, or `{ config, lib, ... }:`).
  # Write lib.mkDefault: the evaluator runs it at priority 1250, below anything
  # an instance or injection sets (lib.mkDefault included) and above the
  # option's declared default. A plain value here conflicts with a plain
  # instance value.
  config = { config, ... }: {
    worker.image.tag = lib.mkDefault config.image.tag;
  };

  # build can be a function or a list of functions.
  # As a list, each entry's deps are discovered independently and results are merged.
  # This is how composable entries like kix.expose and kix.monitor work: they're
  # just functions that declare their own DI deps and return resources.
  # Two entries returning the same part name are an error.
  # Deps are build function args: required = no default, optional = ? null.
  build = [
    # self: lazy-recursive ref to this build entry's return attrset (use self.x to reference sibling resources)
    # config: this instance's evaluated options
    # clusterConfig: cluster-wide module config (clusterConfig.clusterDomain, clusterConfig.cluster.domain)
    ({ self, config, clusterConfig, database, storage, scope, kix, ... }:
    let
      healthCheck = { httpGet = { path = "/health"; port = "http"; }; periodSeconds = 10; };
    in
    {
      dataMount = kix.mount.pvc storage { mountPath = "/data"; };

      deployment =
        {
          name = "${name}-server";
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [{
              name = "server";
              image = kix.image.ref config.image;   # repository:tag@digest
              args = [ "--listen=:8080" ] ++ kix.guardArgs {
                inherit scope;
                owned."--listen" = "the Service and the probes use port 8080; remove it.";
              } config.extraArgs;
              env = kix.mkEnvVars (kix.mergeEnv {
                inherit scope;
                defaults.LOG_LEVEL = "info";
                owned = [ {
                  vars = { DB_HOST = database.out.host; DB_PORT = toString database.out.port; };
                  from = "the database dependency";
                  fix = "Wire another database with deps.database instead.";
                } ];
              } config.env);
              ports = [ (kix.port "http" 8080) ];
              resources = config.resources;
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

      # root: entry point. Resources reachable via self.* refs are auto-tracked.
      # Note root *aliases* a named part; it never constructs a resource
      # itself. See "root must alias a named part" below.
      root = self.service;
    })

    # Composable build entries declare their own DI deps:
    (kix.expose { service = "service"; })
    (kix.monitor { service = "service"; port = "http"; })
  ];
}
```

**Inline attrset package** (for test fixtures and simple inline definitions in cluster files): a plain attrset `{ build, meta?, options?, config?, deps? }`, with no function wrapper needed. Use function packages for `kix/packages/` directory files.

### `root` must alias a named part

**Every resource must live under its own key. `root` only ever points at one; it never constructs a resource itself.**

```nix
# Right
claim = scope.mkResource { apiVersion = "v1"; kind = "PersistentVolumeClaim"; ... };
root  = claim;                      # same store path → dedup'd by the manifest writer

# Wrong: renders nothing
root = scope.mkResource { apiVersion = "v1"; kind = "PersistentVolumeClaim"; ... };
```

Why: `collectResources` gathers renderable resources from the package's parts with `excludeKeys = [ "root" "meta" ]`. A resource reachable *only* through `root` is therefore never collected: the package emits its `PackageInstance` marker and nothing else. The cluster builds green and the resource simply does not exist.

Kix now throws at eval time when `root`'s store path appears under no other part, so this fails the build rather than shipping. The rule is worth knowing anyway: the error tells you at the end, the convention costs nothing at the start.

Both forms of `root` are fine as long as the resource itself is a named part:

```nix
root = self.service;                                   # bare alias
root = { resource = self.deployment; requires = [ self.sa ]; out = { ... }; };  # wrapper
```

This bit `persistent-volume-claim` (it shipped root-only and rendered no PVC), and later a package that produced zero CustomResources with no error. Both fixed by naming the part.

### Reserved part names

`secrets` and `crds` are folders (`knownFolders` in `kix/lib/eval/helpers.nix`): the view expects `secrets.<name> = ...` under them and refuses a resource assigned directly (`'secrets' must be an attrset of resources`). Call a single Secret part something else, e.g. `credentials`. An operator can keep a `crds.*` folder and still set `out.crds.<Kind>`: when `root.out` defines the folder's name, the view shows `out`, and the folder's CRDs are still emitted.

### `self` and dependency tracking

A name Kix does not render is wrapped in `kix.untrackedRef`. When something in the package creates it (a Job minting a Secret, an operator), use the attrset form `kix.untrackedRef { kind = "Secret"; name = "..."; by = self.thatJob; }`: the referrer then depends on the creator and deploy waits for the object (`ingress-nginx`'s admission Secret). Do not also list the creator in `requires`. `by` must be something that creates objects: a passive built-in kind (ConfigMap, Secret, Service, ServiceAccount, RBAC, ...) fails at eval; a Namespace is accepted (the control plane creates `kube-root-ca.crt` and the default ServiceAccount in it). When the resource that holds the reference creates the object itself (an operator mounting an optional Secret it mints: `kubevirt`, `stackgres-operator`), write `kix.untrackedRef { name = "..."; by = "self"; }`, with no `kind`; it adds no dependency or wait. In a workload the reference must set `optional = true` (a pod cannot start to create what it requires), and the audit skips the name only while that one resource carries it: do not hand a self reference to another resource through `out`; that resource names the creator with `kind` and `by` instead.

A package whose controller serves a Service `loadBalancerClass` publishes it as `out.loadBalancerClass = kix.providedLoadBalancerClass { class = "<class>"; by = self.<controller>; }`. A Service naming that value depends on the controller, skips the cluster's `loadBalancer` role check, and gets no external-ingress allowance in derived policy, so the provider must open the backend with a builder of its own (tailscale `out.mkBackendPolicy`). A class written any other way, including a string derived from the provider's value, is checked against the role.

`self` is a lazy-recursive reference to the build function's return attrset. Use `"${self.resourceName}"` to reference another resource; this creates a Nix store-path dependency that Kix tracks automatically. Build a Service with `kix.service.fromWorkload`, which reads the selector from the workload and carries the edge. Only where that would make a cycle (two components that dial each other, see `MULTI_COMPONENT.md`) write the selector from a binding the workload shares and add `requires`:

```nix
service = scope.mkResource {
  apiVersion = "v1"; kind = "Service"; name = "web";
  requires = [ self.deployment ];  # explicit dep: not reachable via string interpolation
  spec.selector = scope.selectorLabels;
  spec.ports = [{ port = 80; }];
};
```

A resource's `requires` and `root.requires` order different things. A resource's `requires` becomes its `kix.run/depends-on` annotation, so deploy applies it after the listed resources. `root.requires` extends the PackageInstance's dependencies, so consumers of the package wait for the listed resources, but nothing inside the package does. An operator that defines CRDs and watches them puts the CRDs in the controller's own `requires` (`requires = builtins.attrValues self.crds;` on the `mkDeployment` call); the scorecard rule `architecture.controllerRequiresCrds` warns when no workload depends on them. CRDs that the operator installs itself are `mkCRDRef` markers and must not go in the controller's `requires`, since the controller would wait for an object only it creates.

### Warning system

`kix check`, `kix build`, `kix plan`, and `kix deploy` show the Kix library's warnings. Among them, the structural warnings name the resource in their `object` field:
- **Redundant requires:** resource already referenced via `"${self.x}"`, no need to also list in `requires`
- **Duplicate requires:** same resource listed twice
- **Orphaned resources:** defined in the package but unreachable from `root`

A package's `warnings` function takes `{ config, self, deps, clusterConfig }` and returns a list of strings or attribute sets with the fields of `scope.fail` (`message`, `fix`, `object`, `option`, `dependency`, `clusterOption`, `id`). Return warnings from `warnings`; Kix hides `builtins.trace` and `lib.warn` output when the build succeeds.

Fix all warnings before committing.

## Kix API Reference

### scope (available in every package)

| API | Description |
|-----|-------------|
| `scope.mkResource { ... }` | Create a namespaced K8s resource that is not a workload. A Deployment, StatefulSet, DaemonSet, or Job through it is an eval error: only the typed builders below seal a workload (validators, derived spread and PDB, netpol edges) |
| `scope.mkClusterResource { ... }` | Create a resource of a cluster-scoped kind (a namespaced kind here fails the eval) |
| `scope.mkDeployment` | Create a Deployment: auto-sets apiVersion/kind, copies `selector.matchLabels` to template labels |
| `scope.mkStatefulSet` | Same as mkDeployment but for StatefulSets |
| `scope.mkDaemonSet` | Same as mkDeployment but for DaemonSets |
| `scope.mkJob` | Same for Jobs; the selector may be omitted (template labels are used). Never set `spec.ttlSecondsAfterFinished` (the build refuses it): a finished Job stays until a later build drops it and prune deletes it. Give every Job a fixed name. `scope.mkJob` adds `kix.run/rerun: on-change` automatically because Kubernetes rejects changes to an existing Job's pod template. Do not set that annotation yourself. Kix reruns the Job when its own manifest changes or when a Kix-built Secret or ConfigMap referenced by the pod through `out` changes (the Kix library includes those reads in `kix.run/rerun-hash`). Add a `checksum/<name>` pod annotation set to `out.contentHash` only for resources the Job reaches over the network or the Kubernetes API, and make every step safe to run twice. Never put a hash of the content in the name: a renamed Job is a removed object plus an added one, and the old Job stays until it is pruned |
| `scope.selectorLabels` | Default selector labels for this instance. Overridable per-instance via `selectorLabels` in cluster config. |
| `scope.mkSecret`, `scope.mkSecretRef` | Secret primitives with enriched `out` API. **Read `SECRETS.md` for the full API, gotchas, and usage patterns.** |
| `scope.forNamespace nsName` | Get a scope for a different namespace (cross-namespace resources) |
| `scope.rbac` | RBAC DSL. **Read `docs/src/content/docs/reference/secrets-crds-and-rbac.mdx` (`#rbac-helpers`)** (`kix/lib/vocab/rbac.nix`) for the full API (`group`, `core`, intents like `watch`/`reconcile`/`own`/`full`, `grant`, `mkClusterRoleSet`/`mkRoleSet`). An operator whose upstream ships its RBAC vendors it instead (`kix/packages/stable/<pkg>/rbac/`, crd-vendoring skill) and passes each file's `rules` to `mkClusterRoleSet`/`mkRoleSet` (kubevirt, cdi). |
| `scope.mkCRD`, `scope.mkCRDRef`, `scope.mkCR` | CRD resource builders. A package that wraps an upstream operator vendors the real CRDs under `<pkg>/crds/` from the URLs in `crds/sources.txt` and loads each with `scope.mkCRD { spec = (builtins.fromJSON (builtins.readFile ./crds/<name>.json)).spec; }`; use the `crd-vendoring` skill for that. `fromKind \|> clusterScoped \|> ...` (`kix/lib/vocab/crd.nix`) builds stubs for kinds Kix invents. |
| `scope.instanceName` | The instance name from the cluster definition |
| `scope.namespaceName` | The namespace this instance lives in |
| `scope.namespace` | The Namespace resource itself (for deps) |

Workload constructors (`mkDeployment`, `mkStatefulSet`, `mkDaemonSet`, `mkJob`) are pipe-friendly: use them at the end of a `|>` chain. They auto-set `apiVersion`/`kind` and use `spec.selector.matchLabels` as the pod labels when the template sets none; a template that sets labels must include the selector's (`scope.selectorLabels // { ... }`). The `name` field is required. They are the only way to build a workload: `scope.mkResource { kind = "Deployment"; ... }` is refused at eval, because a workload that skips `sealWorkload` gets no pod-spec validation, no derived spread or PodDisruptionBudget, and no network-policy edges. Inside `spec.template.spec` write `serviceAccount = self.sa;` (not `serviceAccountName`), and in a StatefulSet `headlessService = self.svc;` (not `serviceName`).

### mkResource / mkClusterResource fields

`ownership.cede = [ "spec.versions" "webhooks[*].rules" ]` names fields an operator takes over after creation (also on `scope.mkCRD`): deploy applies without them when a 409 is confined to those paths, and fails any other conflict. cdi uses it; never reach for `--force-conflicts` in a package. When the operator writes every entry of an object (StackGres's webhook configurations), render the object as metadata only and order the operator after it instead of ceding.

A CRD an operator installs at runtime is a `scope.mkCRDRef { group; kind; plural; version = "<served version>"; installedBy = self.operatorDeployment; }`; CRs of that kind are built with `scope.mkCR self.thatRef { ... }` (mayastor DiskPool). Read the served version off the operator's CRD (`kubectl get crd <plural>.<group> -o jsonpath='{.spec.versions[?(@.served==true)].name}'`); there is no default, and a missing `version` fails the build. Every CR must depend on its declaration; `scope.mkCR` adds it, and a raw `scope.mkResource` with a custom `apiVersion` fails cross-resource check 21. When a CR's readiness depends on its spec (a VirtualMachine is Running or Stopped by its runStrategy), declare no readiness on the marker and pass `readiness` to `scope.mkCR` per CR in an `out.mk<Kind>` builder that refuses specs a deploy cannot wait on (kubevirt `out.mkVirtualMachine`, cdi `out.mkDataVolume`). The CR's `readiness` replaces the kind's and is validated like it.

| Field | Description |
|-------|-------------|
| `apiVersion` | Required. e.g. `"apps/v1"` |
| `kind` | Required. e.g. `"Deployment"` |
| `name` | Required. Resource name |
| `spec` | Resource spec (most resources) |
| `data` | For ConfigMaps |
| `stringData` | For Secrets (prefer `scope.mkSecret`; see `SECRETS.md`) |
| `labels` | Merged into `metadata.labels` (cluster labels + managed-by added automatically) |
| `annotations` | Merged into `metadata.annotations` |
| `extra` | Top-level fields merged outside metadata (e.g. `rules` for ClusterRole, `type` for Secrets) |
| `outputs` | Named values with dependency context. `name`, `fqdn`, `identityHash`, `contentHash`, `selector` are auto-derived. |
| `requires` | Resources that must exist but aren't referenced via `"${self.x}"` |
| `extraDeps` | Additional dependency edges that don't fit `requires` or string interpolation |

### Resource outputs

Every resource exposes:
- `"${resource}"`: the resource name (string interpolation creates a dependency edge)
- `resource.out.name`: the resource name as a string (with dependency context)
- `resource.out.selector`: the resource's labels (for ServiceMonitor selectors etc.)
- `resource.out.fqdn`: full DNS name (`my-svc.my-ns.svc.<clusterDomain>`), suffix from the `clusterDomain` cluster option. Never write `cluster.local`: package-eval scans package sources, and `architecture.clusterDomainLiteral` fails a build on another domain.
- `resource.out.<key>`: named outputs from the `outputs` field, with dependency context

**Naming vs. dialing (typed facts).** Address-shaped outputs (`out.fqdn`,
`out.url`, `outputs.*`) additionally carry an *endpoint fact*: using them in a
workload means "my pods dial this Service", which is what derives the netpol
edge and DNS ordering. `out.name` is structural: it creates the dependency
edge but NO netpol hole. Consequences when authoring:

- To **connect** to a Service, wire `out.fqdn`/`out.url` into the workload
  (directly or via a ConfigMap/Secret: the fact conducts through carriers,
  so indirection works).
- Referencing a Service's identity without any address flowing produces a
  lint (`workload references Service X by identity but no address value
  flowed`). If the use is genuinely structural (label, display string), wrap
  it: `kix.facts.refOnly svc.out.fqdn`.
- Dialing by bare `out.name` (intra-namespace short name) will NOT open a
  netpol hole; use `out.fqdn`, or stamp intent with
  `kix.facts.connect svc.factTokens.endpoint value`.
- A producer that exposes a fact about itself rather than an address (a
  replica count, the scrape job label its operator will give it) wraps it:
  `outputs.replicas = kix.facts.structural (toString n);`. Consumers read
  `out.replicas` and get the ordering edge with no dial claim and no
  `refOnly` at the use site. The VictoriaMetrics operator's `mkVMAgent`,
  `mkVMAlert`, and `mkVMAlertmanager` state `out.scrapeJob` and
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
  CR). The declaration rides the typed builder chain: consumers building
  CRs via `scope.mkCR owner.out.crds.<kind>` get it automatically:

  ```nix
  # in the CRD-owning package (mkCRD works the same way)
  crdRef = scope.mkCRDRef {
    group = "my.io"; kind = "MyCluster"; plural = "myclusters"; version = "v1";
    factBehavior = {
      endpoint = "terminate";          # controller dials; "conduct" = CR merely carries
      podSelector = cr: { "my.io/cluster" = cr.metadata.name; };  # the OPERAND pods
    };
  };
  ```

  netpol then opens egress for the operand pods + caller-ingress into the
  target namespace. An operator that creates scrape objects for its own
  operands (the VictoriaMetrics operator's VMServiceScrapes) declares
  `factBehavior.selfScrapes = cr: [ { kind; name; labels; podSelector; ports; } ]`,
  and the scrape join opens them for the scrapers that select them. Undeclared CR kinds absorbing an endpoint fact warn at
  eval time (conduct is assumed). For CRs not built via the typed builder
  (helm-rendered, raw kind strings), or to fix a broken upstream
  declaration, cluster operators set
  `cluster.factBehavior."<group>/<Kind>"` (it wins over CRD declarations).

- **Readiness rides the same chain.** If the operator never stamps
  Ready/Available conditions, declare its health convention on the CRD
  builder (mkCRD and mkCRDRef both accept it). Two shapes: `readiness =
  { path = "/status/updateStatus"; equals = "operational"; }` compares one
  status field with a string (`victoria-metrics-operator/crds.nix`);
  `readiness = { condition = { type = "Bootstrapped"; status = "True"; }; }`
  looks for that entry in `status.conditions` (`stackgres-operator`,
  `gateway-api`, `cilium/netpol-rules.nix`). Kix stamps the
  declaration on every typed-chain CR as the `kix.run/readiness`
  annotation and `kix deploy` evaluates it instead of the generic
  condition check. The CLI keeps no per-operator kind list: a new
  operator's convention goes in its package, never in `readiness.rs`.
  Without a declaration, deploys time out waiting on healthy CRs.

  If the operator's admission webhook refuses its own kinds until it is
  ready (cert-manager's `failurePolicy: Fail` webhook before cainjector
  injects the CA), set `crRequires = [ self.apiCheck ];` on each
  `scope.mkCRD` or `scope.mkCRDRef` call so every custom resource of that kind
  waits for the operator's API-check Job. See
  `kix/packages/experimental/cert-manager/crds.nix`. Do the same when the
  operator writes its webhook entries after it reports ready:
  a CRD reference is satisfied once the definition is Established, which
  can be seconds before the webhook admits anything
  (`stackgres-operator`, `webhookCheck`), or before the operator has
  written the caBundle into configurations Kix rendered (`cnpg-operator`).
  A boolean or number status field compares by its JSON text:
  `readiness = { path = "/status/applied"; equals = "true"; }`
  (`cnpg-operator` for Database and DatabaseRole). A resource whose status
  only a consumer writes, and which may have no consumer, declares
  `readiness = { path = "/status/updateStatus"; notEquals = "failed"; }`:
  ready while the field is absent or holds another value
  (`victoria-metrics-operator` for VMServiceScrape, VMRule, and the other
  configuration kinds). No form trusts a
  status older than the spec: a path rule also waits for
  `status.observedGeneration`, and a condition rule for the condition's
  own `observedGeneration` (or `status.observedGeneration` when the
  condition has none, as with RabbitMQ's `AllReplicasReady`), to reach
  `metadata.generation` when the operator reports it. An operator that reports neither (CloudNativePG's
  Cluster) can still read as ready from its previous status right after
  a spec change. When the operator reports the generation it has acted
  on in another field, or gives `status.observedGeneration` another
  meaning, name the field: `observedGeneration =
  "/status/desiredGeneration"` beside the ready rule (KubeVirt's
  VirtualMachine reports in `status.observedGeneration` the generation its
  running guest started from, which lags after every edit until a
  restart). Kix waits while a declared field is absent.
  `observedGeneration = false` says the kind reports none, and is the safe
  declaration for a stopped VirtualMachine, whose
  `status.observedGeneration` stops advancing. The ready rule, `failed`,
  and `pendingRestart` all use the declared field.

  When the operator accepts a spec change but keeps the running workload
  on the previous spec until a restart, and reports that, declare the
  state in `pendingRestart`: `{ condition = { type = "RestartRequired";
  status = "True"; }; hint = "<how to restart>"; }`, or `{ path; equals;
  hint ?; message ?; }`. Once the resource is ready and current, `kix
  deploy` reports it as ready with a restart pending and goes on, as it
  does for an `OnDelete` DaemonSet.

  When the operator reports that it rejects a resource, and that verdict
  stands until the spec changes, list the state in `failed` beside the
  ready rule so `kix deploy` fails the resource at once instead of at the
  timeout: `readiness = { condition = { type = "Valid"; status = "True"; };
  failed = [ { condition = { type = "Valid"; status = "False"; }; } ]; }`
  (`cilium/netpol-rules.nix`). An entry is a condition with an optional
  `reason` (matched only when declared) or `{ path; equals; }` for a phase
  field, with `rejected = true` when the phase is a verdict on the spec,
  `message` (a JSON pointer or list) naming status fields to quote, and
  `hint` with the next step for a runtime outcome such as a failed backup
  (`velero/workloads.nix`, `cdi/default.nix`). Declare only verified
  permanent states: a `Ready=False` the operator retries (cert-manager,
  external-secrets) or a `Pending` is not one, and neither is a phase with
  no generation and no timestamp that a restarting controller may leave
  stale (ARC `Outdated`). The CLI trusts the match once the condition's `observedGeneration`
  (or the declared generation field) has reached `metadata.generation`;
  without a generation, once the condition's `lastTransitionTime` is later
  than this deploy's apply of the object (Cilium writes neither generation,
  so this is the check its policies get); and with neither field, once the
  state has held for ten seconds (phase fields such as Velero's and ARC's).
  So a stale status right after an apply does not fail a deploy that fixed
  the problem. The annotation gains a `"failed"` list; an older CLI ignores
  it. Declared today: cilium (`Valid=False`), velero Backup and Restore
  (`FailedValidation`, `Failed`, `PartiallyFailed`) and Schedule
  (`FailedValidation`), cdi DataVolume (`Failed`, in `out.mkDataVolume`).

- **Declare `usesAtLeast` on CRDs whose operator always runs pods or makes claims.** On `scope.mkCRD`
  or `scope.mkCRDRef`, return the least the operator always uses for a custom resource, keyed like a
  ResourceQuota's `spec.hard`. Build it with `kix.usage`:
  `usesAtLeast = cr: kix.usage.times (cr.spec.instances or 1) (kix.usage.ofPod [ { resources = cr.spec.resources or { }; } ])`.
  Add `persistentvolumeclaims`, `requests.storage`, or `services` with `kix.usage.add` when the
  operator always makes them (see `cnpg-operator` for `Cluster`). Count every container the operator
  always runs and whose size the custom resource sets; leave out anything the operator sizes itself.
  A figure that is too high fails a valid build, so when unsure, leave a key out. A quota failure
  lists every custom resource whose kind has no `usesAtLeast` under `Not counted`, grouped by kind.
  Declare `usesAtLeast = _: { }` on a kind whose objects run no pods (rules, certificates, policies)
  to drop it from that list.

- **Declare `holdsData` on every CRD.** On `scope.mkCRD` or `scope.mkCRDRef`, `holdsData = true`
  when deleting a custom resource of the kind loses data (CNPG `Cluster`, `SGCluster`, mayastor's
  `DiskPool`), `false` for monitoring, certificate, policy, and configuration kinds. Each custom
  resource carries it as `kix.run/holds-data`, and `kix plan`, `kix diff`, and `kix deploy` read it to tell a data
  migration from an object swap that moves none. A package with `meta.lifecycle = "stateful"` fails
  to build when it renders a custom resource without it, including one built with `scope.mkResource`
  instead of `scope.mkCR`. Built-in kinds need nothing: a PersistentVolumeClaim, a PersistentVolume,
  and a StatefulSet with `volumeClaimTemplates` are marked `"true"` from their shape, and
  `holdsData` for a built-in group (`kix/lib/core/api-groups.json`, which includes every `*.k8s.io`
  group) is refused. `scope.mkResource` and `scope.mkCR` refuse a per-object `holdsData`.

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

**`kix.expose`**: composable build entry. Auto-detects whether the cluster uses Gateway API or Ingress:
- `gateway` DI dep present → emits `HTTPRoute`
- `ingressNginx` DI dep present → emits `Ingress` with optional TLS
- Neither present → no exposure resource

Parameters: `service` (string key in self) or `paths` (a list of `{ path, pathType?, service, port? }` for several backends behind one host, rendered as an Ingress with a rule per path or one HTTPRoute with a rule per path), `partName` (default `"route"`), `exposurePart` (default `"exposure"`), `defaultAnnotations` (Ingress only), `port`, `timeouts` (HTTPRoute only), `deriveHost` (default `true`: a null `ingress.host` becomes `<instance>.<cluster.domain>`; `false` routes the instance only when `ingress.host` is set, for a package such as Grafana that must not be public by default). Read the public URL as `self.exposure.url`, which fails evaluation when Kix cannot derive one (no route, no host, or a Gateway without `out.listeners`); a package that works without a URL reads `self.exposure.urlOrNull` and handles null. Never re-derive it from `ingress.host`. Build for Gateway API first: Ingress stays supported, but every cluster is moving off it.

Use `options.ingress = kix.options.ingress;` for standardized `{ host, annotations }` options.

For routing `paths` cannot express, build HTTPRoute/Ingress manually via `kix.httpRoute.fromService` / `kix.httpRoute.fromPaths` / `kix.ingress.fromService` or raw `scope.mkResource`.

**`kix.monitor`**: composable build entry. Creates ServiceMonitor + optional PrometheusRule when `prometheus` DI dep is present, emits nothing otherwise.

Parameters: `service` (string key in self), `port` (default "metrics"), `path` (default "/metrics"), `scheme` (default "http"), `tlsConfig`, and `params` (query parameters; both default none), which set the primary endpoint's, `alerts` (attrset of alert definitions), `extraEndpoints` (each defaults to `scheme = "http"`, `path = "/metrics"`, and the instance's `metrics.interval`), `extraLabels`. A package with several metrics Services calls it once per Service and sets `name` (resource name, default the instance name), `monitorPart`, and `rulesPart` (part names, default `serviceMonitor` / `prometheusRules`) so the entries do not collide; `kix/packages/stable/harbor/` does this four times.

Under network policy a monitor needs nothing more from the package: the netpol plugin derives the Prometheus server's egress to each target it selects and the target's ingress from the server (`docs/src/content/docs/explanation/network-policy.mdx` `#how-kix-discovers-connections-from-endpoint-facts`), for `kix.monitor` and direct `mkServiceMonitor`/`mkPodMonitor` alike. Do not open a metrics port with an intent. A PodMonitor over operator-created pods must give its port as a number (`portNumber`, as stackgres-cluster and arc do): Kix cannot resolve a name no Kix workload declares, and egress needs the number. Select PodMonitor pods with `matchLabels`. Under default deny a named port of that kind or a `matchExpressions` selector fails evaluation; without default deny it is a warning and no policy.

**`kix.alerts`** renders the PrometheusRule alone, with the same `alerts` shape and conditions, for a package that scrapes through `prometheus.out.mkPodMonitor` or an operator; its alerts select `job="<ns>/<PodMonitor name>"`, since PodMonitor series have no `service` label. For thresholds, `kix.types.promDuration` types a duration option, `kix.durations.toSeconds`/`fromSeconds` convert it, and `kix.schedules.staleAfter <cron line>` gives a last-success alert's default age (two periods plus two hours, null when unreadable) instead of a per-package parser. For a controller-runtime operator, define the reconcile alert with `kix.reconcileErrorsAlert { selector; by ? ["namespace" "service"]; operator; summary; impact; nextStep; }`. It fires only when a controller's 30-minute failure rate exceeds 10% (with at least three errors) for 15 minutes, so occasional conflict retries do not trigger it.

Use `options.metrics = kix.options.monitor;` for standardized metrics options (`enabled`, `interval`). Alerts select the instance's own targets with `namespace="<ns>",service="<Service name>"`; `alerts` is a static set, so bind the Service name once in the `let` and read it in both the Service and the alerts. Which alerts to write, and the patterns that keep `namespace` on every alert, are in `docs/src/content/docs/reference/composition-helpers.mdx` (`#monitor`) and the `package-review` skill (Mo14 to Mo23).

**`kix.healthCheck`**: composable build entry. Renders a post-deploy probe Job (plus a ConfigMap holding the script) that runs after the things it checks are ready; a failing probe fails the deploy. Addresses come in as env vars from `out.*` values, which is what gives the Job its dependency edges and netpol egress.

Parameters, every callback taking `{ self, config, deps }` (`deps` is every DI package some other entry of the package declares): `script` (usually `builtins.readFile ./health-check.py`), `env` (`-> attrset`; the helper adds `RETRY_FOR`), `when` (`-> bool`, default `config.healthCheck.enabled or true`), `retryFor` (`-> int`, default `config.healthCheck.retryFor or 90`), `requires` (`-> [ resources ]`, on top of the package root, which the Job always waits for), `partName`, `runtime` (`kix.healthCheck.runtimes.python` by default, `runtimes.shell` on curl, or your own `{ image = { repository; tag; digest; }; file; interpreter; env; }`), `activeDeadlineSeconds` (null: `retryFor` plus `kix.healthCheck.roundBudget`, 90 s; a given value must leave that room or the build fails). Declare `options.healthCheck = kix.options.healthCheck;` (`enabled`, `retryFor`) and the defaults read it.

The script gives up once `RETRY_FOR` seconds have passed and keeps one round of checks under the round budget. It reads what it expects off resources (`self.vmAgent.out.replicas`, a structural output), never off the option that produced them. The Job carries `kix.run/rerun: on-change` (`kix/lib/core/annotations.nix`): the deploy engine recreates it when its own content changed or the last run failed. `kix.run/rerun-hash` covers the script and any Kix-built Secrets or ConfigMaps referenced in `env`, while `kix.healthCheck` adds `checksum/*` annotations on the pod template for `self.root` and each resource in `requires`. Changing any of these reruns the probe. Keep the script a file next to `default.nix` so it can be linted and run from a laptop through `kubectl proxy`. Example: `kix/packages/stable/victoria-metrics-agent/`. A probe that must log in takes the credential the same way a container does: `env = { self, ... }: { CLICKHOUSE_PASSWORD = self.credentials.out.keyRef "password"; ... }` (see `SECRETS.md`). Example: `kix/packages/experimental/clickhouse/`.

**Cluster-side wiring:**
- Gateway API: instantiate `kix/packages/experimental/gateway-api` (provides the Gateway API CRDs for the `gatewayApi` role) alongside `kix/packages/experimental/traefik` or `kix/packages/experimental/envoy-gateway` (both answer the `"gateway"` alias and implement `kix.contracts.gateway` in `kix/contracts/stable/gateway.nix`). `envoy-gateway` also requires one `kix/packages/experimental/envoy-gateway-controller` instance in the cluster. Each `envoy-gateway` instance creates one `Gateway`; to run more than one, set `aliases = [ ]` on the extra instances so only one keeps `"gateway"`.
- Ingress: instantiate `kix/packages/experimental/ingress-nginx` with alias `"ingressNginx"`

#### Utility helpers

| Function | Description |
|----------|-------------|
| `kix.port name containerPort` | `→ { name, containerPort, protocol = "TCP" }` |
| `kix.mkEnvVars { KEY = "val"; OPT = null; }` | `→ [{ name, value }]`. Nulls filtered. A value that is a `valueFrom` source (`secret.out.keyRef "password"`) renders as one, with the env name winning; any other attrset throws. |
| `kix.mkEnv { KEY = "val"; } [ rawEntries ]` | Combine named env vars with raw K8s env entries (e.g. `valueFrom.secretKeyRef`). |
| `kix.mergeGuarded { scope; locked; option ? "extraSpec"; object ? null; } base overrides` | Merges `overrides` into `base` with `lib.recursiveUpdate`, failing if `overrides` sets a path in `locked` (a list of attribute paths the package computes) or replaces an ancestor of one with a non-attribute-set value such as `null`. Use it for every `extraSpec` and `settings` option. `option` names the instance option in errors (set `option = null` when `overrides` comes from a function argument such as an `out` builder). Pass `object` (`{ kind; name; namespace ? null; }`) to name the target Kubernetes resource when `option` configures several resources or `option` is `null`. |
| `kix.mergeEnv { scope; option ? "env"; defaults ? { }; owned ? [ ]; } config.env` | Builds the environment attribute set for `kix.mkEnvVars` by merging `defaults`, the instance's `env`, and package-owned variables. Pass every `env` option through it, and set `option` when the option path is not `"env"` (for example, `"runners.env"`). Each `owned` entry is `{ vars ? { }; names ? [ ]; from; fix ? null; }` for variables the package sets, or `{ names; reason; fix ? null; }` for variables it rejects outright. If `env` sets a claimed variable, evaluation fails with `from` (or `reason`) and `fix` (which defaults to removing the variable from `option`). |
| `kix.guardArgs { scope; option ? "extraArgs"; parser ? "gnu"; owned ? { }; ownedFamilies ? { }; defaults ? null; id ? null; } config.extraArgs` | Fails if `extraArgs` sets a disallowed flag; otherwise returns `defaults` (omitting any flag `extraArgs` overrides) followed by `extraArgs`, or merged under `extraArgs` when both are attribute sets. `parser` sets how the program parses flags: `"gnu"` (default) matches `--flag`, `--flag=value`, or a single-letter `-f` with an attached value; `"go"` (Go's `flag` package) treats `-flag` and `--flag` as the same flag; `"paerser"` (Traefik) matches like `"go"` and ignores letter case. Attribute-set keys (such as a VictoriaMetrics CR's `extraArgs`) match with or without leading dashes. `owned."--flag"` maps each disallowed flag to the reason and fix shown after `which this package does not accept:`, and `ownedFamilies."--flag"` does the same for `--flag` and any `--flag.<name>` sub-flag. Pass `defaults` (same type as `extraArgs`) for programs that reject duplicate flags; in a list, write each flag and its value as one string, such as `"--flag=value"`. Set `id` to a change record ID (such as `"K4740"`) when a package starts rejecting a flag or flag spelling it previously accepted. |
| `kix.contracts.secret.helpers.use { scope; arg; dep; keys ? [ ]; anyOf ? null; }` | Returns the secret dep after checking that it is a secret (`kix.contracts.secret`) and declares the keys; read the secret through the returned value so the check runs before any `keyRef` throws. `kix.checkSecretKeys` takes the same arguments and checks the keys only. |
| `kix.operandPolicy { scope; name; spec; }` | A network policy over pods an operator creates (`spec` in the enforcer's format). Drops the `ingress`/`egress` sections of a direction `networkPolicy.directions` does not enforce; null when no enforcer runs or no section is left, so filter nulls before `root.requires`. |
| `kix.parseQuantity "memory" "512Mi"` | `→ 536870912` (bytes; millicores for `"cpu"`); null when not a quantity; an integer, and a value above the signed 64-bit range throws. |

A port name is unique per pod in Kubernetes, but `architecture.consistentPortNames` asks for one meaning per instance: if a package's main workload calls 5678 `http`, its worker's own port needs a different name (`health`, `metrics`), not the same one on another number. Resolvers that are handed a name without a workload cannot tell the two apart.

#### Writing one of Kix's own annotations

Kix stamps its own keys under a domain it owns. **Never spell that domain in a
package.** Use `kix.keys.<name>`, which comes from `kix/lib/core/annotations.nix`:

```nix
annotations.${kix.keys.operandOf} = "monitoring.coreos.com/Prometheus/${name}";
labels.${kix.keys.derived} = "true";
```

Common names: `operandOf`, `monitorsExternalService`, `derived`,
`policyType`, `role`, `dbCluster`, `sopsSource`. The full set
is the `keys` attribute in `kix/lib/core/annotations.nix`.

The domain is spelled exactly once per language, there and in
`cli/kix-core/src/manifest/keys.rs`. A test fails the build if any other file in
`kix/` or `cli/` puts a Kix domain in a string literal, so a package that
hardcodes one will not merge. A package that needs these takes `kix` as an
argument.

### Top-level Kix functions

| Function | When to use | Description |
|----------|-------------|-------------|
| `kix.buildCluster { ... }` | Every cluster definition. | Takes `modules`, optional `specialArgs`, and `name`, which `mkFlake` defaults to the cluster's `clusters` key (a direct call must pass it). Returns `{ activation, instances, namespaces, rawManifests }`. |
| `kix.mkEnv envName envConfig instanceSets` | Same services in multiple environments. | Stamps instance sets into `{envName}-{setName}` namespaces with per-env config overrides. |
| `kix.mergeFragments { fragments; namespacePolicies; }` | Multiple teams own different parts of a cluster. | Deep-merges namespaces, detects instance collisions across fragments. |
| `kix.helmChart { repo; name; version; hash; }` | **Tier 1:** inline Helm chart in cluster definitions. | Quick one-off, no package file needed. Auto-selects root (pass `root = { kind; name; }` when the chart has several Services or workloads), exposes `config.values`. |
| `scope.helm.importChart { chart; scope; values; ... }` | **Tier 2:** inside a package's `build` function. | Full control. Returns resource collection: `get kind name`, `find kind predicate`, `byKind kind`, `workloads`, `mkParts { root }`. |
| `scope.helm.fetchHelmChart { repo; name; version; hash; }` | Inside packages. | Fetches and pins a Helm chart by content hash. |
| `kix.mkImport { from?; out?; kind?; apiVersion?; roles?; crds?; scope?; }` | Resource exists in cluster but not managed by Kix. | Import marker for DI. DI resolution prefers managed instances over imports. `scope` defaults to `"cluster"`, so every namespace resolves to the import by name (a managed package with `meta.scope` unset needs a `ref`); set `"namespace"` to keep it to its own namespace, and name one of several imports with `ref`. `out` may hold `ref.<ns>.<instance>` at any depth of plain attribute sets: Kix swaps in that instance and the marker waits for it (`credentials = ref.app.db-login` for RDS or a mail provider; the secret must be in the consumer's namespace, so such an import sets `scope = "namespace"` and sits beside it). `crds` lists the environment's CRDs as `scope.mkCRDRef` arguments (no `installedBy`); each becomes `out.crds.<Kind>`, as on a managed operator package. |

### Useful `lib` functions for packages

| Function | Use case |
|----------|----------|
| `lib.optionalAttrs condition { ... }` | Conditionally include an attrset |
| `lib.optional condition value` | Conditionally include a list element |
| `lib.optionals condition list` | Conditionally include multiple list elements |
| `lib.mapAttrs fn attrset` | Transform attrset values (e.g. generate resources from a config map) |
| `lib.filterAttrs predicate attrset` | Filter attrset entries |
| `lib.recursiveUpdate base overlay` | Deep-merge two attrsets |
| `lib.id` | Identity function: useful as no-op in conditional pipes: `\|> (if cond then transform else lib.id)` |

## Cluster Definition

Cluster definitions can be **single-file** (one `{ kix, packages }:` function calling `kix.buildCluster` with a single module) or **module-based** (split into NixOS-style modules in `clusters/<name>/`).

### Module-based (production clusters)

Each module file receives `{ config, lib, ref, packages, ... }` and can declare `options` and set `config.instances`.

A package is stable or experimental. `packages.<name>` and `packages.stable.<name>` both name the stable package in `kix/packages/stable/<name>/`. `packages.experimental.<name>` names the package in `kix/packages/experimental/<name>/`, which may break in any release, where a stable package breaks only in a minor release. An experimental package may share a stable package's name, as a rework of it. Once a package graduates, `packages.experimental.<name>` fails with an error that says to write `packages.<name>`. New packages start experimental. `availablePackages = packages` offers stable packages only; add experimental ones by name (`packages // { inherit (packages.experimental) cert-manager; }`). The monitoring module is `kix.modules.experimental.monitoring`.

```nix
# clusters/<name>/platform.nix: sets cluster-wide options
{ config, lib, ref, packages, ... }:
{
  config.cluster.domain = "example.com";   # public base domain kix.expose builds hosts from
  config.instances.kube-system = {
    ingress-nginx = { package = packages.experimental.ingress-nginx; };
  };
}
```

```nix
# clusters/<name>/harbor.nix: uses cluster options, defines instances
{ config, packages, ... }:
{
  config.instances.harbor-system = {
    harbor = {
      package = packages.harbor;
      config.ingress.host = "harbor.${config.cluster.domain}";   # EXT_ENDPOINT follows the route
    };
    harbor-secrets = {
      package = packages.secret;
      aliases = [ "harborSecrets" ];
      config = { source = ./harbor.sops.yaml; keys = [ "adminPassword" "secretKey" "coreSecret"
        "jobserviceSecret" "csrfKey" "registryHttpSecret" "registryPassword" "tokenPrivateKey" ]; };
    };
    harbor-registry = { package = packages.persistent-volume-claim; config.size = "100Gi"; };   # answers `storage`
    harbor-valkey.package = packages.valkey;                                                    # answers `redis`
    valkey-password = { package = packages.secret; aliases = [ "valkeyPassword" ];
      config = { source = ./valkey.sops.yaml; keys = [ "password" ]; }; };
    harbor-pg.package = packages.experimental.stackgres-cluster;      # answers stackgres-database's `postgres`
    harbor-db = { package = packages.experimental.stackgres-database;  # answers harbor's `database`
      config = { database = "registry"; user = "harbor"; }; };
    harbor-db-password = { package = packages.secret; aliases = [ "password" ];   # answers stackgres-database's `password`
      config = { source = ./harbor-db.sops.yaml; keys = [ "password" ]; }; };
  };
}
```

CloudNativePG is the alternative PostgreSQL provider: `cnpg-operator` (one
per cluster), `cnpg-cluster` in place of `stackgres-cluster`, and
`cnpg-database` in place of `stackgres-database`, with the same `out` and
credentials keys, so the application package does not change
(`clusters/test-postgres-swap`). `cnpg-database` takes no `owner` or
`bootstrap.*` options: CloudNativePG creates the role and database itself,
and the role always owns the database. For backups, add a
`cnpg-barman-cloud` instance in the operator's namespace and set
`cnpg-cluster`'s `backup`, with S3 credentials as a `storageCredentials`
secret in the cluster's namespace. For PgBouncer, add a `cnpg-pooler` with
`deps.postgres` on the cluster and wire the `cnpg-database`'s
`deps.postgres` to the pooler.

To move an existing database onto a new `cnpg-cluster`, set its `import`
and wire `deps.importSource` to the old server and `deps.importPassword`
to a secret with the password of `import.user`. CloudNativePG copies the
databases once, with `pg_dump` and `pg_restore`, when the Cluster is
created, so stop writes to the old server first. A server Kix does not
manage becomes a dependency through a `service-ref` instance in its
namespace. Give `selector` the labels of its pods and `targetPort` the port
they listen on, because network policy matches those. A StackGres primary
Service sends 5432 to PgBouncer and 5433 to PostgreSQL itself, so a dump
goes to 5433, with `targetPort = 5432`. A `service-ref` makes Kix write an
ingress policy on those pods, and Kix's default-deny on its namespace, so
check what else reaches them first.

### Instance-level options

- **`aliases`**: DI resolution matches arg names to instance names, `meta.defaultAliases`, *or* instance aliases. A provider's default aliases usually suffice; to choose between two candidates, wire `deps.<arg> = ref.<ns>.<inst>` rather than adding an alias. Packages that fill an infrastructure role (`meta.roles = [ "storageClasses" ]`, validated against the registry in `kix/lib/eval/roles.nix`) get the role name as an alias automatically. An instance alias is right for a secret dep (`aliases = [ "harborSecrets" ]` on a `secret` instance) and for making a non-role package instance the role provider (`aliases = [ "storageClasses" "zfsLocalPv" ]` on a CSI driver).
- **`selectorLabels`**: override auto-generated selector labels per-instance. Use when the cluster has immutable selectors (e.g. StatefulSet).
- **`optional = true`**: instance only activates if something depends on it.
- **`partsOverlays`**: per-instance post-build transforms on the parts attrset. `globalPartsOverlays` applies to all instances. Read `kix/lib/eval/instance.nix`.

### Cluster-level options

- **`clusterDomain`**: the cluster's DNS domain (default `"cluster.local"`), the suffix of every `resource.out.fqdn`. A package that needs it reads `clusterConfig.clusterDomain`; never write `cluster.local` in a package. `cluster.domain` is the separate public base domain.
- **`availablePackages`**: package registry for auto-instantiation into `autoNamespace` when transitively required. A name two entries answer (entry name, `meta.roles`, `meta.defaultAliases`, entry `aliases`) is refused when something depends on it; select with an optional instance of that name or remove the others. A dep wired with `deps.<arg>` never pulls from the shelf; `deps.<arg> = ref.<ns>.<inst>` to an optional instance activates it. A shelf package is placed in each requesting namespace. A one-per-cluster package (a `cluster:` conflictsWith entry naming its own key, or a `meta.roles` claim) that this would place in two namespaces is refused, naming the requesters; declare it once (`instances.<ns>.<name>.package = packages.<name>;`) and every consumer resolves to it. A fixed entry `namespace` or `autoNamespace` places it once. Placed beside a single consumer with neither set, it builds with a warning that Kix 0.10 turns into an error; declare it in its own namespace. A copy placed beside a declared instance that claims the same key without answering the demanded name is refused by that instance's `conflictsWith`, which names the consumers the copy was auto-instantiated for. Two instances that render the same cluster-scoped object (a CRD, a ClusterRole) fail evaluation, naming both.
- **`namespaces`**: per-namespace `labels`, `annotations`, `resourceQuota`, `networkPolicies` (directions, defaultDeny).
- **`cluster.roles`**: binding modes for environment-owned roles (`cni`, `dns`, `storageClasses`, `loadBalancer`, `network-policy-enforcer`, `snapshotController`, `metricsApi`, `registryMirror`): `absent` (vacant, a managed instance fills it), `shadowable` (environment default, managed instance overrides), `exclusive` (environment owns it; a managed instance claiming it is an eval error). Set by flavors; override per-cluster (e.g. `cluster.roles.cni.binding = "absent"` on kind created with `disableDefaultCNI`); an environment that installed Cilium binds `cni` as `shadowable` and declares it as a `platform-cilium` import (`kix.mkImport { roles = [ "cni" ]; out.helmChartConfig = { name; namespace; } or null; }`; on RKE2 `cluster.flavor.rke2.cni = [ "cilium" ]` declares `kube-system/platform-cilium`), and the `cilium` instance takes the import as a dependency and configures or uses that Cilium.
- **`cluster.capabilities`**: substrate axioms (`multiNode`, `privilegedContainers`, `daemonSets`, `gpu`, ...), three-valued: `null` = unknown (relying workloads warn), `false` = hard error, `true` = pass. Read `kix/lib/modules.nix` for the full list. The old role-backed bools (`cni`, `networkPolicyAPI`, `loadBalancer`, `persistentStorage`, `rwxStorage`, `volumeSnapshots`, `ingressController`) no longer exist; role providers are derived from `meta.roles`; no provider publishes rwx or snapshot facts yet.
- **`cluster.kubernetes.uid`**: the UID of the target cluster's `kube-system` Namespace (`kix status <cluster> -v`, or `kubectl get namespace kube-system -o jsonpath='{.metadata.uid}'`), a lowercase UUID. Binds the definition to that one Kubernetes cluster: the build carries it in `kix-packages.json` (`kubernetes.uid`), a deploy labels its Activation record `kix.run/kubernetes-uid`, and deploy, plan, rollback, `gc` (with or without `--full-scan`), and the operator refuse the build against any other cluster. Once a bound build has deployed, the Kubernetes cluster refuses unbound definitions too. Set it for every live cluster; several Kix clusters on one Kubernetes cluster share the value.
- **`k8sVersion`**: the Kubernetes version the package `meta.k8s.minVersion`/`maxVersion` checks run against (`"1.31"`, or a full `gitVersion` such as `"v1.31.2-gke.1209000"`). The build carries it in `kix-packages.json` (`kubernetes.version`), and `kix deploy`, `kix plan`, and the operator stop a new build when the cluster runs a different version, compared as precisely as written (`"1.31"` matches any 1.31.x); the error names the value to set. `kix rollback` and the operator's repair of a running build go ahead. Unset means no check at build or deploy time. `kix status` prints the live version.
- **`cluster.network`**: `podCidr` (cilium's chart cluster-pool IPAM pool; kind, k3s, and rke2 default it), `serviceCidr`, `dnsUpstream` (read by the coredns forward plugin; empty means `/etc/resolv.conf`). No CNI-specific field: an environment's Cilium is the `platform-cilium` import.
- **`cluster.availability`**: `none | pod | node | zone`, the largest failure a workload must survive; derived from the capabilities when unset, capped by them, overridable with `instances.<ns>.<inst>.availability`. Every package takes an `availability` argument and maps it in every replica-shaped default: `default = kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; }` (a literal replica default is wrong; an explicit instance value still wins). A workload that runs one pod at a time declares the ceiling `none` and sets one replica; more than one replica under `none` is an evaluation error. `meta.availability.max` is for a limit of the program that holds for every workload, with a reason; a limit that depends on configuration, on what the package wires, or on one workload goes on that builder call (`availability.max`). Under `meta.availability.max`, an `atLeast` above the ceiling is an evaluation error: the package never sees those levels, so move the ceiling to the builder calls that need it. Do not write `topologySpreadConstraints` or pod anti-affinity in a package: any Deployment/StatefulSet with `replicas > 1` gets spread across `cluster.topology.failureDomainKeys` (zone, then hostname, from `cluster.topology.zoneKey` and `hostKey`, which default to the well-known labels; nothing on `multiNode = false`) and a PDB, derived at build time, with strictness lowered from the level. Author-written constraints switch both derivations off for that workload. On a single-node cluster a hand-written `requiredDuringScheduling` anti-affinity with `replicas > 1` is an eval error. Packages whose pods an operator renders put the same rule in the CR's pod spec with `kix.availability.spreadConstraints { level = availability; selector = <operand labels>; topology = clusterConfig.cluster.topology; }`. Read `kix/lib/plugins/availability/module.nix` and `kix/lib/core/availability.nix`.
- **`ref`**: module arg, `ref.<namespace>.<instance>`, a pointer to another instance for `deps.<arg> = ref.kube-system.coredns`. The wired dep resolves like an auto-resolved one (config injection lands on it, meta checks apply). A list, `deps.<arg> = [ ref.a.b ref.c.d ]`, binds the argument to a list of those instances, each resolved and checked as a single ref is; the package should accept one handle as well (`lib.toList`). The pointer has no attributes of the instance (`ref.a.b.root` and `ref.a.b.out` do not exist). Inside a `kix.mkImport`'s `out`, a ref is replaced by the instance itself. A `kix.mkImport` instance's `extraDeps = [ ref.apps.contract ]` orders the import's marker after that instance's marker. The ref does not activate an optional instance: a ref to one that nothing activates fails evaluation. A malformed entry and `extraDeps` on a managed instance fail whether or not the instance is active.
- **`mkLocked`**: marks a config field as immutable; blocks dep injection overrides.
- **Monitoring module**: declarative Prometheus/Grafana/Loki stack. Read `kix/modules/experimental/monitoring.nix`.

**Network policy:** CiliumNetworkPolicy is auto-derived from endpoint facts, with no package authoring needed. Egress rules for API server access, DNS, and cross-package services are generated automatically; a workload gets an edge to exactly the Services whose *address values* (`out.fqdn`/`out.url`, possibly via ConfigMap/Secret indirection) reached its manifest. Default-deny is per-namespace. Edges the graph cannot see (an ingress controller's backends, a component that dials something it was not handed facts for) are declared as `meta.network.intents` (`docs/src/content/docs/reference/package-anatomy.mdx` `#metanetwork`, `docs/src/content/docs/explanation/network-policy.mdx` `#declarative-intents-and-operand-policies`) or by repeating the dep's `out.*` facts in the workload's env. Use container port numbers as `targetPort` in Services defined directly: cilium drops egress on a named port. Read `kix/lib/plugins/netpol/` and `kix/lib/core/facts.nix` for details. If hitting blindspots (Helm chart opacity, operator-managed pods), see `v2_discussions/archive/96_netpol_autogeneration_blindspots.md`.

### Flavors (target presets)

Flavors set `cluster.provider`, `cluster.roles` bindings, `cluster.capabilities` substrate axioms, and platform-provided DI imports. Use as the first module in `buildCluster`:

```nix
kix.buildCluster {
  name = "my-cluster";
  modules = [ kix.flavors.gke  ./platform.nix  ./apps.nix ];
}
```

Available: `k3s`, `kind`, `kubeadm`, `eks`, `gke`, `gke-autopilot`, `aks`, `openshift`, `ovh`, `scaleway`, `rke2`, `talos`.

Flavors provide imports for platform-managed services, declared via `kix.mkImport { roles = [ ... ]; out = { ... }; }`:
- **DNS** (`platform-dns`, role `dns`): all flavors, `optional = true` except on kind. Imports the cluster's DNS Service (`kix/lib/flavors/platform-dns.nix`) and sets `out.name` and `out.fqdn` from that Service's name and namespace.
- **Storage** (`platform-storage`, role `storageClasses`; the import names the StorageClass with `kind`/`apiVersion`/`out.name`) in flavors whose provider creates the class on every new cluster (not EKS). Not optional: packages take `storageClasses` as an optional dependency, which activates no optional import, and the PVC StorageClass check needs the marker.
- **Snapshot API** (`platform-snapshot-controller`, role `snapshotController`, with `crds`) on RKE2, not optional for the same reason.
- **Resource metrics API** (role `metricsApi`): rke2, k3s, gke, gke-autopilot, and aks bind it `exclusive` with no import; kind, kubeadm, talos, and eks bind it `absent`. A HorizontalPodAutoscaler on resource metrics, or a descheduler with a `KubernetesMetrics` provider, fails evaluation under `absent` until a `metrics-server` instance claims the role. On kind and Talos, give it `extraArgs = [ "--kubelet-insecure-tls" ]`.

If the cluster installs its own managed package (e.g. `storage-classes`), it automatically takes priority over the flavor import (managed shadows import), unless the flavor declares the role binding `exclusive`, in which case the managed instance is refused at eval (e.g. a managed CNI on stock kind/k3s; override the binding to `"absent"` when the cluster genuinely runs without the environment's default). On RKE2 set `cluster.flavor.rke2.cni` to the server config's `cni` list rather than overriding the binding. A managed class annotated default is refused where the flavor imports a default class.

### Helm charts: three tiers

**Tier 1: Inline** (no package file): `package = kix.helmChart { repo; name; version; hash; }; config.values = { ... };`. Add `root = { kind; name; }` when the chart has several Services or workloads.

**Tier 2: Real package with `importChart`** (full control: DI, CRD refs, custom root):
```nix
{ scope, lib }:
let
  release = "1.0.0";
  chart = scope.helm.fetchHelmChart { repo = "oci://..."; name = "x"; version = release; hash = "sha256-..."; };
in {
  meta.version = release;
  build = { config, scope, ... }:
    let resources = scope.helm.importChart { inherit chart scope; values = config.values or {}; releaseName = scope.instanceName; };
    in resources.mkParts { root = resources.get "Deployment" "x"; };
}
```

`mkParts` auto-derives a public `out`:
- `out.byKind.<Kind>.<name>`: flat lookup of every wrapped chart resource. Consumers reach non-root chart resources via `pkg.out.byKind.Service.foo.out.fqdn` instead of forcing the producer to hand-roll overrides.
- For a workload root (Deployment/StatefulSet/DaemonSet/Job) with exactly one Service that selects it, that Service's `out.{name, fqdn, selector, ports, url}` is promoted onto `pkg.out` so consumers reading `pkg.out.fqdn` get the public Service FQDN. Skipped silently when 0 or >1 Services match; pass `out = { fqdn = ...; }` explicitly to override.
- For Service roots, no promotion is needed (`scope.mkResource` already auto-derives correct outs); only `byKind` is added.
- `out.crds.<Kind> = { cr, mkCR }` for every CRD the chart ships in its `helm template --include-crds` output. Builders inject the CRD plus all chart workloads as `requires`, so a consumer's CR waits for both Establishment and controller readiness. Charts that install CRDs at runtime (like cilium's `INSTALL_CRDS`) won't expose anything here; fall back to `scope.mkCRDRef`. Chart CRs depend on the chart's own CRDs. A chart resource of another package's kind (a ServiceMonitor toggle) fails check 21: turn the toggle off and use `kix.monitor` or the owner's builder.

`importChart` parameters worth knowing:
- `deps = [ depA depB ];`: auto-collects every context-carrying string at `dep.out.*` and threads them through netpol generation (replaces the manual `networkDeps = [ dep.out.fqdn ]` plumbing). Use `networkDeps` only for context buried in nested values like `dep.out.byKind.Service.x.out.fqdn`.
- `replaceResource` (method on the returned collection): substitute a chart resource with a Kix-native one: `resources.replaceResource "Ingress" "foo" myKixIngress`. Use when a chart ships e.g. an Ingress but you want `kix.expose` to decide per-cluster how to materialize it. The replacement must declare its own `requires` if it needs to wait for chart resources; edges INTO the original are dropped.

**Tier 3: Native package** (no Helm, full DSL control).

### Dependency Injection (DI)

Packages declare dependencies as **build function args**. Required deps have no default, optional deps get `? null`. The eval system discovers deps by introspecting build function args (stripping system args: `self`, `config`, `clusterConfig`, `scope`, `lib`, `kix`, `deps`, and `availability`).

DI resolution priority: (1) explicit dep overrides, (2) same-namespace match, (3) cluster-wide match (must be unambiguous). **Managed instances take priority over imports.** An instance cannot depend on itself: automatic resolution skips the requesting instance, and pointing `deps.<arg>` (or an entry in a `deps.<arg>` list) at the instance itself with `ref` fails evaluation. Because managed instances take priority over imports before Kix filters out the requesting instance, a managed instance whose own name, aliases, or roles match `<arg>` only auto-resolves to another managed instance; wire `deps.<arg>` with `ref` if it needs an import. The resolved dependencies are also available together as the `deps` build argument.

Every key in an instance's `deps` must match a dependency declared by its package (checked on inactive `optional = true` instances too). If the package renamed that dependency with `deps.<arg>.renamedFrom`, evaluation fails with the rename's change ID and gives the new name. Any other unknown key fails with `[K3646]`, including any `deps` key on a `kix.mkImport` instance (imports take no dependencies; use `extraDeps` for deploy ordering).

**Infrastructure DI patterns:**

| Pattern | Example | When to use |
|---------|---------|-------------|
| Plain value on `out` | `storageClasses.out.storageClassName` | Single field the consumer needs |
| Transformer on `root.out` | `clusterIssuer.out.withCert` | Adding annotations/fields the consumer would forget |
| CRD handle on `out` | `scope.mkCR certManager.out.crds.Certificate { ... }` | Creating custom resources of a provider's kind in the consumer's namespace |

**Storage DI:** Persistent storage uses first-class PVC instances wired through dependency injection. Short version: `storage` is a DI dep, use `kix.mount.pvc storage { mountPath = ...; }`. **Read `STORAGE.md` for the full pattern, cluster definition example, and design rationale.**

**PriorityClass DI:** a workload's PriorityClass is an optional `priorityClass ? null` dependency on a `priority-class` instance, read as `priorityClass.out.name` and wired explicitly with `deps.priorityClass = ref.<ns>.<instance>`. Do not add a `priorityClassName` string option; the dependency orders the workload after its class. Built-in `system-*` classes are named literally.

**The namespace rule of resolution:** a package argument is filled from the consumer's own namespace. An instance in another namespace is used only when the cluster definition names it, with `deps.<arg> = ref.<namespace>.<instance>`, or when the provider's package serves the whole cluster. A package serves the whole cluster when it sets `meta.scope = "cluster"`, claims a role in `meta.roles`, or declares `meta.conflictsWith` on a `cluster:` key (`kix/lib/meta.nix` `servesCluster`); operators, ingress controllers, and certificate issuers are the usual cases. `kix.mkImport` stand-ins serve the whole cluster. An instance that a demand created from `availablePackages` (in `autoNamespace` or elsewhere) or switched on as an `optional = true` instance binds from any namespace too (`demanded` in the resolution index), because the cluster definition chose where it lives. When the only match for a required argument is in another namespace and does not serve the cluster, the build fails and the error prints the `deps` line to add; an optional argument takes its default and Kix prints a warning with that line. Databases, caches, and anything that hands out a Secret leave `scope` unset, so a cluster file names the instance a consumer in another namespace means (`clusters/homelab/services.nix` wires `immich.immich-db` to `ref.data.postgres`).

**Namespace-scoped providers:** a package whose `out` hands consumers a Secret they reference by `secretKeyRef` declares `meta.scope = "namespace"`. It is then never used from another namespace: automatic resolution skips it, and an explicit `deps.<x> = ref.<ns>.<instance>` to it fails, so consumers need no same-namespace guard of their own.

**Illegal object names are an evaluation error.** Kix applies Kubernetes' naming rule for each resource kind: an RFC 1035 label for a Service, a DNS-1123 label for a Namespace, a DNS-1123 subdomain of at most 52 characters for a CronJob, and a DNS-1123 subdomain for other resources. RBAC resources are exempt because the API server validates their names as path segments. Schema validation cannot catch these errors because the OpenAPI schema leaves `metadata.name` unconstrained. During a migration, the usual cause is a camel-case instance name copied from a build argument. Packages normally derive resource names from `scope.instanceName`, so rename the instance with a lowercase name. Preserve the build argument as a DI name with `meta.defaultAliases = [ "thatCamelCaseName" ]`, as `ingress-nginx` does for `ingressNginx`.

**Raw PVCs are an eval error.** A package building `kind: PersistentVolumeClaim` directly throws at build time, including PVCs emitted by an imported Helm chart with persistence enabled. The escape is an explicit grant in package meta: `meta.unsafe = [ "raw-pvc" ]` (closed vocabulary, `kix/lib/unsafe.nix`; every grant is listed by the `architecture.unsafeGrants` scorecard audit). Prefer restructuring to the `storage` DI dep; grant `raw-pvc` only for chart-emitted claims or genuinely inline multi-component claims.

**A package that cannot pass a structural security rule declares why.** Four more grants exist for the cases where the rule is right and the package is still correct: `host-network` (pods on the host network, PID, or IPC namespace), `privileged` (privileged containers), `run-as-root` (containers as uid 0), and `cluster-admin` (a ServiceAccount bound to cluster-admin or an all-wildcard ClusterRole, refused by `security.noClusterAdmin`). Each switches its rule off for that package alone and is listed by `unsafeGrants` in every build. `kix/packages/experimental/cilium` holds the first three, because programming the node's networking is what a CNI does. `kix/packages/experimental/velero` holds `cluster-admin`, because a backup tool restores any kind, including CRDs installed later; every other package derives its RBAC with `scope.rbac`. Reach for one only for a CNI, a CSI node plugin, a node-level agent, or an operator whose own namespace runs privileged pods it creates (tailscale declares `privileged` for its proxies). An application package that trips these rules has a bug. The alternative they replace, a per-namespace severity override in the cluster definition, exempts everything else in that namespace too.

### Package Meta

- **`meta.podSecurity`**: `"privileged" | "baseline" | "restricted"`, the Pod Security level the package's pods need (kubevirt: privileged). The namespace carries `pod-security.kubernetes.io/enforce` at the most permissive level any of its instances needs. The build checks every pod template in a namespace with a level and fails on a workload that breaks it, naming the container and field.
- **`meta.availability.max`** caps the whole instance; a package where only some workloads cannot reach the level puts `availability.max = "none"` on those builder calls (`scope.mkDeployment { availability.max = "none"; ... }`) so a quorum store beside a single-replica controller keeps hard spread. Both accept an optional `reason` string explaining why the software cannot run at a higher level. Kix includes `reason` when it warns that availability was capped at `max` or rejects more than one replica under `max = "none"`.

```nix
meta = {
  lifecycle = "stateful";   # "stateless" (default, omit) | "stateful" | "ephemeral"
  scope = "namespace";      # unset (default): other namespaces use it only through deps.<arg> = ref.<ns>.<instance> | "cluster": every namespace finds it by name | "namespace": never used from another namespace, not even by ref
  version = "1.2.0";        # the upstream release the package deploys by default, without a "v" prefix. An instance reports `out.version` first (`kix.image.version config.image`), then this
  description = "...";      # required: governance.hasDescription warns without it
  owner = "platform";       # required: "platform" or "app-team"
  conflictsWith = [
    "other-pkg"             # same-namespace mutual exclusion
    { key = "cluster:myOperator"; reason = "Its admission webhooks run across all namespaces."; }  # cluster-wide: one instance answering this name per cluster; Kix includes reason in the conflict error
  ];
};
```

- `lifecycle`: `"stateless"` (default; omit per M5), `"stateful"`, or `"ephemeral"` (`kix/lib/core/activation.nix` passes any non-null string through to `PackageInstance.spec.lifecycle`). `lifecycle = "stateful"` marks a package that **provides state that other packages depend on**, triggering `kix plan` protection (PVC deletion = error) and migration pair detection (`persistent-volume-claim`, `stackgres-cluster`, `valkey`). A pair is a removed object and an added one in the same stateful package that may both hold data, preferring a candidate of the same kind. `kix.run/holds-data` answers first (`holdsData` on `scope.mkCRD` or `scope.mkCRDRef`, enforced at build time on every custom resource a stateful package renders, `kix/lib/eval/cluster.nix`; built-in storage kinds get `"true"` from their shape). When an object has no `kix.run/holds-data` annotation, a built-in kind may hold data only when its manifest declares storage (`spec.volumeClaimTemplates`, `spec.resources.requests.storage`, `spec.capacity.storage`, or `spec.storage`), and an unmarked custom resource outside Kix's own group is assumed to hold data (`cli/kix/src/cluster/migrate.rs`). Import markers never pair. A renamed object that holds no data (a Job, a ConfigMap, a Secret, a NetworkPolicy, a StatefulSet without claim templates) does not pair. A package that merely *consumes* stateful services is **not** stateful. `lifecycle = "ephemeral"` marks a package whose local state is expendable on a storage swap (`prometheus`, `alertmanager`, `victoria-metrics-cluster`), suppressing migration pair detection.
- `scope`: unset, an instance is used from another namespace only when the consumer names it with `deps.<x> = ref.<ns>.<instance>`; a required dep whose only match is in another namespace fails and the error prints that line. `"cluster"`: consumers in every namespace find the instance by name; set it on operators, ingress controllers, and issuers (a `meta.roles` claim or a `cluster:` conflict has the same effect). `"namespace"`: automatic resolution skips it for consumers in other namespaces (a required dep then fails as not found and names the skipped instances), and an explicit `ref` to it from another namespace fails.
- `version`: enables dependency version compatibility checks via `checkMetaStatic`. Set it only on a package that deploys upstream software; a package that only writes another package's CRs or a built-in kind omits it. Read `kix/lib/core/version.nix` for `parse`, `atLeast`, and `atMost`.
- `owner`: every package in the tree declares one, `"platform"` for infrastructure and `"app-team"` for user-facing applications. `governance.hasOwner` warns without it.
- `conflictsWith`: build-time error if another instance answering a listed name exists in the namespace, or anywhere in the cluster for a `"cluster:<name>"` entry. An instance whose package lists the name in `meta.defaultAliases` counts even when its own `aliases` replace the defaults (`byDefaultAlias` in `kix/lib/eval/resolve.nix`). A package that runs once per cluster (its controller watches every namespace and cannot be scoped, or two copies would fight over the same objects) lists `"cluster:<its defaultAlias>"`. Auto-instantiation reads that entry (or a `meta.roles` claim) too: it refuses to place the package in a second namespace, or beside the one package that needs it (`[K2377]`), and asks for one declared instance in a namespace of its own, a catalog `namespace`, or `autoNamespace`. Shipping CRDs alone does not call for the entry, because two instances that render the same CRD fail evaluation anyway.
- All enforced by `kix/lib/meta.nix` at build time.

**Every workload kind has a typed builder, and `scope.mkResource` refuses all of them.** `mkDeployment`, `mkStatefulSet`, `mkDaemonSet`, `mkJob`, `mkCronJob`, and `mkHelmWorkload`. A CronJob's pod template sits one level deeper, under `spec.jobTemplate.spec.template`, and `mkCronJob` needs `spec.jobTemplate.spec.template.metadata.labels`, because a CronJob has no selector of its own and those labels are the only identity its pods carry.

**Workload labels.** The typed workload builders stamp the workload's own selector labels onto its `metadata.labels`, on top of the cluster and instance labels, so `app.kubernetes.io/name` is on the object and not only in the selector and the pod template. When the selector has no `app.kubernetes.io/name` (an upstream `app` or `name` selector), `mkDeployment`, `mkStatefulSet`, and `mkDaemonSet` set it to the instance name on the object and the pod template, so `kubectl get pods -l app.kubernetes.io/name=<instance>` finds the pods. The immutable selector is left as written. A package's explicit `labels` argument still wins, and its value is what the pod template gets; an `app.kubernetes.io/name` in the pod template's own labels wins there.

**Scorecard:** on by default with the full built-in rule set, every finding capped at `scorecard.maxSeverity = "warning"` for users; this repository's flakes raise the cap to `error` for every cluster (`mkFlake { clusterModules }`), so a package that trips an error-severity rule fails every test cluster it is in. Rules score what ships, derived resources included. Rules check for: resource requests/limits, liveness+readiness probes, non-root containers (`security.nonRoot`: set `runAsNonRoot = true` when the image runs as a non-root user, numeric `runAsUser` when the image names its user by name, and hold `meta.unsafe = [ "run-as-root" ]` with a comment saying why only when the image needs root), no `:latest` tags, `meta.owner`, `meta.description`, network policies, a source on every volume (`emptyDir = kix.keep { }` for an empty one), distinct labels on same-kind resources, and more. A cluster changes one rule with `scorecard.ruleOverrides`, never by copying `rules`. A package option that makes a rule fire on purpose (vaultwarden's `initChownData` adds a root chown container) reads `kix.scorecard.effectiveSeverity { inherit clusterConfig; rule = "security.nonRoot"; namespaceName = scope.namespaceName; owner = "app-team"; }` (the resolved severity, or null when the rule does not run) and throws its own message naming the override when that is `"error"`. Read `kix/lib/rules/` and `kix/lib/scorecard.nix`.

**Annotation domains (v2_discussions/128):** operator packages declare the annotation prefixes they manage via `meta.annotationDomains = [ "reloader.stakater.com" ]` (prometheus-operator and reloader do). The index matches a domain exactly, so a package lists every subdomain it reads (reloader lists `reloader.stakater.com`, `secret.reloader.stakater.com`, `secrets.exclude.reloader.stakater.com`, and `deployment.reloader.stakater.com`). The `architecture.annotationDomainOwnership` rule warns when a package's resources carry `metadata.annotations` keys under a declared domain without a DI dep on the declarer, and when a domain-shaped annotation has no declarer anywhere (dead annotation: the operator is probably missing). Reserved suffixes (`kubernetes.io`, `k8s.io`, `kix.run`, `helm.sh`, `kubebuilder.io`) are exempt; by-convention domains consumed outside Kix (e.g. `prometheus.io` scrape annotations) go in the cluster's `scorecard.knownAnnotationDomains`. There is no `kix.run/capability` stamping anymore; the dep edge is the legitimacy marker. Restart-on-change for a Secret Kix does not build goes through the reloader dependency's `out.withReloadOn`; for a Kix-built ConfigMap or Secret put `checksum/<name> = <res>.out.contentHash` on the pod template (`docs/src/content/docs/reference/resources-and-out.mdx` `#triggering-rollouts-on-configmap-changes-with-outcontenthash`). Never build it from `out.identityHash`, which also changes when anything the resource depends on changes.

## Multi-Component Packages

For packages with multiple sub-services (harbor-style), keep everything in **one package**, not split into separate packages. **Read `MULTI_COMPONENT.md` for patterns**: shared let bindings, per-component selectors and Service labels, fact-carrying internal URLs, breaking a mutual-dial cycle, one `kix.monitor` per metrics Service, `root.requires`, `root.postHooks`. Reference: `kix/packages/stable/harbor/`.

## Operator-Managed Stacks (VictoriaMetrics reference)

Some stacks are not Deployments you render but custom resources an operator
turns into pods at runtime. The VictoriaMetrics packages are the reference
for that shape (design: `v2_discussions/133`, shipped 2026-09-07):

- `kix/packages/stable/victoria-metrics-operator/` owns the CRDs (`crds.nix`, typed
  builder chain with `readiness` and `factBehavior`), the kinds table
  (`kinds.nix`), and the controller (`operator.nix`). It answers the
  `prometheus` alias and ships the prometheus-operator compat CRDs
  (ServiceMonitor, PodMonitor, PrometheusRule, Probe) with the same
  builder surface (`out.mkServiceMonitor`, `out.mkPrometheusRule`, ...),
  so every `kix.monitor` call and app-package ServiceMonitor works
  unchanged; the operator converts them. It also exposes CR builders such
  as `out.mkVMCluster scope { ... }`.
- `kix/packages/stable/victoria-metrics-cluster/` (VMCluster, aliases
  `prometheusServer` and `vmCluster`), `victoria-metrics-agent/` (VMAgent),
  and `victoria-metrics-alert/` (VMAlert + VMAlertmanager) each build one CR
  through the operator's builder, never a raw kind string. The cluster
  package does not render Services over the operator's pods. It uses
  `scope.mkServiceRef` for the Services the operator creates
  (`vmselect-<name>`, `vminsert-<name>`), and builds `out.serviceUrl` /
  `out.remoteWriteUrl` on the ref's `out.fqdn` so consumers keep dependency
  context. A Service Kix renders itself over operator pods declares the CR
  with
  `metadata.annotations."kix.run/operand-of" = "<group>/<Kind>/<name>"`;
  otherwise the cross-resource check refuses a selector that matches no pod
  template in the build. There is no list of operator kinds anywhere.
- Trial posture: `lifecycle = "ephemeral"` on the cluster package means
  historical metrics are expendable on a storage swap. Revisit before VM
  becomes a long-term store.
- The StorageClass arrives as an import marker (`kix.mkImport { out.storageClassName = ...; }`
  under the `storageClasses` alias), so the substrate stays outside Kix.

When migrating a cluster from the kube-prometheus-stack chart, pick a
native backend. `kix.modules.experimental.monitoring` instantiates
prometheus-operator, prometheus, alertmanager, grafana, node-exporter,
kube-state-metrics, and prometheus-default-rules
(`clusters/test-monitoring-native.nix`, kix-examples
`how-to/package-stacks/monitoring-cluster.nix`). Grafana needs a
`grafanaAdmin` secret (keys `admin-user`, `admin-password`) in the module's
namespace. The Prometheus and Alertmanager resources take their fields
through each instance's `extraSpec`, and Alertmanager's routing through
`monitoring.alertmanager.settings`. For VictoriaMetrics,
keep the `prometheus` alias on the operator package and the
`prometheusServer` alias on the cluster package
(`clusters/test-victoria-metrics.nix`, kix-examples
`how-to/package-stacks/victoria-metrics-cluster.nix`). Either way,
existing `kix.monitor` users and the grafana datasource rewire
themselves. Take the native instance names and let `kix plan` show the
replacement.

## Two Implementations, One Alias (ClickHouse reference)

When a service has a small form and an operator form, build both as separate packages that answer one alias with one `out` contract, so a consumer is wired once and the cluster picks the implementation. The ClickHouse packages are the reference (design: `v2_discussions/148`):

- `kix/packages/experimental/clickhouse/` renders a single StatefulSet with embedded Keeper. `kix/packages/experimental/clickhouse-cluster/` builds a ClickHouseInstallation through `kix/packages/experimental/clickhouse-operator/` and `kix/packages/experimental/clickhouse-keeper/`. Both carry `defaultAliases = [ "clickhouse" ]` and the `out` that `kix.contracts.experimental.clickhouse` (`kix/contracts/experimental/clickhouse.nix`) defines (`httpUrl`, `nativeEndpoint`, `host`, `ports`, `username`, `credentials` (key `password`), `clusterName`, `version`, `replicas`, `replicaHosts`).
- The contract is one file in `kix/contracts/stable/`, read as `contract = kix.contracts.experimental.clickhouse;` by both implementations (`root.out = contract.check scope { ... }`) and by the facade (`deps.clickhouse.assertions = contract.assertions;`), so a missing or misshapen field fails at eval and names the instance. Keep it small. A field one implementation cannot honour means a different alias, not a `null`.
- `version` is a contract field (the server version, read from the image tag with `kix.image.version`). A consumer states a requirement as an assertion on the dep: `lib.optional (lib.versionOlder dep.out.version "25.3") { assertion = false; message = ...; }`, as `clickhouse-database` does. Selection among several instances stays explicit (`deps.clickhouse = ref.<ns>.<inst>`). With both packages in `availablePackages`, a demanded `clickhouse` is refused until the cluster selects one: `instances.data.clickhouse = { package = packages.experimental.clickhouse-cluster; optional = true; };`.
- An operator package exposes the selectors of the pods it creates from its kinds table (clickhouse-operator `out.operandSelector.<kind> name`; the convention for new packages is `out.operandSelectors.<operand>`, as stackgres-operator's `sgCluster`), and the CR packages read them for the policies they write over operator pods with `kix.operandPolicy { scope; name; spec; }`, which returns null when network policy is off. Operator-created pods in the consumer's namespace get a builder on the operator package when the policy needs the operator's namespace (cdi `out.mkImporterPolicy`). Their `extraSpec` goes through `kix.mergeGuarded` with the computed paths locked.
- Consumers go through a facade, `kix/packages/experimental/clickhouse-database/` (the `stackgres-database` shape), which owns the credentials in the consumer's namespace and forwards the server's `out`. No consumer touches the server package.
- Every contract that more than one package shares is a file in `kix/contracts/stable/` (or `kix/contracts/experimental/`, read as `kix.contracts.experimental.<name>` by experimental packages only), named after its name under `kix.contracts`. The file returns the result of `mkContract`, so each contract has `name`, `alias`, `fields`, `problems`, `check`, `assertions`, `require`, `requireAs`, `helpers`, and `options`. The Postgres `database` contract is `kix.contracts.postgresDatabase` (`kix/contracts/stable/postgresDatabase.nix`, fields `host`, `port`, `database`, `credentials`, `username`, `extensions`, `tls`). A provider package returns `root.out = kix.contracts.postgresDatabase.check scope { ... }`; a package that takes `deps.database` sets `deps.database.assertions = kix.contracts.postgresDatabase.assertions;` (or `dep: kix.contracts.postgresDatabase.assertions dep ++ ...` to append its own checks). The consumer side requires only `host`, `port`, `database`, and `credentials`, so a consumer that reads `username`, `extensions`, or `tls` handles their absence on a `kix.mkImport` (harbor asserts `username`; immich skips its extension check without `extensions`).
- Redis: `harbor`, `immich`, and `n8n` take `kix.contracts.redis` as the dependency `redis`. The `valkey` package answers it through `meta.defaultAliases = [ "redis" ]`, and still takes its own `valkeyPassword` secret. A `kix.mkImport` that stands in for Valkey is named `redis` or carries `aliases = [ "redis" ]`. Sentinel and TLS checks are `kix.contracts.redis.helpers.usesSentinel` and `kix.contracts.redis.helpers.requirePlaintext`. A package that renames a dependency sets `deps.<arg>.renamedFrom = { name = "<old name>"; id = "K1234"; }` (using the ID of its `error` change record). When the renamed dependency is missing, or when an instance still sets `deps.<old name>`, evaluation fails with that ID and names both the old and new dependency names.
- Single sign-on: an application takes one `oidc ? null` dependency (`kix.contracts.oidc`, `kix/contracts/stable/oidc.nix`: `issuerUrl`, optional `endpoints`, and `credentials` with `clientId` and `clientSecret`), adds `oidc = kix.contracts.oidc.options { scopes = [ ... ]; autoLogin = "<its setting>"; };`, and calls `kix.contracts.oidc.helpers.client { scope; oidc; options = config.oidc; }`, which returns null when no client is wired. Single sign-on is on when the dependency is wired. The `oidc-client` package answers it for keycloak: it sits in the application's namespace, takes `deps.oidcProvider = ref.<ns>.<keycloak>` (`kix.contracts.experimental.oidcProvider`, functions of the realm), `config.realm`, and a secret aliased `oidcClient`. An outside provider with one issuer can be a namespaced `kix.mkImport` whose out sets `issuerUrl` and `credentials = ref.<ns>.<secret>` (grafana, harbor, and immich; `clusters/test-keycloak-oidc.nix`).
- Credentials always travel in the provider's `out.credentials`. An outside service with a login (RDS, a mail provider) is a `kix.mkImport` in the consumer's namespace whose `out` names the secret with `credentials = ref.<ns>.<secret>`; Kix swaps the ref for the instance and the import's marker waits for it.
- Share what is genuinely the same: `clickhouse-cluster` runs the probe script from `kix/packages/experimental/clickhouse/health-check.py`, with an env var for what differs (the replica count).
- Prove the contract with a build: `clusters/test-clickhouse-swap/` builds one consumer on each implementation and the `clickhouse-swap` flake check diffs the rendered manifests, allowing only the hostname to differ.
- Upstream vocabulary, not a Kix dialect: server config is ClickHouse YAML fragments as Nix attrsets, merged with `null` deleting a key, so anything in the ClickHouse docs can be set without a new option.

## Migration Tips

- **Read the Ansible role first.** Understand what the role creates: which Deployments, Services, ConfigMaps, RBAC, etc. Don't reverse-engineer from the cluster dump alone.
- **Ansible vars → `options`.** Anything variable in the Ansible role → `lib.mkOption` default. Anything hardcoded → hardcoded in the package.
- **Match the cluster, not the Ansible.** If Ansible says `replicas: 2` but the cluster has `3`, use `3` as the cluster definition override.
- **Start rough, diff, fix.** Write a first pass, build, diff against the cluster dump, iterate. The diff tool tells you exactly what's wrong.
- **Match names exactly.** If the diff shows a Kix-only resource with a fuzzy match to a cluster resource, rename it.
- **Don't over-specify.** K8s defaults (e.g. `strategy: RollingUpdate`) are stripped by the diff tool automatically.
- **After a deploy, `kix plan <cluster> --read-only` should print nothing.** It compares an object whose `kix.run/identity-hash` names a manifest in the build as that manifest, the rule `kix deploy` uses to skip it, and lists edits made since apply in its drift section. For an object the build changes it treats `null`, `[]`, documented server defaults, and quantity spellings (`1` and `"1"`) as equal (`cli/kix-core/src/manifest/diff/equivalence.rs`). A change line it still prints after a clean deploy is a comparison bug; a drift line names the field and the manager that changed it.
- **Before the first deploy onto an existing cluster, run `kix plan <cluster>`.** `kix plan --read-only` reads only, so it misses what shows on the write path. Taking over objects that Helm, kubectl, or an installer made usually stops on field ownership conflicts (the plan names the manager and the fields) and on immutable fields such as a Deployment's `spec.selector`. Decide per conflict: `ownership.cede` when the other manager should keep the field, `--force-conflicts` when Kix should take it, or delete and recreate for an immutable field. An object whose namespace or CRD the deploy creates is listed as not checked, which is expected on a first deploy. `kix plan --read-only` can also show a field as removed when another manager owns it, so trust the dry-run plan where the two disagree. A "Kubernetes would not keep" warning names a field the CRD's schema drops (often a field the upstream chart sets for a newer CRD version, or a typo) or a value a mutating webhook changes: fix the manifest or the CRD version, since the setting never takes effect.
- **Cluster-only resources are fine.** Many cluster resources (operator CRDs, auto-generated secrets) are not Kix-managed. Focus on the **Modified** section.
- **A new package is evaluated by the `every-package-evaluates` flake check** at availability `none` and `zone`, without being named by any cluster. If it has options with no default, or needs an instance the catalog cannot auto-instantiate (a secret dep such as `valkeyPassword`), add them to the `settings` table in `kix/package-eval.nix`. Run this check locally with `nix develop -c bash -c 'cd cli && cargo test -p kix-cli --test commands_test -- --ignored flake_checks_evaluate_with_helm'`. This runs the check through Kix because plain `nix build` cannot render Helm charts. The `Package checks` workflow runs the same test on pull requests that change `kix/` or `clusters/`.
- **Never `types.anything` with an attrset default.** Use `kix.options.resources` for container resources, a submodule with defaults on its fields otherwise, and `kix.types.quantity` for sizes. `extraArgs` goes through `kix.guardArgs`, `env` through `kix.mergeEnv`, and every secret dep through `kix.contracts.secret.helpers.use`.
- **Review the package before opening a pull request.** The `package-review` skill (`.claude/skills/package-review/SKILL.md`) holds the principles a package must meet and the checklist of known mistakes, with the commands that find them.
- **Pipe the diff to an LLM.** `./scripts/compare-cluster-dump.py ./result cluster-dump/ | pbcopy`
- **Look at existing packages for patterns:**
  - `kix/packages/experimental/reloader/`: native package with one Deployment, derived RBAC, leader election, flags and env guarded at evaluation, and an `out` transformer
  - `kix/packages/experimental/immich/`: mid-complexity: DI storage, `kix.expose`, `kix.monitor` with `extraEndpoints`, an optional dependency with a version check (`machineLearning`), `kix.mergeEnv` owned groups, a local `settings` path check, `kix.mount.*` + `kix.withMounts`
  - `kix/packages/stable/harbor/`: complex multi-component (read `MULTI_COMPONENT.md`)
  - `kix/packages/stable/valkey/`: StatefulSet with a Sentinel sidecar, scripts as files read from env, a required `valkeyPassword` dependency, `meta.scope = "namespace"`, a Sentinel ACL, and `kix.monitor`
  - `kix/packages/stable/storage-classes/`: `kix.storage.mkClasses` over a typed map of classes
  - `kix/packages/stable/victoria-metrics-*/`: operator + operand CRs, compat CRDs behind an alias (see "Operator-Managed Stacks")
  - `kix/packages/experimental/clickhouse*/`: one alias and contract served by a bare package and an operator stack, with a facade for consumers (see "Two Implementations, One Alias")
