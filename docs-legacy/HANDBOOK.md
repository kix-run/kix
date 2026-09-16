# kix Handbook

Dense, low-level reference for writing kix packages and clusters. Loaded on
demand. Companion to [`BEST-PRACTICES.md`](BEST-PRACTICES.md) (durable principles)
and [`FEATURE-CATALOG.md`](FEATURE-CATALOG.md) (breadth-first inventory).

> **Source-of-truth code.** Every signature here is verified against the current
> `kix/lib/` files and the canonical examples in `ludo/` and `kix/packages/`.
> If you find drift, fix this doc — don't paper over the discrepancy.

## Contents

1. [Cheat sheet](#1-cheat-sheet)
2. [Project layout](#2-project-layout)
3. [Build, diff, deploy commands](#3-build-diff-deploy-commands)
4. [The eval pipeline](#4-the-eval-pipeline)
5. [Package authoring contract](#5-package-authoring-contract)
6. [`scope` API](#6-scope-api)
7. [`mkResource` field reference](#7-mkresource-field-reference)
8. [Resource `out` reference](#8-resource-out-reference)
9. [`kix` composition helpers](#9-kix-composition-helpers)
10. [Top-level `kix.*`](#10-top-level-kix)
11. [RBAC DSL](#11-rbac-dsl)
12. [Helm tiers](#12-helm-tiers)
13. [Cluster definition](#13-cluster-definition)
14. [Cluster-wide options](#14-cluster-wide-options)
15. [Flavors and capability matrix](#15-flavors-and-capability-matrix)
16. [Network policy auto-derivation](#16-network-policy-auto-derivation)
17. [Scorecard](#17-scorecard)
18. [Multi-environment stamping](#18-multi-environment-stamping)
19. [Multi-component packages](#19-multi-component-packages)
20. [Storage](#20-storage)
21. [Secrets](#21-secrets)
22. [CRDs](#22-crds)
23. [Imports](#23-imports)
24. [Manifest stamping](#24-manifest-stamping)
25. [Activation CR and operator](#25-activation-cr-and-operator)
26. [Diff and snapshot tooling](#26-diff-and-snapshot-tooling)
27. [Common gotchas](#27-common-gotchas)
28. [References](#28-references)
29. [Image pins](#29-image-pins)
30. [Deploy receipt](#30-deploy-receipt)

---

## 1. Cheat sheet

| Question | Answer |
|---|---|
| Build a cluster | `nix build ludo/#cluster-ludo-kind --extra-experimental-features pipe-operators` |
| Diff vs live cluster | `kix diff <cluster>` (or `./scripts/kix-dump.py --all cluster-dump/ && ./scripts/kix-diff.py ./result cluster-dump/`) |
| Deploy a cluster | `kix deploy <cluster>` (add `-y` to skip confirm; `--dry-run` to preview) |
| Promote an image | `kix pin set <key> --tag <tag>` (§29) |
| Check every pin still resolves | `kix pin check` |
| See what was actually deployed | `kubectl get activation <name> -o jsonpath='{.status.receipt}'`, or `kix compliance attest <cluster> --from-cluster` (§30) |
| Find a symbol in `kix.lib` | `kix/lib/default.nix` — re-exports everything |
| Internals of eval/scope/netpol | `kix/lib/architecture.md` |
| What CLI commands exist | `kix --help` or `cli/README.md` §Where things live |
| Reference cluster | `ludo/` (the `ludo-kind` variant is the smoke test) |
| Reference packages | `kix/packages/{reloader,immich,harbor,valkey,storage-classes,persistent-volume-claim}` |
| Migration playbook | `.claude/skills/kix-migration/SKILL.md` |
| Sub-topic deep-dives | `.claude/skills/kix-migration/{SECRETS,STORAGE,MULTI_COMPONENT}.md` |

**Top idioms.**

```nix
# Reference resource names (carries DAG context):     self.svc.out.name
# Reference resource FQDN:                            self.svc.out.fqdn
# Reference selector labels (carries DAG context):    self.deployment.out.selector
# Cycle escape (no DAG edge to workload):             self.deployment.rawSelector
# Build a workload pipe-style:                        { ... } |> kix.withMounts [...] |> scope.mkDeployment
# Build a service from a workload:                    self.deployment |> kix.service.fromWorkload {...} |> scope.mkResource
# Auto-expose service via Ingress or HTTPRoute:       (kix.expose { service = "service"; })
# Auto-monitor service:                               (kix.monitor { service = "service"; port = "metrics"; })
# Post-deploy probe Job:                               (kix.healthCheck { script = builtins.readFile ./health-check.py; env = ...; })
# Reference a kix-managed Secret:                     self.secret.out.keyRef "password"
# Reference an external Secret:                       (scope.mkSecretRef { name = ...; keys = [...]; }).out.keyRef "..."
# Read an image from a committed pin file:            { kix, pins, ... }: pins.get "web"   (flake: pins = ./pins.json;)
# Render an image reference (repo:tag@digest):        kix.image.ref config.image
# Filter null env vars:                               kix.mkEnvVars { OPT = config.opt or null; }
# Combine env + raw entries:                          kix.mkEnv { K=v; } [ rawEntry ]
# Conditional resource:                               if cond then ... else null    (collectTypedAttrs strips null)
# Intentional empty value (emptyDir, selectors):      emptyDir = { };   (literal empties render; all-null containers collapse, see §7)
# Constructor-built maybe-empty container:            kix.keep { medium = config.medium; sizeLimit = config.sizeLimit; }
```

## 2. Project layout

```
kixpkgs/
├── kix/
│   ├── lib/                   # The kix Nix library (imported as `kix.lib`)
│   │   ├── default.nix        # Re-exports — start here to find a symbol
│   │   ├── architecture.md    # Internals + non-obvious patterns
│   │   ├── eval/              # buildCluster, evaluateInstance, scope, resolve, auto, namespace, view
│   │   ├── flavors/           # k3s, kind, kubeadm, eks, gke, gke-autopilot, aks, openshift, rke2, talos, lithus
│   │   ├── modules/           # Reusable cluster modules (monitoring.nix)
│   │   ├── rules/             # Built-in scorecard rules: security, reliability, governance, architecture
│   │   ├── compose.nix        # `kix` arg passed to packages (kixlib helpers)
│   │   ├── k8s.nix            # mkResource, mkClusterResource, mkPackageInstance, mkActivation
│   │   ├── modules.nix        # NixOS-style cluster option schema
│   │   ├── helm.nix           # Helm bridge (tiers 1+2)
│   │   ├── helm-dag.nix       # Helm chart DAG reconstruction
│   │   ├── netpol.nix         # CiliumNetworkPolicy auto-derivation
│   │   ├── scorecard.nix      # Rule engine
│   │   ├── rbac.nix           # RBAC DSL
│   │   ├── crd.nix            # Pipe-friendly CRD spec builders
│   │   ├── env.nix            # mkEnv multi-env stamping
│   │   ├── fragments.nix      # mergeFragments
│   │   ├── meta.nix           # Version system, peekPackageMeta, diagnostics
│   │   └── mkFlake.nix        # Flake boilerplate generator
│   ├── packages/              # Reusable kix packages (~50)
│   ├── checks.nix             # kubeconform schema check; re-exports the cross-resource checks from lib/eval/validate.nix
│   └── pi-checks.nix          # PackageInstance schema/wiring checks
├── cli/                       # Rust workspace (kix CLI + operator)
│   ├── kix/                   # Library crate: eval, manifest, cluster
│   ├── kix-cli/               # Binary: clap CLI + plan rendering + observers
│   ├── kix-operator/          # Binary: kube-rs controller for Activation CRs
│   └── README.md              # ← Authoritative CLI architecture doc
├── ludo/                      # Reference cluster — Luca's home server
│   ├── flake.nix              # Wires baseline + variants
│   ├── cluster.nix            # Real k3s deployment
│   ├── cluster-kind.nix       # Local kind variant (smoke test)
│   ├── base.nix               # Flavor-agnostic shared module
│   ├── platform.nix           # Cluster-wide options
│   ├── services.nix           # All application instances
│   └── variants/              # Story variants (gateway/tls/upgrade/migrate/...)
├── nw1/                       # Production-target cluster
├── clusters/                  # Test/example cluster definitions
├── scripts/                   # kix-dump.py, kix-diff.py, etc.
├── PRINCIPLES.md              # Durable design tenets
├── ROADMAP.md                 # Live status / open design questions
├── CLAUDE.md                  # Project rules for AI agents
└── docs/
    ├── BEST-PRACTICES.md      # High-level guidance
    ├── HANDBOOK.md            # ← This file
    └── FEATURE-CATALOG.md     # Breadth-first feature inventory
```

**When to edit each:**

| You want to … | Edit |
|---|---|
| Add or change a package's K8s resources | `kix/packages/<pkg>/default.nix` |
| Add a cluster | `clusters/`, `ludo/`, or `nw1/` |
| Add a kix DSL helper | `kix/lib/compose.nix` |
| Add a NixOS-style cluster option | `kix/lib/modules.nix` |
| Add a flavor | `kix/lib/flavors/`, register in `kix/lib/default.nix` |
| Add a scorecard rule | `kix/lib/rules/`, register in `kix/lib/rules/default.nix` |
| Change CLI behavior | `cli/kix-cli/src/`, `cli/kix/src/` |
| Document a new pattern | `BEST-PRACTICES.md` (philosophy) or `HANDBOOK.md` (mechanics) |

## 3. Build, diff, deploy commands

### 3.1 Nix-level build

```bash
# Cluster activation derivation (rooted at the Activation CR)
nix build ludo/#cluster-ludo-kind --extra-experimental-features pipe-operators

# Result: ./result is a directory of namespace/Kind-name.yaml files
ls result/
```

`pipe-operators` is required because kix uses `|>` extensively. Add to `~/.config/nix/nix.conf` (`experimental-features = nix-command flakes pipe-operators`) to drop the flag.

### 3.2 Python diff scripts (no CLI needed)

```bash
./scripts/kix-dump.py --all [--context <ctx>] cluster-dump/
./scripts/kix-diff.py ./result cluster-dump/
```

`kix-dump.py` strips server-side fields and Secret data; ephemeral resources (Pods, ReplicaSets, Jobs, Events) are excluded. `kix-diff.py` produces a `Modified | kix-only | cluster-only | renamed` report.

### 3.3 `kix` CLI

| Command | Purpose | Key flags |
|---|---|---|
| `kix build <cluster>` | Render manifests to stdout (yaml/json) | `-o yaml|json` |
| `kix diff <cluster>` | Diff vs live, or vs a directory (previous build result, snapshot, export) | `--from <dir>`, `-o markdown` |
| `kix check <cluster>` | Eval (constructor validators, cross-resource checks, scorecard errors) + schema tools + scorecard report | `--sarif` |
| `kix deploy <cluster>` (alias `apply`) | Wave-based apply with confirmation | `-y`, `--dry-run`, `--reconcile`, `--prune`, `--operator`, `--tui`, `--log-format=line|json|pretty` |
| `kix status <cluster>` | Resource health table | `--operator` (group by package) |
| `kix list clusters` | List flake clusters | |
| `kix list packages` | List registered packages | `--cluster <name>` |
| `kix graph <cluster>` | DAG visualization | `--format tree|dot|json` |
| `kix inspect <cluster>` | Cluster structure summary | |
| `kix gc <cluster>` | Garbage-collect stale resources; retire old Activation records | `--hard`, `--operator`, `--keep N` (always keep the N newest, default 10), `--keep-max N` (never more than N, default 50), `--keep-for 30d` (retire older, default 30d, `0` off), `--include-unstamped`, `-y` |
| `kix rollback <cluster>` | Roll back to a previous activation | `-y`, `--dry-run`, `--prune`, `--list`, `--operator` |
| `kix health <cluster>` | Drift detection vs live | |
| `kix snapshot save <dir>` | Dump live cluster state | |
| `kix logs <package>` | Shell-out to `kubectl logs` for the package's primary workload | `-f`, `--tail`, `--since`, `-c`, `-p` |
| `kix pf <package> <port>` | Shell-out to `kubectl port-forward` | `--address` |
| `kix images <cluster>` | List all container images (pull-friendly) | `--sources`, `-o json` |
| `kix export <cluster> --out <dir>` | Plain-YAML export for handoff | `--for=exit|audit` |
| `kix sbom <cluster>` | CycloneDX 1.6 SBOM | |
| `kix attest <cluster>` | SLSA v1 provenance | `--builder-id`, `--invocation-id` |
| `kix audit <cluster>` | Compliance bundle (SARIF + SBOM + provenance + OSCAL + report) | `--out` |
| `kix completions <shell>` | Generate completions | bash/zsh/fish |

**Global flags:** `-o text|json|yaml`, `-v|-vv|-vvv`, `-q`, `--no-color`, `--context <ctx>`, `--flake <path>`, `--no-cache` (bypass SQLite eval cache).

**Env vars:** `KIX_LOG` overrides the log-filter (RUST_LOG syntax). Apiserver transport (every command and the operator share one policy; defaults suit a cluster mid-incident, override only to debug): `KIX_RETRY_ATTEMPTS` total attempts per request (default 7, `1` disables retries), `KIX_SWEEP_CONCURRENCY` parallel LISTs in the managed-resource sweep (default 16), `KIX_REQUEST_TIMEOUT` per-attempt deadline in seconds for non-watch requests (default 120, `0` none), `KIX_CONNECT_TIMEOUT` TCP connect timeout in seconds (default 15), which also sets the deadline for the first-contact probe (`KIX_PREFLIGHT=0` skips it), `KIX_STALL_TIMEOUT` seconds of no progress before `kix deploy` gives up (default 600, `0` never; a `stalled:` line naming every resource in flight, its phase and its age prints after 30s of no progress regardless). Retries: 429 always, with `Retry-After` honoured; 5xx and connection loss only for idempotent requests (GET, DELETE, PATCH including server-side apply). A request that still fails after the retries is an error, never an empty result: `diff`, `deploy` and `gc` refuse to plan from a partial view of the cluster. Resource types the account may not list (403) are reported, not hidden. First contact: every command proves the apiserver answers before doing anything else, so an unreachable cluster fails in seconds with the endpoint named instead of hanging on whatever request happened to run first. A refused port fails in 0.1s, a blackholed address in 15s, and an endpoint that completes the handshake and then goes silent in 20s.

**Exit codes:** `0` success; `1` error / failed resources; `2` differences detected (diff).

## 4. The eval pipeline

```
flake.nix → mkFlake.nix → buildCluster (eval/cluster.nix)
  → evalModules (modules.nix)            # merge cluster config
  → auto-instantiate (eval/auto.nix)     # activate optionals + transitive deps
  → resolution index (eval/resolve.nix)  # DNS-like DI map
  → phase-1 pre-pass                     # introspect packages, inject config
  → nested fixpoint: evaluateInstance (eval/instance.nix)
      → scope (eval/scope.nix) → build() → collect → closure
      → netpol.processInstance, scorecard
  → aggregate manifests, stamp deps, build PackageInstance + Activation CRs
  → mkManifests → YAML dir
```

**Two-phase package calling.** Packages are called twice. Phase 1 introspects the
build function's args to resolve DI targets and lets deps inject config (e.g.
prometheus inserts a ServiceMonitor; storage forwards the storage class). Phase
2 (inside `builtins.fix`) binds real instances by name and calls `build`.

**DNS-like DI resolution.** A package requests deps by build-arg name
(`{ vault, ... }`). The resolver walks: explicit override → same-namespace match
→ cluster-wide unambiguous match → arg default → error. Aliases (instance-level
or package `meta.defaultAliases`) participate in the index. Managed instances
beat imports.

**Platform imports are shadowable.** Flavors declare e.g. `platform-dns` via
`kix.mkImport`. If the cluster installs its own coredns under
`instances.kube-system.coredns`, the explicit instance wins. Breaks otherwise
circular bootstrap dependencies.

Read `kix/lib/architecture.md` for the full set of non-obvious patterns
(store-path = DAG edge, `_type` marker = leaf, `_kix.*` internal metadata,
capability ownership, etc.).

## 5. Package authoring contract

A package is a function `{ scope, lib, kix, ... }: { meta?, options?, deps?, build }`.

```nix
# kix/packages/<pkg>/default.nix
{ scope, lib, kix }:
let
  name = scope.instanceName;
in
{
  meta = {
    version       = "1.2.0";
    description   = "Short, single-line.";
    owner         = "team-name";              # used by scorecard governance.hasOwner
    lifecycle     = "stateless";              # "stateless" (default) | "stateful" | "durable" | "ephemeral"
    scope         = "namespace";              # "cluster" (default) | "namespace"
    roles         = [ "storageClasses" ];     # infra-role claim — closed registry (kix/lib/eval/roles.nix); role name doubles as a DI alias. Infra packages only.
    defaultAliases = [ "storage" ];           # DI aliases when no instance-level aliases set
    conflictsWith         = [ "alt-pkg" ];    # same-namespace mutual exclusion
    "cluster:conflictsWith" = [ "alt-cni" ];  # cluster-wide mutual exclusion
    compatibleWith.database = {               # advisory compat declarations
      reason = "requires the vchord extension";
    };
  };

  # Per-dep diagnostics — co-located with the dep.
  deps = {
    database.config = { ... };                # config injection forwarded to the dep
    database.assertions = dep: lib.optional (...) { assertion = false; message = "..."; };
    database.warnings   = dep: lib.optional (...) "soft warning";
    storage.warnings    = dep: lib.optional (kix.parseGi (dep.out.size or "0") < 50)
      "library storage is ${dep.out.size}; recommended >= 50Gi";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { repository = "myapp/server"; tag = "v1.0.0"; pullPolicy = "IfNotPresent"; };
    };
    replicaCount = lib.mkOption { type = lib.types.int; default = 1; };
    ingress = kix.options.ingress;            # standardized { host, annotations }
    metrics = kix.options.monitor;            # standardized { enabled, interval }
  };

  build = [
    # Build is a function OR a list of functions. As a list, each entry's deps
    # are discovered independently and results are merged into the parts attrset.
    # This is how kix.expose / kix.monitor compose — they're build entries that
    # declare their own DI deps.
    ({ self, config, clusterConfig, postgres, storage, scope, kix, machineLearning ? null, prometheus ? null, ... }:
    let
      healthCheck = { httpGet.path = "/health"; httpGet.port = "http"; periodSeconds = 10; };
    in
    {
      libraryMount = kix.mount.pvc storage { mountPath = "/data"; };

      deployment =
        {
          name = "${name}-server";
          spec = {
            replicas = config.replicaCount;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [{
              name = "server";
              image = "${config.image.repository}:${config.image.tag}";
              env = kix.mkEnv
                {
                  DB_HOST = postgres.out.fqdn;
                  DB_PORT = postgres.out.port;
                  ML_URL  = if machineLearning != null then "http://${machineLearning.out.fqdn}" else null;
                }
                # Pull credentials from the dep's local Secret — no cross-ns reads.
                (postgres.out.credentials.out.mkEnv {
                  DB_USERNAME = "username";
                  DB_PASSWORD = "password";
                });
              ports = [ (kix.port "http" 8080) ];
              livenessProbe = healthCheck;
              readinessProbe = healthCheck;
            }];
          };
        }
        |> kix.withMounts [ self.libraryMount ]
        |> scope.mkDeployment;

      service = self.deployment |> kix.service.fromWorkload { name = "${name}-server"; } |> scope.mkResource;

      root = self.service;          # entry point — resources reachable via self.* are auto-tracked
    })

    # Composable build entries declare their own deps:
    (kix.expose  { service = "service"; })
    (kix.monitor { service = "service"; port = "metrics"; })
  ];
}
```

### 5.1 Build args

| Arg | Provided by | Use |
|---|---|---|
| `self` | fixpoint | Lazy-recursive ref to this build entry's return attrset (for cross-resource refs) |
| `config` | NixOS module eval | Evaluated per-instance options |
| `clusterConfig` | cluster eval | The cluster's full `config.*` (e.g. `clusterConfig.cluster.domain`) |
| `scope` | per-instance | The scope object (see §6) |
| `lib` | nixpkgs | Standard nixpkgs lib |
| `kix` | from `compose.nix` | Composition helpers (see §9) |
| `deps` | resolution | All resolved DI deps as a single attrset (rarely needed — usually destructure individual deps as args) |

DI dep args: `{ requiredDep, optionalDep ? null, ... }`. The `?` default makes a dep optional. System args (`self`, `config`, `clusterConfig`, `scope`, `lib`, `kix`, `deps`) are stripped during dep discovery; everything else is treated as a DI dep.

### 5.2 `self` and dependency tracking

- `"${self.x}"` — reads the resource's outPath and creates a Nix store-path edge in string context. **Names** in K8s manifests are real names (not store paths) — see §8. Use `self.x.out.name` instead of `"${self.x}"` when you need a string for use in spec/data fields.
- `self.x.out.name`, `out.fqdn`, `out.selector` — these all carry the resource's store-path context, so reading them creates a DAG edge.
- `requires = [ self.x ]` — explicit dependency edge that isn't reached via string interpolation. Use for label-based references (Service selector, PDB, NetworkPolicy) or for ordering against resources whose store path you wouldn't otherwise see.
- `extraDeps = [ self.x ]` — same as `requires` but tagged differently in the `kix.run/depends-on` annotation. Use when the edge is structural rather than "requires this to exist before me".
- `rawSelector` — workload-only escape hatch that exposes `spec.selector.matchLabels` without forcing the workload's store-path context. Use when reading `out.selector` would create a cycle. Trade-off: the consumer loses the workload DAG edge — `scorecard:architecture.selectorCoherence` fires to keep the workaround visible.

### 5.3 Warning system

`scope.mkDeployment`/`mkStatefulSet`/`mkDaemonSet` emit `builtins.trace` warnings for:

- **Redundant requires** — resource is already reached via `"${self.x}"`; drop from `requires`.
- **Duplicate requires** — same resource listed twice.
- **Orphaned resources** — defined in `self` but unreachable from `root`.

Fix all warnings before committing.

### 5.4 Inline-attrset packages

Test fixtures and one-off cluster-inline packages can skip the function wrapper:

```nix
# Inline package — no { scope, lib, kix }: wrapper needed
package = {
  meta.version = "0.0.1";
  build = { self, config, scope, ... }: { root = scope.mkResource { ... }; };
};
```

Use this only for fixtures and inline cluster definitions. Files in `kix/packages/` are always function packages.

## 6. `scope` API

`scope` is the per-instance context. It carries the instance name, namespace, label conventions, and resource builders. Symbols:

### 6.1 Read-only fields

| Field | Type | Notes |
|---|---|---|
| `scope.instanceName` | string | The instance name from the cluster definition |
| `scope.namespaceName` | string | The namespace this instance lives in |
| `scope.namespace` | resource | The Namespace resource itself (use as a dep) |
| `scope.selectorLabels` | attrset | Default selector labels — overridable per-instance via `selectorLabels` in cluster config |
| `scope.labels.selector` | attrset | Lazy alias for `selectorLabels` |
| `scope.labels.common` | attrset | `selectorLabels // instanceLabels` |
| `scope.labels.clusterScoped` | attrset | Defaults for cluster-scoped resources |
| `scope.labelStyle` | enum | `"kix"` (default) or `"helm"` (Helm-compatible labels) |
| `scope.namespaces` | attrset | All cluster namespaces (rarely needed) |

### 6.2 Resource builders

| Symbol | Signature / Notes |
|---|---|
| `scope.mkResource attrs` | Create a namespaced K8s resource — see §7 for fields |
| `scope.mkClusterResource attrs` | Same, cluster-scoped (omits `metadata.namespace`) |
| `scope.mkDeployment attrs` | Workload wrapper. Sets apiVersion/kind, copies `selector.matchLabels` to `template.metadata.labels`, validates, runs per-workload CNP generation. Pipe-friendly. `name` required. |
| `scope.mkStatefulSet attrs` | Same; expands `headlessService` shorthand (auto-creates the headless Service) |
| `scope.mkDaemonSet attrs` | Same |
| `scope.mkJob attrs` | Same; no selector enforcement |
| `scope.mkHelmWorkload attrs` | Helm-sourced workload (used internally by `importChart`). Runs the pod-spec validators `mkDeployment` runs, except the DI-tracked reference check: chart names are plain strings, and the cross-resource checks resolve them instead |
| `scope.mkOptional cond builder` | Gate a resource on a boolean. `builder` may be a thunk `(_: ...)` to avoid eager eval when `cond` is false |
| `scope.mkSecret { ... }` | Secret with enriched `out` (see §21). **Always** use this instead of `scope.mkResource { kind = "Secret"; }` |
| `scope.mkSecretRef { ... }` | Reference an externally-managed Secret (Vault, ESO, cert-manager). Emits a PackageInstance import marker; deploy verifies the Secret exists before applying dependents. See §21 |
| `scope.mkServiceRef { name, selector, ports, labels?, requires? }` | Reference an externally-managed Service (operator-provisioned). `out.{name, fqdn, port, labels}` carry context (`out.fqdn` is `${name}.${ns}.svc.${clusterDomain}`, the same form as a rendered Service); `out.{selector, ports}` are the declared shapes. The marker is Ready when the Service has ready endpoints |
| `scope.mkWebhookService { ... }` | Builds Service + ValidatingWebhookConfiguration + MutatingWebhookConfiguration in one call |
| `scope.mkCRD spec` | Create a CustomResourceDefinition. Pair with `crd.fromKind` builders (§22) |
| `scope.mkCRDRef { kind; ... }` | CRD marker (no CRD resource). Use when the CRD is owned externally |
| `scope.mkCR { ... }` | Create a custom resource instance. Auto-routes by CRD scope |
| `scope.crd` | Module: `fromKind`, `clusterScoped`, `withVersion`, `withShortNames`, `withCategories`, `withPrinterColumns`, `withSchema`, `withLabels` (§22) |

### 6.3 Cross-cutting

| Symbol | Notes |
|---|---|
| `scope.forNamespace nsName` | Returns a new scope bound to a different namespace. Use when emitting resources that must live in another namespace (e.g. paired ingress CNP in the callee's ns) |
| `scope.helm` | Helm bridge: `fetchHelmChart`, `importChart`, etc. (§12) |
| `scope.rbac` | RBAC DSL (§11) |
| `scope.checkCapability capabilities cap message` | Lazy capability check; throws if `capabilities.${cap} == false` |
| `scope.augmentEdge passengers value` | Stamp a list of resources' context onto a string value (manual edge construction) |
| `scope.augmentAllEdges passengers outAttrs` | Apply `augmentEdge` to all string fields of an attrset |
| `scope.forwardEdges dep passengers` | Forward a dep's service edges with context merge — used when a sibling needs the same edges |

## 7. `mkResource` field reference

```nix
scope.mkResource {
  apiVersion = "apps/v1";    # required
  kind       = "Deployment"; # required
  name       = "...";        # required
  spec       = { ... };
  data       = { ... };      # ConfigMap
  stringData = { ... };      # Secret (prefer scope.mkSecret — see §21)
  labels      = { ... };     # merged into metadata.labels (cluster + managed-by added automatically)
  annotations = { ... };     # merged into metadata.annotations
  outputs     = { ... };     # named values exposed via .out — name/fqdn/identityHash/selector are auto-derived
  requires    = [ ... ];     # explicit dep edges not visible via string interpolation
  extraDeps   = [ ... ];     # additional dep edges (tagged "extra:" in kix.run/depends-on)
  extra       = { ... };     # top-level passthrough for fields kix doesn't model (e.g. `rules` for ClusterRole, `provisioner` for StorageClass)
  clusterDomain = "...";     # rarely overridden — comes from clusterConfig.cluster.domain
}
```

**`extra.*` shadowing check.** `extra` may NOT redefine `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, `spec` (when `spec != {}`), `data` (when `data != {}`), `stringData` (when `stringData != {}`). The check fires at eval time with a remediation hint. `metadata.labels` and `metadata.annotations` are deliberately allowed because they merge additively with scope-injected values.

**Namespace handling.** `mkResource` doesn't take a namespace arg directly — it comes from `scope`. `mkClusterResource` sets the cluster-scoped sentinel, which omits `metadata.namespace`.

**Manifest normalization (the collapse rule).** Rendering strips nulls bottom-up. A container that had members and lost them all collapses to null and is omitted, and the collapse cascades upward through wrappers. A container written literally empty (`emptyDir = { };`, `ingress = [ ];`) renders as `{}`/`[]`: empty values are meaningful to Kubernetes (an empty volume source selects `emptyDir`; an empty label selector matches everything; `subresources.status = { };` enables the subresource). Null list elements are dropped, and an element that collapses entirely leaves its list. The one trap: a constructor that builds a presence-meaningful container from optional arguments that are all null collapses, and the field disappears without an error. Such constructors must either filter their own nulls (`lib.optionalAttrs`, as `kix.mount.emptyDir` does) or wrap the result in `kix.keep` (§9.1). The `volumeHasSource` scorecard rule (severity error) catches the volume case at build time.

## 8. Resource `out` reference

Every resource exposes `out.*` carrying the resource's store-path context, so reading any `out` field creates a DAG edge.

| Field | Auto-derived | Notes |
|---|---|---|
| `out.name` | yes | Real K8s name + context. Prefer over `"${resource}"` string interpolation |
| `out.fqdn` | yes | `${name}.${ns}.svc.${clusterDomain}` (or just `${name}` for cluster-scoped) |
| `out.identityHash` | yes | The blake3 32-char store hash. Used in `kix.run/identity-hash` |
| `out.selector` | yes (when present) | Auto-derived from `spec.selector.matchLabels` → `metadata.labels` → null. Each label value carries context |
| `out.ports` | Service only | The raw `spec.ports` list |
| `out.url { scheme?, port? }` | Service only | URL builder. Default port = first entry in `spec.ports` |
| `out.<custom>` | from `outputs = { ... }` arg | User-defined named outputs. `null` values **suppress** auto-derived fields (e.g. `outputs.fqdn = null` to hide it) |

**Why `out.name` over `"${self.x}"`:** `"${self.x}"` evaluates to the store path string and is unsuitable as a K8s name. The `out.*` form is a real K8s name with context; the store-path edge is preserved by Nix's string-context system.

**Workload `rawSelector`.** `workload.rawSelector` exposes `spec.selector.matchLabels` without forcing the workload's store-path context. The consuming resource does not gain a DAG edge to the workload. Use only to break cycles (see §27).

**`out` extension patterns.** Capability-providing packages expose builders/transformers on `out`:

```nix
# Plain value:           storageClasses.out.storageClassName
# Transformer (composes): clusterIssuer.out.withCert ingressResource
# Builder (creates):     prometheus.out.mkServiceMonitor scope { name; spec; }
# Secret helpers:        secret.out.keyRef "key"
#                        secret.out.mkEnv { ENV_NAME = "key"; }
#                        secret.out.envFrom
#                        secret.out.volume "vol-name"
```

## 9. `kix` composition helpers

The `kix` arg to packages comes from `compose.nix` (`kixlib`).

### 9.1 Primitives

| Symbol | Signature |
|---|---|
| `kix.port name containerPort` | `→ { name, containerPort, protocol = "TCP" }` |
| `kix.mkEnvVars { K = "v"; OPT = null; }` | `→ [{ name, value }]`. Null values filtered (`lib.optionalAttrs` plays nicely). |
| `kix.mkEnv attrs rawList` | `(mkEnvVars attrs) ++ rawList`. Combines named env vars with raw entries (e.g. `valueFrom.secretKeyRef`) |
| `kix.parseGi "50Gi"` | `→ 50` (number). Supports `Ti`/`Gi`/`Mi`. Strips Nix string context so it works on `dep.out.size` |
| `kix.untrackedRef "name"` | Escape hatch: a string carrying an "untracked" context marker. Use when referring to resource names not managed by kix (Helm hook secrets, cert-manager-issued secrets, etc.). Bypasses the DI-tracking check in `mkDeployment`. The marker is inert: it satisfies the ref check and is filtered out of `kix.run/depends-on`, so it never becomes a deploy-ordering edge |
| `kix.keep container` | Marks an attrset "never collapse to absent": it renders as `{}` even when every member is null, and the protection survives later merges that introduce fresh nulls (additive `_kixKeep` marker, resolved at `mkResource`, never rendered). Lists are normalized eagerly instead, since merges replace lists whole. Use in constructors of presence-meaningful fields (`emptyDir`, selectors) built from optional arguments; a hand-written empty needs no keep, a literal `{ }` renders as-is (§7) |

### 9.2 Mounts

Each `kix.mount.*` returns `{ _type, name, mountPath, source, ... }` or `null` when the resource arg is `null` (so disabled features cleanly skip).

| Function | Signature |
|---|---|
| `kix.mount.pvc resource { mountPath, name?, readOnly?, subPath? }` | PVC mount |
| `kix.mount.configMap resource { mountPath, name?, readOnly?, subPath?, items?, defaultMode? }` | ConfigMap mount |
| `kix.mount.secret resource { mountPath, name?, subPath?, items?, defaultMode? }` | Secret mount |
| `kix.mount.emptyDir { mountPath, name, medium?, sizeLimit?, subPath? }` | Ephemeral mount (no resource arg; `name` required) |

Volume names auto-derive from `resource.out.name`. Sources carry a `_kix.namespace` marker that `checkNamespacedRefs` reads to enforce same-namespace mounts at build time, then `stripKixMeta` strips it before serialization.

| Function | Signature |
|---|---|
| `kix.withMounts [ m1 m2 ... ]` | Inject mounts into a single-container pod spec. Nulls filtered. Errors on multi-container pods |
| `kix.withMountsOn "containerName" [ ... ]` | Target a specific container by name (multi-container pods) |

Both errors-out on duplicate volume names. Pipe pre-seal: `attrs |> kix.withMounts [...] |> scope.mkDeployment`.

### 9.3 Service / Ingress / HTTPRoute helpers

| Symbol | Signature |
|---|---|
| `kix.service.extractPorts workload` | Extract service port entries from a workload's container spec |
| `kix.service.fromWorkload { name, type?, ports?, outputs?, ... }` | Pre-seal Service attrset from a workload. Auto-derives selector from `workload.out.selector` and ports from container spec. **Validates** that any user-supplied string `targetPort` matches a named container port. Pipe to `scope.mkResource` |
| `kix.ingress.fromService { name, host, path?, pathType?, port?, className?, tls? }` | Pre-seal Ingress from a Service. Auto-derives backend name + port |
| `kix.httpRoute.fromService { name, host, parentRef, path?, pathType?, port? }` | Pre-seal HTTPRoute (Gateway API) from a Service |

Where `parentRef` is `{ name, namespace? }` — typically `gateway.out.gatewayRef`.

### 9.4 Composable build entries

These return functions whose own DI args are auto-discovered.

**`kix.expose`** — auto-creates `Ingress` or `HTTPRoute` based on which DI dep is wired:

```nix
(kix.expose {
  service ? null,                # string: part name in self (single-backend mode)
  paths ? null,                  # list of { path, pathType?, service, port? } (Ingress multi-backend)
  partName ? "ingress",          # name of the generated part in self
  defaultAnnotations ? {},       # package-level Ingress annotations
  port ? null,                   # override auto-derived service port
  tlsSecretName ? null,          # tracked string (must come from kix.untrackedRef or x.out.name)
  tlsSecret ? null,              # k8s-resource — preferred form, enables ns validation
  tlsSecretPart ? null,          # string: part name in self resolving to the secret
})
```

- `gateway` DI dep present → emits `HTTPRoute` (TLS is the Gateway's concern).
- `ingressNginx` DI dep present → emits `Ingress` with optional TLS via `clusterIssuer`.
- Both present → fail loudly (ambiguous; cluster must wire exactly one).
- Neither present → no exposure resource emitted.
- `service` and `paths` are mutually exclusive. `paths` is Ingress-only.
- TLS-secret cross-namespace check fires at build time — K8s ingress controllers only read TLS secrets from their own namespace.

**`kix.monitor`** — auto-creates `ServiceMonitor` + optional `PrometheusRule` when `prometheus` DI dep is present:

```nix
(kix.monitor {
  service,                       # string: part name in self
  port ? "metrics",              # name (string) or number (int)
  path ? "/metrics",
  alerts ? {},                   # { alertName = { expr, "for"?, severity?, description?, summary?, runbook_url?, labels?, annotations? }; }
  extraEndpoints ? [],
  extraLabels ? {},
})
```

The builder consumes `prometheus.out.mkServiceMonitor` and `prometheus.out.mkPrometheusRule` — those are exposed by the prometheus package's `out`. `metrics.enabled` and `metrics.interval` are read from `config.metrics` (use `options.metrics = kix.options.monitor;`).

**`kix.healthCheck`**: a post-deploy probe, a Job in the package's namespace that runs a script against addresses passed in as env vars from `out.*` values. Every callback receives the same `{ self, config, deps }`.

```nix
(kix.healthCheck {
  script,                        # the probe body, usually builtins.readFile ./health-check.py
  env ? (_: {}),                 # -> { NAME = value; }; nulls dropped; RETRY_FOR is added by the helper
  when ? ({ config, ... }: config.healthCheck.enable or true),     # false renders nothing
  retryFor ? ({ config, ... }: config.healthCheck.retryFor or 90), # seconds the script keeps re-checking
  requires ? (_: []),            # -> resources the probe waits for beyond the package root (always waited for)
  partName ? "healthCheck",      # parts rendered: <partName> (Job), <partName>Script (ConfigMap)
  runtime ? kix.healthCheck.runtimes.python,  # { image = { repository; tag; digest; }; file; interpreter; env; }
  activeDeadlineSeconds ? null,  # null: retryFor + roundBudget (90); given, it must leave that room
  ttlSecondsAfterFinished ? 3600,
})
```

- The script lives in a ConfigMap named `<instance>-health-script`, mounted read-only at `/probe`; the Job runs `interpreter ++ [ "/probe/<file>" ]`. `runtimes.python` is `docker.io/library/python:3.13-slim` pinned by digest (standard library only); `runtimes.shell` is `curlimages/curl`. Bump a digest with `crane digest <repository>:<tag>`.
- Env values from `out.*` carry the dependency edges: the Job runs after its targets are ready, and under a network-policy enforcer it gets the same egress edge a real consumer gets. The Job also always waits for the package root, so it runs after the package it belongs to; `requires` adds to that. `deps` is every dependency-injected package some entry of the package declares (`deps.vmCluster.out.serviceUrl`); the probe entry itself declares none.
- The helper owns the time budget. It hands the script its retry window as `RETRY_FOR` and sizes `activeDeadlineSeconds` to that window plus `kix.healthCheck.roundBudget` (90 s, one worst-case round of checks), because the Job deadline deletes the pod and leaves no output. A given deadline that leaves less room fails the build. The script's side: give up once `RETRY_FOR` has passed, keep a round under the budget. `when` and `retryFor` default to the option set `kix.options.healthCheck` (§9.5) when the package declares it.
- The Job carries `kix.run/rerun: on-change` (`core/annotations.nix`, shared with check 16). The deploy engine deletes and recreates it whenever its identity hash differs from the one the cluster last ran, or when the live Job failed. So under `kix deploy` and `kix rollback` the probe runs again when it, or anything upstream of what it checks, changes, and never otherwise. A deploy that changes nothing skips it, unless the last run failed; to force a run, change an input such as the retry window. The operator diffs against live objects, so after `ttlSecondsAfterFinished` has reaped a finished Job the operator's next reconcile runs the probe again; it never retries a failed one on its own.
- A failing probe fails the deploy like a pod that never came up, and the last lines it printed are shown under the failure.
- The probe pod carries its own labels (`app.kubernetes.io/name: <instance>-health`), never the package's selector labels, so no Service routes traffic to it (check 15 below guards this). It runs as user 65534 with a read-only root filesystem, no capabilities and no service account token, and passes the stock security rules at error.

Example, from the victoria-metrics-agent package:

```nix
options.healthCheck = kix.options.healthCheck // { maxSampleAge = lib.mkOption { ... }; };

(kix.healthCheck {
  env = { self, config, deps, ... }: {
    VMSELECT_URL = deps.vmCluster.out.serviceUrl;
    AGENT_JOB = self.vmAgent.out.scrapeJob;        # structural outputs the operator package
    AGENT_REPLICAS = self.vmAgent.out.replicas;    # states on the CR (kix.facts.structural)
    MAX_SAMPLE_AGE = toString config.healthCheck.maxSampleAge;
  };
  script = builtins.readFile ./health-check.py;
})
```

The probe reads what it expects off the resource it checks, never off the option that produced it: `config.replicaCount` is what the author asked for, `self.vmAgent.out.replicas` is what the CR says after `extraSpec` had its way.

### 9.5 Reusable option sets

```nix
options.ingress = kix.options.ingress;       # { host = nullOr str; annotations = attrsOf str; }
options.metrics = kix.options.monitor;       # { enabled = bool (default true); interval = nullOr str; }
options.healthCheck = kix.options.healthCheck;  # { enable = bool (default false); retryFor = int (90) }; kix.healthCheck reads both

# A package's image. Takes the defaults, returns one mkOption whose type is a
# submodule: { repository, tag, digest = null, pullPolicy = "IfNotPresent",
#              sourceRev = null, promotedBy = null, resolvedAt = null }
options.image = kix.options.image {
  repository = "docker.io/library/nginx";
  tag = "1.27-alpine";
};
```

Use these in your package's `options` so cluster authors see consistent shapes across packages.

## 10. Top-level `kix.*`

These come from `kix.lib` (top-level), distinct from the per-package `kix` arg (`kixlib`).

| Symbol | Signature / Use |
|---|---|
| `kix.buildCluster { name, modules, specialArgs? }` | Top-level cluster orchestrator. Returns `{ activation, instances, namespaces, rawManifests, ... }` |
| `kix.mkEnv envName envConfig instanceSets` | Stamp instance sets into env-prefixed namespaces (§18) |
| `kix.mergeFragments { fragments, namespacePolicies? }` | Merge multiple cluster fragments. Instance collisions error; namespace configs deep-merge |
| `kix.helmChart { repo, name, version, hash, releaseName?, includeCrds?, strip?, patchResources? }` | Tier-1 inline Helm chart (§12) |
| `kix.mkImport { from?, out? }` | Import marker — DI prefers managed > import (§23) |
| `kix.flavors.{k3s,kind,kubeadm,eks,gke,gke-autopilot,aks,openshift,rke2,talos,lithus}` | Platform flavor modules (§15) |
| `kix.modules.monitoring` | Reusable Prometheus/Grafana/Loki module (see `kix/lib/modules/monitoring.nix`) |
| `kix.rules.{security,reliability,governance,architecture}` | Built-in scorecard rule sets (§17) |
| `kix.pins <path>` | Read a committed pin file (JSON): `{ get, ref, keys, all }`. Usually unnecessary: declare `pins = ./pins.json;` in `mkFlake` and take a `pins` argument (§29) |
| `kix.image.ref <image>` | Render `repository:tag[@digest]` (§29) |
| `kix.peekPackageMeta` | Extract package meta without full evaluation (used by tooling) |

The `kixlib` helpers (port, mkEnvVars, mount.*, withMounts, service.fromWorkload, expose, monitor, options.*, etc.) are passed to each package as the `kix` arg by the eval pipeline — see §9. They're also accessible at top level via `kix.kixlib.*`.

## 11. RBAC DSL

```nix
{ scope, lib, kix }:
let
  inherit (scope.rbac) core group grant watch reconcile own readWrite full emit allow restrictTo sub mkClusterRoleSet mkRoleSet;
  apps = group "apps" [ "deployments" "daemonsets" "statefulsets" ];
in
{
  build = { self, ... }: let
    clusterRoles = mkClusterRoleSet scope {
      subjects = [{ kind = "ServiceAccount"; name = self.serviceAccount.out.name; namespace = scope.namespaceName; }];
      roles = {
        "${name}-role" = {
          bindingName = "${name}-binding";
          rules = grant [
            ([ core.secrets core.configmaps ] |> watch)
            ([ apps.deployments apps.daemonsets ] |> allow [ "list" "get" "update" "patch" ])
            (core.events |> emit)
            (core.pods |> restrictTo [ "specific-pod" ] |> allow [ "delete" ])
            (core.pods |> sub "status" |> allow [ "patch" ])
          ];
        };
      };
    };
  in { ... } // clusterRoles;
}
```

### 11.1 Groups

- `group apiGroup [ "resources" ]` — produces `{ resourceName = ref; ... }` plus a `__functor` fallback so `(group "..." [...]) "resourceName"` works for dynamic access.
- `core` — pre-populated group for the core API (`""`). Includes `configmaps`, `pods`, `secrets`, `serviceaccounts`, `services`, `endpoints`, `namespaces`, `nodes`, `persistentvolumeclaims`, `events`, etc.

### 11.2 Ref modifiers (Ref → Ref)

| Modifier | Effect |
|---|---|
| `restrictTo [ "name1" "name2" ]` | Scope to specific resource names (`resourceNames` rule field) |
| `sub "status"` | Sub-resource access (e.g. `pods/status`, `deployments/scale`) |

### 11.3 Intents (Ref or [Ref] → [Rule])

| Intent | Verbs |
|---|---|
| `watch` | get, list, watch |
| `reconcile` | watch + patch/update on resource and `status` sub-resource |
| `finalize` | update on `finalizers` sub-resource |
| `own` | get, list, watch, create, delete |
| `readWrite` | get, list, watch, create, update, delete |
| `full` | get, list, watch, create, update, delete, patch |
| `emit` | create, patch |
| `watchAndFinalize` | watch + finalize |
| `allow [ "verb1" "verb2" ]` | Custom verb list |

### 11.4 Builders

- `grant [[Rule]]` — flatten and merge rules by `(apiGroups, verbs, resourceNames)`; concatenate `resources` lists.
- `mkClusterRoleSet scope { subjects, labels?, roles }` — returns `{ "<role>" = ClusterRole; "<binding>" = ClusterRoleBinding; ... }`. Spread into the build return via `// clusterRoles`. Each role can be either `[Rule]` or `{ rules; bindingName?; }`.
- `mkRoleSet scope { subjects, labels?, roles }` — namespace-scoped equivalent.

## 12. Helm tiers

Three tiers, in order of control:

### 12.1 Tier 1 — inline `kix.helmChart` (cluster files)

```nix
# clusters/<name>/services.nix
instances.homeassistant.homeassistant = {
  package = kix.helmChart {
    repo = "https://pajikos.github.io/home-assistant-helm-chart";
    name = "home-assistant";
    version = "0.3.51";
    hash = "sha256-...";
    releaseName = "homeassistant";
    patchResources = map (r: ...);   # optional pre-wrap transform
  };
  config.values = {
    ingress.enabled = false;          # values are deep-merged with kix.helmChart's defaults
    persistence = { enabled = true; size = "5Gi"; };
  };
};
```

`kix.helmChart` returns an inline package with `options.values` (deep-merged with package-level defaults at eval). Auto-selects root via `Service > Deployment > StatefulSet > first`.

### 12.2 Tier 2 — package using `scope.helm.importChart`

For full DI control, custom root selection, CRD refs, capability declarations, intra-chart patching, and dep config injection:

```nix
# kix/packages/<pkg>/default.nix
{ scope, lib, kix }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "oci://registry-1.docker.io/bitnamicharts";
    name = "valkey";
    version = "1.2.3";
    hash = "sha256-...";
  };
in
{
  meta.version = "1.2.3";
  options = { values = lib.mkOption { type = lib.types.anything; default = {}; }; };
  build = { config, scope, ... }:
    let resources = scope.helm.importChart {
      inherit chart scope;
      values = config.values or {};
      releaseName = scope.instanceName;
    };
    in resources.mkParts {
      root = resources.get "Deployment" "valkey";
      out = { ... };
    };
}
```

The collection returned by `importChart` exposes:

| Method | Use |
|---|---|
| `all` | Flat `[Resource]` |
| `get kind name` | Lookup; throws if missing |
| `find kind name` | Lookup; null if missing |
| `byKind kind` | Filter by kind |
| `workloads` | All Deployment/StatefulSet/DaemonSet/Job/CronJob |
| `excluding [ ... ]` | All resources except given list |
| `attrs` | Resources keyed by `"${toLower kind}-${name}"` |
| `depsOf resource` | Inferred internal deps (from `helm-dag.nix`) |
| `edges` | All link edges (`{ from, to, type }`) |
| `autoRoot` | Auto-selected root |
| `mkParts { root, extraParts?, extraRequires?, out? }` | Build complete parts tree |

`importChart` strips `helm.sh/*`, `meta.helm.sh/*`, `app.kubernetes.io/managed-by: Helm`, default strategy/updateStrategy, and test hooks. Foreign-namespace resources are respected when explicitly set.

### 12.3 Tier 3 — native package (no Helm)

Full DSL control. Use when the upstream chart is too large/complex/messy or you want to express the package idiomatically. Reference: `kix/packages/reloader/` (single Deployment + RBAC).

## 13. Cluster definition

Two shapes:

### 13.1 Single-file cluster

```nix
# clusters/<name>.nix
{ kix, packages }:
kix.buildCluster {
  name = "<name>";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.k3s
    {
      cluster.domain = "lab.local";
      availablePackages = packages;          # enables auto-instantiation
      instances.<ns>.<inst> = {
        package = packages.<pkg>;
        config = { ... };
      };
    }
  ];
}
```

### 13.2 Module-based (production clusters)

Each module is a NixOS-style function `{ config, lib, ref, packages, kix, ... }: { options?, config?, imports? }`. See `ludo/` for a clean example: `flake.nix` → `cluster.nix` (real) and `cluster-kind.nix` (kind variant) → `base.nix` → `platform.nix` + `services.nix`.

```nix
# ludo/base.nix
{ packages, kix, ... }:
{
  imports = [ ./platform.nix ./services.nix kix.modules.monitoring ];
  availablePackages = packages;
  cluster.domain = "ludo.lan";
  clusterLabels = { "app.kubernetes.io/part-of" = "ludo"; };
  monitoring = { enabled = true; loki.enabled = true; defaultRules.enabled = true; };
  scorecard = { enable = true; rules = { architecture = kix.rules.architecture; }; };
}
```

### 13.3 Per-instance options

```nix
instances.<namespace>.<instanceName> = {
  package        = packages.foo;
  aliases        = [ "redis" ];          # extra DI resolution keys
  config         = { ... };              # deferredModule — multiple modules merge
  deps           = { explicit = ref; };  # override DI resolution; collisions are errors
  partsOverlays  = [ (scope: self: base: ...) ];
  extraDeps      = [ ... ];
  platformIntents = { ... };             # network connectivity intents (import-instance pods)
  version        = "1.2.3";
  labelStyle     = "kix" | "helm";
  selectorLabels = { app = "foo"; };     # override auto-generated selectors (immutable workloads)
  optional       = true;                 # dormant unless transitively required
};
```

`mkLocked value` marks a config field as immutable — blocks dep injection overrides. Useful when a package's dep config injection would override a value you want to pin.

## 14. Cluster-wide options

Set at the top level of the cluster module (or under `config.*` in module form). Source: `kix/lib/modules.nix`.

| Option | Type | Default | Use |
|---|---|---|---|
| `clusterLabels` | `attrsOf str` | `{}` | Labels injected into every resource |
| `clusterDomain` | `str` | `"cluster.local"` | In-cluster DNS suffix — affects every `out.fqdn` |
| `instances` | nested attrset | `{}` | `{ namespace: { instance: { package, ... } } }` (§13.3) |
| `availablePackages` | `attrsOf raw` | `{}` | Package registry; auto-instantiates on DI miss |
| `autoNamespace` | `nullOr str` | `null` | Default ns for auto-instantiated packages |
| `namespaces` | attrset | `{}` | Per-ns labels, annotations, ResourceQuota, NetworkPolicies |
| `globalPartsOverlays` | list | `[]` | Parts overlays applied to ALL instances |
| `global` | `attrsOf anything` | `{}` | Cluster-wide configuration accessed via `_kixOptions` |
| `k8sVersion` | `nullOr str` | `null` | Target K8s version — used for meta version-compat checks |
| `cluster.domain` | `nullOr str` | `null` | Public base domain — `kix.expose` derives `<instance>.<domain>` |
| `cluster.provider` | `nullOr str` | flavor-set | Distribution name (informational) |
| `cluster.roles` | `attrsOf submodule` | flavor-set | Environment role bindings per registry role: `{ binding = "absent" | "shadowable" | "exclusive"; provider? }` (§15) |
| `cluster.capabilities.*` | various | flavor-set | 8 substrate axioms — see §15 |
| `cluster.maintenance` | submodule | `{}` | `{ enable, reason?, until? }` — maintenance window marker |
| `cluster.network` | submodule | – | `{ podCidr, serviceCidr, dnsUpstream }` |
| `cluster.nodes` | attrset | `{}` | Static node inventory: `{ nodeName: { roles, cpu?, memory?, labels, taints? } }` |
| `scorecard` | submodule | `{}` | `{ enable, rules, ruleDefaults, ruleOverrides }` (§17) |
| `networkPolicy` | submodule | `{}` | `{ enable, defaultDeny, directions, platformIntents }` (§16) |

`clusterDomain` and `cluster.domain` are different options and are not interchangeable.

- `clusterDomain` is the Kubernetes DNS suffix, default `cluster.local`. `mkResource` builds `out.fqdn` as `<name>.<namespace>.svc.<clusterDomain>`. Change it only when the cluster itself was installed with a non-default domain.
- `cluster.domain` is the public base domain, default `null`. `kix.expose` derives an Ingress/HTTPRoute host as `<instanceName>.<cluster.domain>` when the instance sets no explicit `ingress.host`; `kix.modules.monitoring` derives Grafana's root URL from it. Null means no host is derived and `kix.expose` emits no route.

Putting a public domain in `clusterDomain`, or `cluster.local` in `cluster.domain`, produces addresses that resolve nowhere and no error.

## 15. Flavors and capability matrix

Flavors set `cluster.provider`, `cluster.roles` bindings, `cluster.capabilities` substrate axioms, and platform-provided DI imports. Use as the first module in `buildCluster`:

```nix
modules = [
  kix.flavors.gke           # cluster.provider, capabilities
  ./platform.nix            # cluster-wide options
  ./apps.nix                # instances
];
```

| Flavor | provider | multiNode | loadBalancer | managedCP | persistentStorage | daemonSets | privileged | CNI | Platform imports |
|---|---|---|---|---|---|---|---|---|---|
| `k3s` | k3s | yes | no | no | yes | yes | yes | k3s | DNS (CoreDNS), storage (local) |
| `kind` | kind | no | no | no | **no** | yes | yes | kindnet | DNS, storage (local-path-provisioner) |
| `kubeadm` | kubeadm | yes | no | no | yes | yes | yes | (none) | none — user installs CNI |
| `eks` | eks | yes | yes | yes | yes | yes | yes | aws-vpc-cni | DNS, storage (ebs) |
| `gke` | gke | yes | yes | yes | yes | yes | yes | gke-native | DNS, storage (pd-standard) |
| `gke-autopilot` | gke-autopilot | yes | yes | yes | yes | **no** | **no** | gke-native | DNS, storage; restricted SCC |
| `aks` | aks | yes | yes | yes | yes | yes | yes | azure-cni | DNS, storage (default) |
| `openshift` | openshift | yes | yes | yes | yes | yes | **no** | ovn-kubernetes | DNS, storage; restricted SCC |
| `rke2` | rke2 | yes | yes | no | yes | yes | yes | cilium (bundled) | DNS (CoreDNS), storage |
| `talos` | talos | yes | no | no | yes | yes | yes | (none) | minimal |
| `lithus` | lithus | varies | varies | varies | varies | varies | varies | varies | isolated node-local |

**Capability flags** (full list, all on `cluster.capabilities`): `multiNode`, `availabilityZones` (list), `nodeAutoscaling`, `managedControlPlane`, `gpu`, `privilegedContainers`, `podSecurityEnforcement` (`"privileged" | "baseline" | "restricted" | null`), `daemonSets`. Flags are three-valued substrate axioms: `null` = unknown (relying workloads warn), `false` = hard error, `true` = pass.

The old role-backed bools (`cni`, `networkPolicyAPI`, `loadBalancer`, `persistentStorage`, `rwxStorage`, `volumeSnapshots`, `ingressController`) are gone (v2_discussions/127): role providers derive from `meta.roles`, the environment's claim on a role is a `cluster.roles.<name>.binding`, and rwx/snapshot facts live on the storage provider's `out`. The CNI/LB/storage columns in the table above describe role bindings and platform imports, not capability flags.

**Override flavor defaults** when reality differs (e.g. ludo runs k3s with
flannel disabled, so the k3s flavor's exclusive `cni` binding doesn't hold and
a managed cilium instance fills the vacant role):

```nix
# ludo/cluster.nix
modules = [
  kix.flavors.k3s
  ./base.nix
  {
    cluster.capabilities.multiNode = false;
    # flannel is disabled on the node, so the environment's claim on the
    # cni role is genuinely vacant; the managed cilium instance fills it.
    cluster.roles.cni = { binding = "absent"; provider = null; };
  }
];
```

**Platform imports.** Flavors declare `optional = true` instances for platform-managed services:
- `platform-dns` (alias `dns`) — all flavors.
- `platform-storage` (alias `storageClasses`) — flavors with built-in storage.

If a cluster installs its own `coredns` or `storage-classes` instance, the explicit instance wins (DI prefers managed > import).

## 16. Network policy auto-derivation

`CiliumNetworkPolicy` is auto-derived from the DI graph — packages don't author netpol manifests. Enable with `networkPolicy.enable = true`. See `kix/lib/architecture.md` "Netpol is derived, not declared" + v2_discussions/83.

### 16.1 What's discovered

| Signal | Generates |
|---|---|
| Package's `kix.run/depends-on` to a Service in another package | Egress CNP (caller→callee) + paired ingress CNP in callee's namespace via `scope.forNamespace` |
| Workload makes Helm/JSON-context refs to a sibling Service | Same — discovered by intersecting raw spec JSON context against the per-package Service registry |
| Any package has RBAC or CRD resources (precise: SA → RoleBinding/ClusterRoleBinding walk) | API-server egress |
| Package's pod hits DNS | DNS egress (per-workload, emitted inside `mkDeployment` etc., spliced into `extraDeps`) |
| StatefulSet | Self-egress + self-ingress (peer pods) |
| LoadBalancer Service or hostNetwork pod | External ingress allowance |

### 16.2 What's NOT discovered

- Cross-package edges hidden inside Helm templates that don't appear in JSON string context (warned via "Helm opacity" message).
- hostNetwork pods bypass CNI policy (warning emitted).

### 16.3 Cluster-side wiring

The enforcer is auto-discovered: any package with `meta.roles ∋ "network-policy-enforcer"` becomes the cluster's enforcer. The enforcer's package exposes `out.cnpCrdRef` (a CRD marker for `CiliumNetworkPolicy`); every generated CNP is built via `cnpCrdRef.out.cr` so the CNP → CRD-ref → enforcer-root edge is wired transitively. Two enforcer packages illustrate the pattern:

- `kix/packages/cilium/` — Helm-wrapped, deploys cilium fully (used by `ludo-kind`).
- `kix/packages/cilium-external/` — emits only the CRD marker; cilium is installed out-of-band on the host (used by `ludo`, RKE2-based clusters, etc.). Auto-discovered as `packages.cilium-external`.

### 16.4 Default-deny

```nix
networkPolicy = {
  enable = true;
  defaultDeny = true;                    # per-namespace
  directions = [ "ingress" "egress" ];   # which directions to deny by default
};
```

`namespaces.<ns>.networkPolicies.{directions, defaultDeny}` allows per-namespace overrides.

## 17. Scorecard

Rule levels, evaluated against the corresponding object:

| Level | Object |
|---|---|
| `manifest` | One K8s manifest at a time |
| `package` | A whole package's resources + parts + config + meta |
| `namespace` | All instances + resources in a namespace |
| `cluster` | All instances + resources cluster-wide |

### 17.1 Severity precedence

```
rule disable          (rule excluded outright)
> ruleOverrides.byOwner
> ruleOverrides.byNamespace
> rule's own severity
> ruleDefaults
```

Configure via `scorecard.{enable, rules, ruleDefaults, ruleOverrides}`.

### 17.2 Built-in rules

**Security** (`kix.rules.security`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `nonRoot` | manifest | error | All containers `runAsNonRoot` |
| `noPrivileged` | manifest | error | No privileged containers |
| `readOnlyRootfs` | manifest | warning | Read-only root recommended |
| `noHostNetwork` | manifest | error | No `hostNetwork`/`hostPID`/`hostIPC` |
| `noLatestTag` | manifest | warning | Images explicitly tagged (not `:latest` or untagged) |
| `noUnresolvedPlaceholder` | manifest | warning | No `REPLACE_ME`, `CHANGEME`, `PLACEHOLDER`, `TODO`, `FIXME`, `XXX` or unexpanded `${...}` in an image reference (§29) |
| `hasNetworkPolicy` | namespace | warning | Workload namespaces have at least one NetworkPolicy |

**Reliability** (`kix.rules.reliability`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `boundedResources` | manifest | warning | All containers declare CPU+memory requests AND limits |
| `hasResourceLimits` | manifest | warning | All containers have limits |
| `hasResourceRequests` | manifest | warning | All containers have requests |
| `hasProbes` | manifest | warning | Workload containers have liveness + readiness probes |
| `hasPDB` | package | warning | Multi-replica Deployments have PodDisruptionBudget |
| `gracefulShutdown` | manifest | info | `terminationGracePeriodSeconds` set |

**Governance** (`kix.rules.governance`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `hasOwner` | package | warning | `meta.owner` set |
| `hasDescription` | package | info | `meta.description` set |
| `labelStandards` | manifest | info | Standard labels (`app.kubernetes.io/name`, `managed-by`) |

**Architecture** (`kix.rules.architecture`):

DI-hygiene rules (v2_discussions/128 replaced the old fingerprint-based capabilityOwnership rule):

- `annotationDomainOwnership` — a package's `metadata.annotations` keys under an operator-declared domain (`meta.annotationDomains`, e.g. reflector's `reflector.v1.k8s.emberstack.com`) require a DI dep on the declarer; a domain nobody declares warns as a dead annotation. Reserved suffixes (`kubernetes.io`, `k8s.io`, `kix.run`, `helm.sh`, `kubebuilder.io`) and the cluster's `scorecard.knownAnnotationDomains` are exempt.
- `unsafeGrants` — info-level audit listing every `meta.unsafe` grant (currently only `raw-pvc`, whose absence is enforced as an eval *error* in `scope/validators.nix`, not a scorecard rule).
- `selectorCoherence` / `fqdnWithoutContext` — selectors and `*.svc` FQDNs must carry store-path context from the owning workload/service.
- `monitorSelectorMatchesService` (cluster-level, **error**) — every ServiceMonitor/VMServiceScrape selector must match some Service's *metadata labels* in its target namespaces. Monitor selectors match Service labels, NOT the workload's pod selector — a mismatch drops every target at relabeling and the job silently vanishes from `up` (this shipped four times before the rule existed). Use `self.service.out.selector` or `kix.monitor`. A monitor deliberately targeting a Service kix doesn't render (e.g. prometheus-operator's runtime `kubelet` Service) opts out with `annotations."kix.run/monitors-external-service" = "true"`. Cluster-level findings trace and gate builds like instance findings.
- `externalMonitorTargets` (info) — audit listing every `kix.run/monitors-external-service` claim, so opted-out monitors stay visible in review (the unsafeGrants property).

### 17.3 Output

```nix
scorecard.enable = true;
scorecard.rules = {
  inherit (kix.rules) security reliability governance architecture;
};
scorecard.ruleDefaults = "warning";   # or "error", "info"
scorecard.ruleOverrides.byNamespace = { kube-system = { noLatestTag = "info"; }; };
```

`buildScorecardReport` aggregates findings; `scorecardToWarnings` converts them into `builtins.trace` (warning/info) or assertion failures (error). `kix check --sarif` emits SARIF 2.1.0.

### 17.4 Cross-resource checks

Sixteen checks over the finished manifest list run inside every cluster evaluation (`kix/lib/eval/validate.nix`, called from `buildCluster`). They ask whether the thing a name points at exists and whether labels really match a pod in the build. The scorecard rules ask a different question, whether a value came from the right place, and run before string context is stripped. Both are needed: a hand-typed selector with a typo gets the same scorecard warning as a correct one, and only these checks tell them apart.

| # | Check | Skips |
|---|---|---|
| 1 | Workload `serviceAccountName` names a ServiceAccount in its namespace | `default`; unset |
| 2 | (Cluster)RoleBinding `roleRef` names a Role or ClusterRole that is in the build | names starting `system:`, ending `-psp`, or `admin`, `edit`, `view`, `cluster-admin` |
| 3 | `volumes[].configMap.name` names a ConfigMap in the namespace | Secrets are not checked (often created out of band) |
| 4 | Service selector matches at least one pod template | no selector; the control-plane scrape selectors (kube-dns, kube-scheduler, ...); a Service that declares `kix.run/operand-of` (below) |
| 5 | HPA `scaleTargetRef` exists | |
| 6 | StatefulSet `serviceName` is a headless Service (`clusterIP: None`) in the namespace | unset |
| 7 | One resource per kind, namespace and name | |
| 8 | Every resource carries `app.kubernetes.io/managed-by: kix` | |
| 9 | Workload `selector.matchLabels` is within its pod template labels (Deployment, StatefulSet, DaemonSet, Job) | |
| 10 | Ingress backends name a Service in the namespace | |
| 11 | Every `metadata.namespace` has a Namespace resource | `_`-prefixed sentinel namespaces (cluster-level instances) |
| 12 | NetworkPolicy `podSelector` matches at least one pod template | empty selector |
| 13 | A named `targetPort` exists on a container of a selected pod | numeric ports; Services that select no pod template in the build (check 4 reports those, or their pods are an operator's and there is no container spec to read) |
| 14 | PodDisruptionBudget `selector.matchLabels` matches at least one pod template | no `matchLabels`; a PDB that declares `kix.run/operand-of` (below) |
| 15 | A Job's pod template labels satisfy no Service selector in its namespace (the Service would route traffic to the Job pod) | Services without a selector |
| 16 | `kix.run/rerun` appears on Jobs only, with the value `on-change` (the deploy engine deletes and recreates what carries it; key and value live in `core/annotations.nix`) | |

**Scope of a lookup.** A reference is looked up in the referrer's namespace only, unless the referenced kind is a built-in cluster-scoped kind (a RoleBinding to a ClusterRole). Nothing else falls back to the cluster-scoped bucket. A `kix.untrackedRef` name resolves whatever its kind. Pod selectors follow the same rule: a Service, NetworkPolicy or PodDisruptionBudget matches pod templates in its own namespace only.

**Failure shape.** The eval fails like any other assertion:

```
error: Cluster 'ludo-kind' has 1 failed assertion(s):
  - [validate] Service data/postgres-metrics selector {"app":"pg"} matches no workload pod template
```

`nix build`, `kix build`, `kix deploy` and `kix check` all stop there. Under `nix flake check` the same list appears as `validateManifestSet(cluster-<name>):` from `kix/checks.nix`.

**Services for operator-created pods.** Check 4 cannot see pods an operator creates at runtime. Two ways through, in order of preference:

1. `scope.mkServiceRef` for a Service the operator itself creates (`prometheus-operated`, `alertmanager-operated`, `vmselect-<name>`). It carries the selector, ports and the Service's labels, renders as a marker, and no check or rule fires on it. The prometheus, alertmanager, victoria-metrics-cluster and stackgres-cluster packages do this. Two consequences to know: consumers now wait until the operator's Service has ready endpoints (the per-node readiness timeout, 180s by default, applies to a slow Prometheus start), and the declared selector should be as wide as the operator's own (`prometheus-operated` selects every Prometheus in the namespace; a ref that adds the instance label describes fewer pods than the Service reaches).
2. When kix must render the Service itself (the operator creates none, as for the Thanos sidecar), the Service declares the CR whose pods it selects: `metadata.annotations."kix.run/operand-of" = "<group>/<Kind>/<name>"`. Check 4 accepts the Service when that CR is in the build in the same namespace, and reports the declaration when it is not. A PodDisruptionBudget over operator-created pods declares the same annotation for check 14 (the alertmanager package does). Group and kind together, because kind names are not unique across API groups. There is no list of operator kinds anywhere in the checker.

**References to things kix does not render.** Wrap the name in `kix.untrackedRef` (a ServiceAccount the cluster provides, a ConfigMap another system owns). The value carries an inert marker in its string context; `buildCluster` collects those names before context is stripped, keyed by the referring resource's namespace, and the checks accept them there. A `scope.mkServiceRef` or `scope.mkSecretRef` marker counts as the Service or Secret it describes, in its namespace, and its declared pod selector counts as pods for the Service and NetworkPolicy selector checks. For a cluster-level `kix.mkImport`, pass `kind = "Service"` so the marker carries the kind; a consumer in another namespace wraps the name in `kix.untrackedRef`. A bare string that names nothing in the build fails, and so does a name derived from a resource with a suffix added (`self.sa.out.name + "-typo"`): provenance is not resolution. A suffix on an untracked ref stays untracked, since the author marked it. The StatefulSet headless-Service check reads `clusterIP: None` off a rendered Service and cannot accept a marker.

**Where it sits.** `kix/lib/tests/validate.nix` holds a failing and a passing case per check. The scorecard is off unless a cluster enables it; these checks are always on.

## 18. Multi-environment stamping

`kix.mkEnv` stamps the same instance set into env-prefixed namespaces:

```nix
# clusters/example-multi-env/services.nix
let
  appStack = {
    api = { package = packages.api; config = {...}; };
    db  = { package = packages.stackgres-cluster; config = {...}; };
  };
in {
  instances = (kix.mkEnv "dev"  { config = { replicas = 1; }; } { app = appStack; })
           // (kix.mkEnv "prod" { config = { replicas = 3; }; overrides.app.api = { config.image.tag = "stable"; }; } { app = appStack; });
}
```

Result: namespaces `dev-app`, `prod-app` with per-env config overrides. `overrides.${setName}.${instName}` lets you override individual instances.

The namespace prefix is the whole isolation mechanism. A plain dependency auto-instantiated for `dev-app` lands in `dev-app`, because `eval/auto.nix` resolves it into the requesting namespace. Two exceptions, both deliberate: a package that declares its own `namespace` in `availablePackages`, and a cluster that sets `autoNamespace`, are pinned there and so shared by every environment. Role-named deps are keyed by the role rather than by namespace, so one provider serves them all.

Every environment in one `mkEnv` cluster deploys together, under one activation. When you want them to deploy separately, write one cluster per environment over a shared base module instead (`clusters/example-multi-env/`).

Use only when the environment dimension is genuinely "same shape, different tuning". Don't use for truly distinct shapes — make those separate clusters.

## 19. Multi-component packages

Apps with multiple sub-services (Harbor: core, portal, registry, jobservice, exporter) live in **one package**, not split across packages. They share config, secrets, and internal URLs. Reference: `kix/packages/harbor/`. Deep dive: [`.claude/skills/kix-migration/MULTI_COMPONENT.md`](../.claude/skills/kix-migration/MULTI_COMPONENT.md).

Five key patterns:

1. **Shared `let` bindings** — define common values (selector labels, security contexts, probe bases, internal URLs) once.
2. **Per-component selectors** — add a `component` label to distinguish pods: `selector.matchLabels = selectorLabels // { component = "core"; }`.
3. **Cross-resource refs via enriched `out`** — `self.coreSecret.out.envFrom`, `self.coreConfigMap.out.name`, `self.coreSecret.out.keyRef "secret"`.
4. **Inline PVCs** — when storage is owned by the package (not the cluster operator), define PVCs as resources within the package.
5. **`root.requires` / `root.postHooks`** — the synthesized `root` declares `requires` (everything must exist before root) and `postHooks` (resources deployed after the rest of the package).

## 20. Storage

Storage is first-class via DI: `app → PVC → StorageClass`. Deep dive: [`.claude/skills/kix-migration/STORAGE.md`](../.claude/skills/kix-migration/STORAGE.md).

```nix
# Cluster definition:
instances.kube-system.storage-classes = {
  package = packages.storage-classes;   # claims the storageClasses role — the role name auto-aliases
};
instances.my-app.storage = {
  package = packages."persistent-volume-claim";
  config = { size = "500Gi"; accessModes = [ "ReadWriteOnce" ]; };
};
instances.my-app.app = { package = packages.my-app; };  # storage resolves via DI
```

```nix
# Consuming package:
{ scope, lib, kix }: {
  build = { self, config, storage, ... }: {
    dataMount = kix.mount.pvc storage { mountPath = "/data"; };
    deployment = { ... } |> kix.withMounts [ self.dataMount ] |> scope.mkDeployment;
  };
}
```

The `persistent-volume-claim` package declares `meta.defaultAliases = [ "storage" ]`, so consumers get DI resolution by arg name. `meta.lifecycle = "stateful"` triggers PVC-deletion protection in `kix-diff`.

## 21. Secrets

**Always** use `scope.mkSecret` or `scope.mkSecretRef` — never `scope.mkResource { kind = "Secret"; }`. Deep dive: [`.claude/skills/kix-migration/SECRETS.md`](../.claude/skills/kix-migration/SECRETS.md).

### 21.1 `scope.mkSecret` — kix-managed

```nix
creds = scope.mkSecret {
  name = "${name}-credentials";
  stringData = { username = "admin"; password = config.password; };
  # keys auto-derive from stringData. For SOPS:
  # keys = [ "username" "password" ];
  # source = ./secrets/creds.yaml;
  # hash = "sha256-...";
  # type = "Opaque";   # default
};
```

### 21.2 `scope.mkSecretRef` — external

References a Secret managed outside kix (Vault, ESO, cert-manager, operator-provisioned). Emits a `PackageInstance` import marker with `kix.run/mode=import` that the deploy CLI polls before applying dependents — if the Secret is missing or declared keys aren't populated, the wave fails fast.

```nix
appSecret = scope.mkSecretRef {
  name = "my-app-secret";
  keys = [ "API_KEY" "DB_URL" ];   # build-time validation + deploy-time presence check
};
```

**Gotcha — return the marker, don't bury it in `let`.** `collectTypedAttrs` only emits resources that appear in the build's return attrset. A `mkSecretRef` stashed in a `let` binding will not produce a manifest. Always `inherit` (or otherwise return) the ref.

### 21.3 Enriched `out`

```nix
secret.out.keyRef "key"             # → { valueFrom.secretKeyRef = { name; key }; }   (validates "key" against declared keys)
secret.out.mkEnv { ENV = "key"; }   # → [{ name = "ENV"; valueFrom.secretKeyRef = ...; }, ...]
secret.out.envFrom                  # → { secretRef.name = ...; }
secret.out.volume "vol-name"        # → { name = "vol-name"; secret.secretName = ...; }
```

`keyRef` and `mkEnv` validate requested keys at build time, catching typos.

### 21.4 Cross-namespace via reflector

Set `reflect = true` on `scope.mkSecretRef` (or `scope.mkSecret`'s consumer) when an emberstack/kubernetes-reflector Secret is being mirrored across namespaces. Relaxes the same-namespace check in `checkNamespacedRefs`.

## 22. CRDs

Pipe-friendly builders in `scope.crd` (or top-level `kix.crd`):

```nix
{ scope, lib }:
let
  myCrd = scope.mkCRD (
    scope.crd.fromKind "MyKind" {}
    |> scope.crd.clusterScoped
    |> scope.crd.withVersion "v1alpha1"
    |> scope.crd.withShortNames [ "mk" ]
    |> scope.crd.withCategories [ "all" ]
    |> scope.crd.withPrinterColumns [ { name = "Status"; type = "string"; jsonPath = ".status.phase"; } ]
    |> scope.crd.withSchema { type = "object"; properties = { spec = { ... }; }; }
    |> scope.crd.withLabels { "app.kubernetes.io/component" = "demo"; }
  );
in {
  build = { self, ... }: {
    crd = myCrd;
    instance = scope.mkCR "MyKind" {
      name = "my-instance";
      spec = { ... };
      requires = [ self.crd ];   # mkCR auto-adds the CRD ref to requires
    };
  };
}
```

`scope.mkCRDRef` creates a CRD marker (no actual CRD resource) — use when the CRD is owned by an external package that you depend on.

Both `mkCRD` and `mkCRDRef` accept two per-kind controller-semantics declarations that ride the typed chain into every CR built via `mkCR`:

- `factBehavior = { endpoint = "terminate"|"conduct"; podSelector = cr: {...}; }` — netpol semantics (§facts).
- `readiness = { path = "/status/updateStatus"; equals = "operational"; }` — the controller's health convention, stamped on each CR as the `kix.run/readiness` annotation; `kix deploy` evaluates it instead of the generic Ready/Available condition check. Declare it whenever the operator never stamps Ready/Available (the VictoriaMetrics operator's `updateStatus` convention is the canonical example) — without it, deploys time out waiting on healthy CRs.

## 23. Imports

`kix.mkImport` marks a resource as existing-but-unmanaged. DI resolution prefers managed > import, so a `mkImport` is the lowest-priority candidate.

```nix
# In a flavor's platform module:
{ kix, ... }: {
  instances.kube-system.platform-dns = {
    package = kix.mkImport {
      from = ./platform-dns.nix;     # optional package fn — for lazy out derivation
      out  = { fqdn = "10.96.0.10"; };
    };
    aliases = [ "dns" ];
    optional = true;
  };
}
```

Pre-deploy: `kix deploy` polls each `kix.run/mode=import` PackageInstance to confirm the resource exists before applying anything that depends on it. There is no flag to skip this; mark the instance `optional = true` if the resource may legitimately be absent. Only kind, apiVersion and name are verified (plus the declared keys of a Secret ref) — an import's `fqdn` and `port` are passed through unchecked.

## 24. Manifest stamping

Every kix-managed resource gets:

| Annotation/Label | Value |
|---|---|
| `kix.run/identity-hash` | Blake3 32-char store hash (change detection) |
| `kix.run/depends-on` | Comma-separated dep entries: bare hash (implicit), `requires:<hash>`, `extra:<hash>` |
| `kix.run/package` | Package instance name |
| `kix.run/package-namespace` | Package namespace |
| `kix.run/mode` | `"import"` for external resources |
| `kix.run/rerun` | `on-change`, on a `kix.healthCheck` Job: never patched, deleted and created again when its hash changed or its last run failed (§9.4, check 16) |
| `kix.run/cluster` (label) | Cluster name |
| `app.kubernetes.io/managed-by: kix` (label) | Always |

Activation CR also gets `kix.run/built-via` (the activation derivation's store path).

### 24.1 Clusters deployed before the kix.run move

Kix stamped these keys under `kix.dev` until September 2026, and registered
its two CRDs in the `kix.dev` API group. We do not own that domain, so both
moved to `kix.run`. A cluster deployed before the move still carries the old
keys and the old CRDs, and Kix refuses to touch it until it has been
migrated.

Per cluster, once. **If the cluster runs the kix operator, scale it to 0
first.** While the operator watches the old API group it re-adds its finalizer
to the records, and deleting the old CRDs would then make the operator delete
every resource in the activation.

The command checks this for itself rather than trusting you to have done it.
It clears the finalizers, waits, and reads them back; only a running operator
puts one back. If one returns, it stops there, having copied and deleted
nothing. Note that the finalizer's mere presence proves nothing, which is why
the check is a probe and not a look: the operator adds it on every reconcile
and removes it only when a record is being deleted, so every record on a
cluster that ever ran the operator carries one for ever.

```bash
kubectl -n <ns> scale deploy/kix-operator --replicas=0   # if one runs here
kix migrate domain <cluster> --dry-run                   # prints the plan, writes nothing
kix migrate domain <cluster>
```

It copies every Activation record to the new group with its spec, status and
history intact, verifies each copy by name and by phase, then deletes the old
CRDs. Rerunning after an interruption skips
what it already copied, and repairs a copy whose status write did not land. PackageInstance records are not copied: the next
deploy re-creates them from the build, import markers included.

Then, in this order:

1. If the cluster runs the kix operator, upgrade its image and scale it back
   up. The operator watches one API group, so the new image watches the new
   group and the old one would see nothing.
2. `kix deploy <cluster>`.

**Hard gc in the window between the two.** Until that first deploy, every
object still carries the annotations the pre-move build wrote. An identity
hash covers the manifest that produced it and the move changed every
manifest, so a live hash from before the move can never equal one from a
build made now. Hard gc therefore judges those objects by Kubernetes
identity instead, the rule soft gc and prune already use: present in the
build means still yours and waiting to be re-stamped, absent means garbage.
It says how many it judged that way. One deploy restores hash precision.

**What that first deploy does.** Every resource's identity hash changed,
because the keys stamped into it changed, so every resource is applied once.
Nothing is deleted. Almost nothing restarts: the keys sit on the object, not
on the pod template. The exception is a package that hashes a ConfigMap into
a pod-template annotation to force a rollout on config change (`valkey`,
`n8n` and `python-app` do). Their pods roll once. A second deploy is a no-op.

**While the compatibility layer stands**, a Kix key is read under the new
domain first and the old one second, so an object an older Kix stamped is
still recognised. A build loaded from a pre-move activation, including a
`kix rollback` target, has its keys and its record's API group moved on load.
The layer lives in `cli/kix/src/legacy_domain/` and goes as one piece; the
checklist is in `v2_discussions/archive/137_kix_run_domain_migration.md`.

## 25. Activation CR and operator

The cluster's root resource is an `Activation` CR. `mkActivation` references every PackageInstance via Nix string context, so `nix-store -q --tree` on the Activation derivation yields the full deploy DAG. This contract is what the CLI (and operator) rely on for ordering.

**Activation lifecycle:** `Queued → Deploying → Active | Degraded | Failed → Superseded`.

The record is created before the first wave, not after the last, so a deploy
that stops part way leaves one. `Degraded` means the deploy finished but some
resources failed to apply or become ready; it is still the cluster's current
state. `Failed` means the deploy stopped before finalizing, so it is not a
current state and `kix deploy` never diffs against it. The next deploy reads a
`Failed` record only as an extra baseline, to re-apply what that run may have
changed and prune what it left behind, then supersedes it.

| Path | Behavior |
|---|---|
| Default (no `--operator`) | CLI runs the scheduler directly. Reads/writes `Activation` CR for state. Wave-based apply with SSA, readiness, prune. |
| `--operator` | CLI patches the Activation CR's source path; the kix-operator reconciles. Operator handles GC via finalizers when superseded Activation CRs are deleted. |

Operator requires `nix-store` binary on the host and read access to `/nix/store/`.

## 26. Diff and snapshot tooling

| Need | Tool |
|---|---|
| Diff vs live cluster | `kix diff <cluster>` (default mode) |
| Diff vs snapshot or export dir | `kix diff <cluster> --from <dir>` |
| Diff between two builds | `kix diff <cluster> --from <result>` |
| Save live state | `kix snapshot save <dir>` (in-CLI; uses `kix.run/managed-by` label) or `./scripts/kix-dump.py --all <dir>` (Python; broader scope) |
| Apply with planning | `kix deploy <cluster>` (use `--dry-run` first) |
| Markdown for PR comments | `kix diff <cluster> -o markdown` |

Diff features:
- Structural (path-based) differences with **keyed-list awareness** — containers→name, ports→name, env→name, volumeMounts→mountPath, subjects→kind:name. So reordering doesn't show as a diff.
- **Rename detection** via fuzzy similarity matching across kix-only and cluster-only sets.
- Configurable ignore rules (`--ignore-path` for one-off, plus built-in K8s default-stripping).
- **PVC modification warnings** — `kix-diff.py` warns when a kix-only PVC's spec differs from a cluster PVC; `lifecycle = "stateful"` packages enforce no-deletion.

## 27. Common gotchas

| Symptom | Fix |
|---|---|
| Reading `out.selector` cycles through a back-reference | Use `workload.rawSelector`. Trade-off: `architecture.selectorCoherence` warns; live with it |
| Raw PVC throws at eval | Provision via a sibling `persistent-volume-claim` instance + `storage` dep; only canonical/chart-persistence packages hold `meta.unsafe = [ "raw-pvc" ]` |
| `<Kind> name '<n>' is not a legal Kubernetes object name` | Rename the **instance**, not the resource: packages derive names from `scope.instanceName`, so `ingressNginx` renders `Deployment/ingressNginx`. Use a lowercase name and give the package `meta.defaultAliases = [ "camelCaseArgName" ]` so the DI build argument still resolves |
| `annotationDomainOwnership` warns about an operator's annotations | Declare the DI dep on the operator (e.g. `reflector`) and use its builder; for domains consumed outside kix add `scorecard.knownAnnotationDomains` |
| Cross-namespace mount or secret-ref errors at build | Either move the resource to the right ns, use `scope.forNamespace`, or set `reflected = true` if reflector mirrors it |
| Dep injection overrides a value you want to pin | Wrap with `mkLocked` |
| Reflected secret looks unhealthy | Reflector controller copies on schedule; `reflected = true` relaxes ns-check but does not guarantee the copy exists. Order via DI on the reflector |
| `_kix.<typo>` silently dropped | `stripKixMeta` enforces a whitelist (`namespace`, `source`, `reflected`, `serviceAccountNamespace`) and throws on unknown keys |
| `_type` markers eaten in unexpected places | `collectTypedAttrs` stops descending at `_type` — that's intentional (resources are leaves). Only attrsets without `_type` get traversed |
| A `let`-bound `mkSecretRef` doesn't appear in the output | Return it from `build` (inherit it into the return attrset) |
| `extra.spec = ...` errors with shadowing | Use the dedicated `spec` arg. `extra` is for sibling fields kix doesn't model (e.g. `provisioner` on StorageClass) |
| `kix.expose` does nothing | Neither `gateway` nor `ingressNginx` is wired. Wire one in the cluster: `instances.<ns>.gateway = { package = packages.envoy-gateway; ... };` or `instances.<ns>.ingress-nginx = { package = packages.ingress-nginx; };` |
| `kix.monitor` does nothing | No `prometheus` instance; or the prometheus package doesn't expose `out.mkServiceMonitor` |
| Build fails: "extra.* shadows managed field" | Move customizations into `spec`/`data`/`stringData` directly |
| Workload starts before its CNPs | Per-workload CNPs are emitted *inside* `mkDeployment`/`mkStatefulSet`/`mkDaemonSet` and spliced into the workload's `extraDeps` so the workload depends on its own policies. If you see ordering issues, you're likely on the post-fixpoint path (RBAC/CRD/LB CNPs); check `processInstance` in `netpol.nix` |
| Build fails with `[validate] Service ... matches no workload pod template` | The Service selects pods that are not in the build. Typo in a label, or operator-created pods: see §17.4 (`scope.mkServiceRef` to the operator's Service, or `kix.run/operand-of` on the Service) |
| Build fails with `[validate] Duplicate resource: <kind>/<ns>/<name>` | Two different resources share an identity; the writer would keep one and drop the other. Common cause: an operator auto-instantiated once per environment (cluster-scoped RBAC and webhooks collide). Declare one shared instance |
| Helm-chart resources lack DI edges to other charts | Helm opacity warning. The `helm-dag.nix` reconstructs intra-chart edges from K8s patterns (SA mounts, RBAC bindings, Service selectors, etc.); cross-chart edges require explicit `requires` |

## 28. References

| Topic | File |
|---|---|
| Internals + non-obvious patterns | `kix/lib/architecture.md` |
| CLI architecture & module map | `cli/README.md` |
| Durable principles | `PRINCIPLES.md` |
| LLM best-practices guide | `docs/BEST-PRACTICES.md` |
| Breadth-first feature inventory | `docs/FEATURE-CATALOG.md` |
| Migration playbook | `.claude/skills/kix-migration/SKILL.md` |
| Secrets deep-dive | `.claude/skills/kix-migration/SECRETS.md` |
| Storage deep-dive | `.claude/skills/kix-migration/STORAGE.md` |
| Multi-component packages deep-dive | `.claude/skills/kix-migration/MULTI_COMPONENT.md` |
| Live status / open questions | `ROADMAP.md` |
| Project rules | `CLAUDE.md` |

**Canonical examples:**

| Pattern | Reference |
|---|---|
| Clean simple package (Deployment + Service + RBAC) | `kix/packages/reloader/` |
| `lib.mapAttrs` to generate resources | `kix/packages/storage-classes/` |
| First-class PVC instance | `kix/packages/persistent-volume-claim/` |
| Image reference read from a committed pin file | `clusters/test-pins.nix` + `clusters/pins.json` |
| Mid-complexity with DI storage, expose, monitor, mounts | `kix/packages/immich/` |
| Complex multi-component | `kix/packages/harbor/` |
| Helm-wrapped capability owner | `kix/packages/cilium/` (helm) and `external.nix` (CRD-only) |
| Multi-resource native package | `kix/packages/valkey/` |
| Production cluster (real + kind variants) | `ludo/` |
| Multi-env stamping | `clusters/example-multi-env/` |

---

**Source-of-truth dates** (last reconciled with this doc):

```
PRINCIPLES.md                          2026-04-27
kix/lib/architecture.md                2026-04-27
.claude/skills/kix-migration/SKILL.md  2026-04-27
.claude/skills/kix-migration/SECRETS.md          2026-04-27
.claude/skills/kix-migration/STORAGE.md          2026-04-27
.claude/skills/kix-migration/MULTI_COMPONENT.md  2026-04-27
cli/README.md                          2026-04-14
docs/FEATURE-CATALOG.md                2026-04-09
ludo/                                  2026-05-06
ROADMAP.md                             2026-05-06
```

If a section here disagrees with the source-of-truth file above, **the source wins** — fix this doc.

## 29. Image pins

Something outside the cluster definition sometimes decides an input to it: a
CI build produces an image tag, or a person decides that this build is the one
that goes to production. Kix has one channel for such a value, the definition
itself, so the value is committed first and deployed second. There is no
`--set` and no `--values`; §9.4 of BEST-PRACTICES explains why one would not
work even if we wanted it.

### 29.1 The file

A pin file is JSON, living next to the cluster definition that reads it,
written by `kix pin`:

```json
{
  "version": 1,
  "managedBy": "kix pin",
  "images": {
    "atlas-server-prod": {
      "repository": "harbor.example.com/team/server",
      "tag": "main",
      "digest": "sha256:00f522cf9c0e4a4d5a2c1e6b7f8a9d0c3b4e5f6a7b8c9d0e1f2a3b4c5d6e7f80",
      "sourceRev": "5d5dda2e5c1f",
      "promotedBy": "ci:deploy#3981",
      "resolvedAt": "2026-09-09T10:47:00Z",
      "note": "Held back while we investigate the memory leak. See PLAT-412."
    }
  }
}
```

`repository` and `tag` are required. Everything else is optional, because an
upstream image has no revision in your history and a pin that has never been
resolved has no digest.

**Make the tag name a stream, not a build.** `main`, not `sha-5d5dda2`. A tag
that changes on every build gives the file no stable key, so CI ends up
editing the cluster definition to promote, which is the pattern the pin file
exists to end. With a floating tag the digest is the only thing that moves,
one line per promotion, and the file stays regenerable. Upstream images keep
their ordinary version tags, because a person moves those.

**Keys are yours.** Kix never interprets them. `atlas-server-prod`,
`atlas-server-acme`, `web-eu`: environments, tenants, regions, or two axes
at once. Nothing in Kix has an opinion about what the axis means.

`note` is for whoever reads the file. Kix never reads it and a promotion
never discards it, which is what a comment could not promise. It does not
reach the image option either, so it cannot affect a manifest.

JSON rather than Nix, for a reason worth checking rather than taking on
taste. Reading a Nix file means evaluating it, so reading a pin file would
execute whatever is in it, and a pull request that edits the file becomes
code execution in CI. Writing one means escaping registry-supplied strings
into a programming language by hand. Neither belongs in a file a bot
rewrites on every build. It is also what the rest of Kix already does:
`kix-packages.json`, `kix-scorecard.json`, the SBOM, the provenance and the
OSCAL assessment are all JSON, and YAML appears only where Kubernetes
imposes it. The evaluation cache fingerprints `.json` alongside `.nix`,
`.yaml` and `.yml` (`cli/kix/src/eval/cache.rs`), so a JSON pin file lands
in the fingerprint like any other input.

### 29.2 Reading it

Name the file once, in the flake. Every cluster that takes a `pins` argument
gets it already loaded, so no cluster definition repeats the path.

```nix
# flake.nix
inputs.kix.lib.mkFlake {
  inherit inputs;
  pins = ./pins.json;
  clusters.app = ./app.nix;
}
```

```nix
# app.nix
{ kix, packages, pins }:
kix.buildCluster {
  name = "app";
  modules = [{
    instances.app.web = {
      package = { ... };
      config.image = pins.get "web";
    };
  }];
}
```

A cluster with a pin file of its own reads one directly instead, which is the
same call under another name:

```nix
let pins = kix.pins ./other-pins.json; in ...
```

| Call | Returns |
|---|---|
| `pins.get "<key>"` | The pin, shape-checked. Throws naming `kix pin set ... --init` when the key is absent |
| `pins.ref "<key>"` | `kix.image.ref (pins.get "<key>")` |
| `pins.keys` | Every pin name in the file |
| `pins.all` | Every pin, shape-checked |

Inside the package, declare the option once and render the reference:

```nix
options.image = kix.options.image {
  repository = "docker.io/nginxinc/nginx-unprivileged";
  tag = "1.28-alpine";
};

# in build:
image = kix.image.ref config.image;   # repository:tag@digest
imagePullPolicy = config.image.pullPolicy;
```

`kix.image.ref` renders the digest when there is one and omits it when there
is not, so an unresolved pin still deploys and is visibly different from a
resolved one.

### 29.3 Promoting

```bash
# Add a pin and the file it lives in
kix pin set web --repository docker.io/library/nginx --tag 1.27 --init

# Promote
kix pin set web --tag 1.28

# From CI, recording what it was built from
kix pin set web --tag "sha-${GITHUB_SHA::7}" --source-rev "$GITHUB_SHA"
```

`kix pin` finds the pin file rather than being told where it is. It looks in
the working directory, then next to the flake (`--flake ./clusters` is enough
to point it at `clusters/pins.json`), then for the only pin file in the
repository. More than one, and it refuses and lists them, because writing a
digest into the wrong file is a quiet failure and being asked which one is a
loud one. `--pins-file <path>` settles it either way.

The flake cannot supply that path, and the reason is worth knowing. A path
literal inside a flake evaluates to a store path, so reading a declaration out
of the flake would mean evaluating the flake and reconstructing the source
path from `self`. That would make a command that needs neither Nix nor a
flake depend on both, and the state in which a pin most needs fixing is the
state in which evaluation is unhappy about it.

`--promoted-by` defaults to the CI run when `GITHUB_RUN_ID` is set, and to
`user@host` otherwise, so a human promotion and a CI promotion produce the
same commit shape.

Refusals, all of which leave the file untouched: a tag the registry does not
have, a key that is not in the file without `--init`, a malformed `--digest`,
and a pin file that `kix pin` did not write without `--force`.

`--no-resolve` writes a pin with no digest and warns that nothing then
verifies the tag exists. `--digest <d>` records a digest you already have,
for an air-gapped promotion.

### 29.4 Checking

```bash
kix pin check
kix pin check --source-rev "$GITHUB_SHA"
```

Two separate questions, reported separately:

- **Is the reference real?** Verified **by digest, not by tag**. A digest that
  has gone from the registry is a failure. A tag that has moved, or that a
  retention job deleted while its digest still runs, is a warning: nothing is
  broken and there is nothing the author could do about it. A pin with no
  digest is a failure unless `--allow-unresolved`.
- **Is it current?** `--source-rev <rev>` fails when a pin records a different
  source revision. This is the only check that catches a promotion step which
  silently did not run, and that failure is otherwise invisible: the deploy
  succeeds, every rule passes, `--dry-run` says configured, the receipt is
  honest, and the cluster runs old code.
Exit code 1 on any failure, 0 otherwise. `--offline` checks shape without
contacting a registry.

### 29.5 Building and deploying in one job

The digest is an output of the build, so the deploy depends on the build.
Splitting them into two workflows joined by a commit turns that dependency
into a trigger, and triggers can form a cycle: the build writes a pin, the
pin commit starts the build, forever.

Do all of it in one job. The commit then records what happened rather than
instructing anything to happen, because the deploy already ran.

```
on: push to the deploy branch, filtered to paths that can affect the cluster

1. if the application source changed:
     build the image
     push it to repository:<floating tag>
2. kix pin set <key> --source-rev "$SHA"
3. if the pin file changed, commit and push it
4. check the push landed
5. kix deploy
```

Two details carry the design.

**Step 1 is conditional, and that is what closes the loop.** The bot's commit
starts the workflow once more. On that run the source has not changed, so no
image is built, so no digest moves, so nothing is committed, and Kix deploys
nothing because the activation hash is unchanged. It converges after one
extra run. Without the condition the image is rebuilt, most container builds
are not reproducible, a fresh digest appears for identical source, and it
really does run forever.

**Step 4 is not optional.** Deploying before the push lands means deploying
something that is not in your repository, and the receipt then names a
revision nobody else can fetch.

Filtering which pushes start the workflow is a free optimisation, since a
wrong filter now costs a wasted run rather than a loop. Filter generously: a
filter that is too narrow means somebody merges a change, sees green, and
nothing deployed. Excluding the pin file saves the one redundant run, and
nothing breaks if it is removed. A `[skip ci]` token on the pin commit does
the same job. To make wasted runs cheap, have CI cache `~/.cache/kix`, which
holds the evaluation cache, so a run that changes nothing finishes in
seconds.

Kix has no opinion about your CI beyond this, and no command that reads its
configuration.

### 29.5 Credentials

In order: `KIX_REGISTRY_USERNAME` and `KIX_REGISTRY_PASSWORD`, a `credHelpers`
entry for this registry, the general `credsStore` helper (which is what
`docker login` uses on macOS and most Linux desktops), then a literal `auths`
entry in `~/.docker/config.json`, or `$DOCKER_CONFIG/config.json`. Anonymous
access is a valid outcome, not a failure.

The digest Kix records is the digest of the manifest the registry served, and
for a multi-architecture image that is the index digest, which is what a
container runtime resolves and what `crane digest` prints. Kix computes it from
the response body rather than trusting the `Docker-Content-Digest` header, and
treats a disagreement between the two as an error.

### 29.6 The ratchet

`security.noUnresolvedPlaceholder` fails an image reference containing
`REPLACE_ME`, `REPLACEME`, `CHANGE_ME`, `CHANGEME`, `PLACEHOLDER`, `TODO`,
`FIXME`, `XXX` or an unexpanded `${...}`. Warning by default; promote it to
error in a cluster that deploys something you care about:

```nix
scorecard.rules.security.noUnresolvedPlaceholder =
  kix.rules.security.noUnresolvedPlaceholder // { severity = "error"; };
```

It is a ratchet, not the fix. A predicate over spelling cannot tell you that
`sha-typo12` is wrong, which is the same limit `noLatestTag` has. What closes
the class is a resolved digest checked against a registry. This rule's one job
is to make the known placeholders unwriteable again.

## 30. Deploy receipt

Every `kix deploy` writes what it deployed into the Activation's
`status.receipt`:

```bash
kubectl get activation <name> -o jsonpath='{.status.receipt}' | jq
```

```json
{
  "schema": "kix.run/receipt/v1",
  "cluster": "app",
  "activationHash": "jak8b4glx8fnbq2c3hkb0khyyvigb96i",
  "deployedAt": "2026-09-09T10:47:55Z",
  "source": {
    "flakeRef": "./clusters",
    "gitCommit": "c1b8d5ede22b680fa172991b9edd6e78ae513b70",
    "dirty": false,
    "revision": "c1b8d5ede22b680fa172991b9edd6e78ae513b70",
    "flakeLock": "blake3:1d2417994d31f798…"
  },
  "builder": { "kixVersion": "0.1.0", "nixVersion": "nix (Nix) 2.28.5", "arch": "aarch64", "os": "macos" },
  "inputs": [ { "name": "nixpkgs", "rev": "8d8c1fa…", "narHash": "sha256-J0dZU4a…" } ],
  "images": [ "docker.io/nginxinc/nginx-unprivileged:1.28-alpine@sha256:7377697a…" ]
}
```

Status rather than spec, for two reasons. The status subresource is untouched
by an apply of the main resource, so a rollback that re-applies an Activation
cannot erase the record of what happened. And by Kubernetes convention spec is
intent and status is observation, and a receipt is an observation.

Superseded activations keep their own receipts, so the cluster carries a
per-deploy history of what ran, bounded by `kix gc` retention.

**Dirty trees are recorded, not hidden.** `source.dirty` says whether the
working tree matched the commit, and `source.revision` uses Nix's spelling,
`<rev>-dirty`. `kix deploy` prints the warning above the confirmation, so you
can still decide not to. This is not a refusal: deploying from a dirty tree is
a normal thing to do while working. What is not acceptable is doing it while
recording a commit that does not contain what is being deployed.

**Not in the receipt: the manifests.** Built manifests carry secret values
inline, so storing them would make every deploy record a readable archive of
every credential the cluster ever held. Rollback stays tied to the source.

`kix compliance attest --from-cluster` builds the SLSA statement from the
receipt instead of from a fresh evaluation, so a deploy can be attested from a
machine that never built it. Both routes go through the same assembly, so they
cannot drift apart. A container image only gets a `sha256` digest in
`resolvedDependencies` when its reference actually carries one: a tag is a
request, not a resolution, and putting it in a digest field would be a
well-formed false statement.

