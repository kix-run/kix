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
| Preview a deploy | `kix plan <cluster>` (server-side dry run; `kix deploy --dry-run` runs it) |
| Deploy a cluster | `kix deploy <cluster>` (prints the plan first; add `-y` to skip confirm) |
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
│   │   ├── default.nix        # Re-exports: start here to find a symbol
│   │   ├── architecture.md    # Internals + non-obvious patterns
│   │   ├── core/              # Resource sealing (mkResource, mkPackageInstance, mkActivation), annotations, markers, availability levels, versions
│   │   ├── eval/              # buildCluster, evaluateInstance, resolve, auto, import, roles, options (option contract), validate (cross-resource checks)
│   │   ├── scope/             # The per-instance `scope`: builders, labels, validators
│   │   ├── vocab/             # The `kix` arg passed to packages (compose.nix), RBAC DSL, CRD builders, quantity, StorageClass vocabulary, pins, mergeFragments
│   │   ├── plugins/           # netpol (CiliumNetworkPolicy derivation), availability (spread and PDBs)
│   │   ├── flavors/           # k3s, kind, kubeadm, eks, gke, gke-autopilot, aks, openshift, rke2, talos, scaleway, ovh
│   │   ├── modules/           # Reusable cluster modules (monitoring.nix)
│   │   ├── rules/             # Built-in scorecard rules: security, reliability, governance, architecture
│   │   ├── modules.nix        # NixOS-style cluster option schema
│   │   ├── helm.nix           # Helm bridge (tiers 1+2)
│   │   ├── helm-dag.nix       # Helm chart DAG reconstruction
│   │   ├── scorecard.nix      # Rule engine
│   │   ├── unsafe.nix         # The `meta.unsafe` grant vocabulary
│   │   ├── env.nix            # mkEnv multi-env stamping
│   │   ├── meta.nix           # Version checks, peekPackageMeta, diagnostics
│   │   └── mkFlake.nix        # Flake boilerplate generator
│   ├── packages/              # Reusable kix packages (~60)
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
└── docs-legacy/
    ├── BEST-PRACTICES.md      # High-level guidance
    ├── HANDBOOK.md            # ← This file
    └── FEATURE-CATALOG.md     # Breadth-first feature inventory
```

**When to edit each:**

| You want to … | Edit |
|---|---|
| Add or change a package's K8s resources | `kix/packages/<pkg>/default.nix` |
| Add a cluster | `clusters/`, `ludo/`, or `nw1/` |
| Add a kix DSL helper | `kix/lib/vocab/compose.nix` |
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
| `kix diff <cluster>` | Read-only diff vs live, or vs a directory (previous build result, snapshot, export) | `--from <dir>`, `-o json|yaml|markdown` |
| `kix plan <cluster>` | What a deploy would do, as a server-side dry run: field changes, refused writes, drift, prune | `--prune`, `--reconcile`, `--force-conflicts`, `--current-activation`, `--save F.kixplan`, `-o markdown` |
| `kix check <cluster>` | Eval (constructor validators, cross-resource checks, scorecard errors) + scorecard report | `--sarif` |
| `kix deploy <cluster>` (alias `apply`) | Wave-based apply with confirmation | `-y`, `--dry-run`, `--reconcile`, `--prune`, `--operator`, `--tui`, `--log-format=line|json|pretty` |
| `kix status <cluster>` | Resource health table | `--operator` (group by package) |
| `kix list clusters` | List flake clusters | |
| `kix list packages` | List registered packages | `--cluster <name>` |
| `kix graph <cluster>` | DAG visualization | `--format tree|dot|json` |
| `kix inspect <cluster>` | Rendered resources by namespace and kind | |
| `kix gc <cluster>` | Garbage-collect stale resources; retire old Activation records | `--hard`, `--operator`, `--keep N` (always keep the N newest rollback targets, default 10), `--keep-max N` (never more than N, default 50), `--keep-for 30d` (retire older, default 30d, `0` off), `--include-unstamped`, `--include-unattributed`, `--include-copies`, `-y` |
| `kix rollback <cluster>` | Roll back to a previous activation | `-y`, `--dry-run`, `--prune`, `--list`, `--operator` |
| `kix health <cluster>` | Drift detection vs live | |
| `kix snapshot save <cluster> <dir>` | Dump one Kix cluster's live state | |
| `kix logs <package>` | Shell-out to `kubectl logs` for the package's primary workload | `-f`, `--tail`, `--since`, `-c`, `-p` |
| `kix pf <package> <port>` | Shell-out to `kubectl port-forward` | `--address` |
| `kix images <cluster>` | List all container images (pull-friendly) | `--sources`, `-o json` |
| `kix export <cluster> --out <dir>` | Plain-YAML export for handoff | `--for=exit|audit` |
| `kix sbom <cluster>` | CycloneDX 1.6 SBOM | |
| `kix attest <cluster>` | SLSA v1 provenance | `--builder-id`, `--invocation-id` |
| `kix audit <cluster>` | Compliance bundle (SARIF + SBOM + provenance + OSCAL + report) | `--out` |
| `kix completions <shell>` | Generate completions | bash/zsh/fish |

**Global flags:** `-o text|json|yaml`, `-v|-vv|-vvv`, `-q`, `--no-color`, `--context <ctx>`, `--flake <path>`, `--no-cache` (bypass SQLite eval cache), `--override-input <name> <url>`. A subcommand's `--help` lists only the ones it reads (`SCOPED_GLOBALS` in `cli/kix-cli/src/cli.rs`); the rest are accepted and ignored.

**Env vars:** `KIX_LOG` overrides the log-filter (RUST_LOG syntax). Apiserver transport (every command and the operator share one policy; defaults suit a cluster mid-incident, override only to debug): `KIX_RETRY_ATTEMPTS` total attempts per request (default 7, `1` disables retries), `KIX_SWEEP_CONCURRENCY` parallel LISTs in the managed-resource sweep (default 8), `KIX_REQUEST_TIMEOUT` per-attempt deadline in seconds for non-watch requests (default 120, `0` none), `KIX_CONNECT_TIMEOUT` TCP connect timeout in seconds (default 15), which also sets the deadline for the first-contact probe (`KIX_PREFLIGHT=0` skips it), `KIX_STALL_TIMEOUT` seconds of no progress before `kix deploy` gives up (default 600, `0` never; a `stalled:` line naming every resource in flight, its phase and its age prints after 30s of no progress regardless; a resource that keeps reporting readiness without reaching it is not a stall, so for it a `waiting:` line with its last readiness message and the readiness budget prints at 10s, 30s, 60s, 120s, then every minute). A retry the API server's rate limiter forces is logged only at debug level; a request that outlasts its retries still warns. Retries: 429 always, with `Retry-After` honoured; 5xx and connection loss only for idempotent requests (GET, DELETE, PATCH including server-side apply). A request that still fails after the retries is an error, never an empty result: `diff`, `deploy` and `gc` refuse to plan from a partial view of the cluster. Resource types the account may not list (403) are reported, not hidden. First contact: every command proves the apiserver answers before doing anything else, so an unreachable cluster fails in seconds with the endpoint named instead of hanging on whatever request happened to run first. A refused port fails in 0.1s, a blackholed address in 15s, and an endpoint that completes the handshake and then goes silent in 20s.

**Exit codes:** `0` success; `1` error / failed resources; `2` differences detected (diff).

## 4. The eval pipeline

```
flake.nix → mkFlake.nix → buildCluster (eval/cluster.nix)
  → evalModules (modules.nix)            # merge cluster config
  → auto-instantiate (eval/auto.nix)     # activate optionals + transitive required deps
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
→ cluster-wide unambiguous match → arg default → error. An explicit override
that is a `ref.<ns>.<inst>` pointer resolves to that instance and is then
treated as an auto-resolved dep (config injection, `meta.scope`, version
checks); any other explicit value is bound as it is and receives no
injection. Aliases (instance-level
or package `meta.defaultAliases`) participate in the index. Managed instances
beat imports.

**Platform imports are shadowable.** Flavors declare e.g. `platform-dns`
via `kix.mkImport`. A coredns instance claims the `dns` role
(`meta.roles`), so it wins over the import wherever it runs, and workloads
order after its Service. Under `networkPolicy.enable` it must run in
`kube-system`: the enforcer's DNS egress rule allows only kube-system pods
labelled `k8s-app: kube-dns`, and the package refuses another namespace.
Breaks otherwise circular bootstrap dependencies.

Read `kix/lib/architecture.md` for the full set of non-obvious patterns
(store-path = DAG edge, `_type` marker = leaf, `_kix.*` internal metadata,
capability ownership, etc.).

## 5. Package authoring contract

A package is a function `{ scope, lib, kix, ... }: { meta?, options?, config?, deps?, build }`.

```nix
# kix/packages/<pkg>/default.nix
{ scope, lib, kix, availability }:
let
  name = scope.instanceName;
  who = "myapp ${scope.namespaceName}/${name}";   # prefix of every message the package raises
in
{
  meta = {
    version       = "1.2.0";
    description   = "Short, single-line.";
    owner         = "platform";               # "platform" or "app-team"; governance.hasOwner warns without it
    lifecycle     = "stateful";               # "stateless" (default, omit) | "stateful" | "ephemeral"
    scope         = "namespace";              # "cluster" (default) | "namespace": resolution skips it for consumers in other namespaces; an explicit ref from one fails
    roles         = [ "storageClasses" ];     # infra-role claim, closed registry (kix/lib/eval/roles.nix); role name doubles as a DI alias. Infra packages only.
    defaultAliases = [ "storage" ];           # DI aliases when no instance-level aliases set
    conflictsWith = [ "alt-pkg" "cluster:alt-cni" ];  # a cluster: prefix makes the exclusion cluster-wide; "cluster:<own alias>" marks the package one per cluster
    k8s.minVersion = "1.26";                  # versions: [v]N(.N)*[-suffix][+build]
    compatibleWith.machineLearning = {        # version bounds on a dependency's meta.version
      minVersion = "1.100.0";                 # unknown versions warn, out of range fails
      reason = "the server and its ML worker ship together";
    };
  };

  # Per-dep diagnostics, co-located with the dep. Key checks on a secret
  # dependency go through kix.checkSecretKeys in the build instead (§9.1).
  deps = {
    database.config = { ... };                # config injection forwarded to the dep
    database.assertions = dep: lib.optional (...) { assertion = false; message = "..."; };
    database.warnings   = dep: lib.optional (...) "soft warning";
    storage.warnings    = dep: lib.optional (kix.parseQuantity "memory" (dep.out.size or "0") < 50 * 1024 * 1024 * 1024)
      "library storage is ${dep.out.size}; recommended >= 50Gi";
  };

  options = {
    image = kix.options.image { repository = "docker.io/myapp/server"; tag = "v1.0.0"; };
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; };
    };
    resources = kix.options.resources { requests = { cpu = "100m"; memory = "128Mi"; }; };
    env = kix.options.env;                    # rendered through kix.mergeEnv
    ingress = kix.options.ingress;            # standardized { host, annotations }
    metrics = kix.options.monitor;            # standardized { enabled, interval }
    # Same release as `image`; its tag follows `image.tag` through `config`.
    # Declare both tags from one `let` binding so they cannot drift apart.
    worker.image = kix.options.image { repository = "docker.io/myapp/worker"; tag = "v1.0.0"; tagText = "config.image.tag"; };
  };

  # The package's own config module: an attrset or `{ config, clusterConfig, lib, ... }:`,
  # evaluated with `options`, dependency injections and the instance config.
  # Its lib.mkDefault runs at priority 1250, so an instance or injection that
  # sets the option wins, even with lib.mkDefault (see below).
  config = { config, ... }: {
    worker.image.tag = lib.mkDefault config.image.tag;
  };

  build = [
    # Build is a function OR a list of functions. As a list, each entry's deps
    # are discovered independently and results are merged into the parts
    # attrset; two entries defining the same part name are an error.
    # This is how kix.expose / kix.monitor compose: they're build entries that
    # declare their own DI deps.
    ({ self, config, database, storage, scope, kix, reloader ? null, ... }:
    let
      healthCheck = { httpGet.path = "/health"; httpGet.port = "http"; periodSeconds = 10; };
    in
    {
      libraryMount = kix.mount.pvc storage { mountPath = "/data"; };

      deployment =
        {
          name = "${name}-server";
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [{
              name = "server";
              image = kix.image.ref config.image;   # repository:tag@digest
              # The package owns the variables it wires from dependencies;
              # an instance that sets one in `env` gets an error naming it.
              # Optional dependencies (such as prometheus on kix.monitor) must
              # not mutate a disruptive workload's pod env directly when they
              # resolve; gate pod-template changes on an explicit option
              # (`config.metrics.enabled`) instead.
              env = kix.mkEnvVars (kix.mergeEnv {
                inherit who;
                defaults = lib.optionalAttrs config.metrics.enabled {
                  METRICS_ENABLED = "true";
                };
                owned = [ {
                  vars = {
                    DB_HOST = database.out.host;
                    DB_PORT = toString database.out.port;
                    # From the dep's Secret in this namespace: no cross-ns reads.
                    DB_USERNAME = database.out.credentials.out.keyRef "username";
                    DB_PASSWORD = database.out.credentials.out.keyRef "password";
                  };
                  from = "the database dependency";
                  fix = "Wire a different database instance through deps.database instead.";
                } ];
              } config.env);
              resources = config.resources;
              ports = [ (kix.port "http" 8080) ];
              livenessProbe = healthCheck;
              readinessProbe = healthCheck;
            }];
          };
        }
        |> kix.withMounts [ self.libraryMount ]
        |> (if reloader != null then reloader.out.withReloadOn [ database.out.credentials ] else lib.id)
        |> scope.mkDeployment;

      service = self.deployment |> kix.service.fromWorkload { name = "${name}-server"; } |> scope.mkResource;

      root = self.service;          # entry point: resources reachable via self.* are auto-tracked
    })

    # Composable build entries declare their own deps:
    (kix.expose  { service = "service"; })
    (kix.monitor { service = "service"; port = "metrics"; })
  ];
}
```

A package's `config` is for defaults. Every `lib.mkDefault` in
it is evaluated at priority 1250 (`packageDefaultPriority` in
`kix/lib/eval/resolve.nix`), between `lib.mkDefault` (1000) and an option's
declared default (1500). The package default replaces the declared default,
and anything an instance or a dependency injection sets replaces the package
default, `lib.mkDefault` included. The rewrite reaches through `lib.mkIf`,
`lib.mkMerge` and `lib.mkOrder`. Other priorities are left as written: a
plain value in the package's `config` is a fixed setting that conflicts with a
plain instance value, and `lib.mkForce` there beats the instance. Module
errors name the option as `instances.<ns>.<inst>.config.<option>` and each
definition's file: the package's module reads `package config of
<namespace>/<instance>`, an injected one `config injected into <ns>/<inst> by
<source>`.
Package and instance config modules receive `clusterConfig` as a module
argument, so a default can derive from a cluster fact:
`config = { clusterConfig, ... }: { zone = lib.mkDefault clusterConfig.clusterDomain; };`.

**Option contract.** An option's default must survive an instance that sets
only part of the option, because the module system replaces an attrset
default as a whole once any definition exists. `kix/lib/eval/options.nix`
refuses three declarations: an untyped option (`anything`, `unspecified`,
`raw`, `attrs`, or `attrsOf` of those) with a non-empty attrset default; an
`attrsOf`/`lazyAttrsOf` of any other type with a non-empty default; and a
submodule whose own default sets a key its field does not default to the
same value. An option without `type` counts as `unspecified`; a `coercedTo`
whose source type rejects the default counts as its final type; a default
wrapped in `lib.mkDefault`, `lib.mkOverride`, `lib.mkOrder`, `lib.mkMerge`,
or `lib.mkIf` is checked as the value it wraps. The default of an option
whose type takes no attrset (`str`, `int`, `listOf`) is not evaluated, so it
may read a sibling field with no default. A declaration the walker cannot
read is a violation too: a default that throws, a default with any other
`_type`, a submodule that throws when evaluated with `{ }`, a non-empty
attrset default on a type no rule covers (`attrTag`, or a `coercedTo` whose
source type accepts the default), a non-option entry in `options`, and
nesting deeper than twelve levels. A recursive submodule type stops at the
first option that repeats a declaration on its path. The remedies are a
submodule whose fields carry their defaults (`kix.options.resources` for
container resources), entries set one by one with `lib.mkDefault` in the
package's `config` over a `{ }` default, or a `null` default that the build
replaces with the package's value, named in a `defaultText`. The error lists
every violation with its file and line, under `the options of <who> break
the option contract`.

`kix.checkPackageOptions { package; who ? ...; scope ? ...; }` checks one
package: it calls phase 1 at each availability level up to the package's
`meta.availability.max`, with the `kix` an instance at that level receives,
returns null when the options pass, and throws otherwise, naming the levels
of a violation that occurs at some levels only (`kix.packageOptionViolations`
returns the list). Instance evaluation does not check the contract, so a
cluster that uses a package outside kixpkgs never runs it. kixpkgs runs it
in `every-package-evaluates` (`kix/package-eval.nix`, for every package
before any synthetic cluster); `mkFlake { packages.<name> = ./pkg; }` adds
the check `option-contract-<name>` for a package a flake defines. One
kixpkgs package:
`(import ./kix/package-eval.nix { inherit lib kix; }).checkOptionContract "<name>"`
returns null or throws; the full commands are in
`docs/src/content/docs/reference/package-schema/options.mdx`.

### 5.1 Build args

| Arg | Provided by | Use |
|---|---|---|
| `self` | fixpoint | Lazy-recursive ref to this build entry's return attrset (for cross-resource refs) |
| `config` | NixOS module eval | Evaluated per-instance options |
| `clusterConfig` | cluster eval | The cluster's full `config.*`: `clusterConfig.clusterDomain` (in-cluster DNS suffix), `clusterConfig.cluster.domain` (public base domain, §14) |
| `scope` | per-instance | The scope object (see §6) |
| `lib` | nixpkgs | Standard nixpkgs lib |
| `kix` | from `vocab/compose.nix` | Composition helpers (see §9) |
| `deps` | resolution | All resolved DI deps as a single attrset (rarely needed — usually destructure individual deps as args) |

DI dep args: `{ requiredDep, optionalDep ? null, ... }`. The `?` default makes a dep optional. System args (`self`, `config`, `clusterConfig`, `scope`, `lib`, `kix`, `deps`) are stripped during dep discovery; everything else is treated as a DI dep.

### 5.2 `self` and dependency tracking

- `"${self.x}"` — reads the resource's outPath and creates a Nix store-path edge in string context. **Names** in K8s manifests are real names (not store paths) — see §8. Use `self.x.out.name` instead of `"${self.x}"` when you need a string for use in spec/data fields.
- `self.x.out.name`, `out.fqdn`, `out.selector` — these all carry the resource's store-path context, so reading them creates a DAG edge.
- `requires = [ self.x ]` — explicit dependency edge that isn't reached via string interpolation. Use for label-based references (Service selector, PDB, NetworkPolicy) or for ordering against resources whose store path you wouldn't otherwise see.
- `extraDeps = [ self.x ]` — same as `requires` but tagged differently in the `kix.run/depends-on` annotation. Use when the edge is structural rather than "requires this to exist before me".
- `rawSelector` — workload-only escape hatch that exposes `spec.selector.matchLabels` without forcing the workload's store-path context. Use when reading `out.selector` would create a cycle. Trade-off: the consumer loses the workload DAG edge — `scorecard:architecture.selectorCoherence` fires to keep the workaround visible.

### 5.3 Reserved part names

Two part names are folders, not resources: `secrets` and `crds` (`knownFolders` in `kix/lib/eval/helpers.nix`). The package view expects `secrets.<name> = scope.mkSecret { ... }` and `crds.<name> = scope.mkCRD { ... }` under them and refuses a resource assigned to the folder itself ("'secrets' must be an attrset of resources, not a resource directly"). Name a single Secret part something else, e.g. `credentials`. A package may also define `out.crds` or `out.secrets` (operators expose `out.crds.<Kind>`). The view then shows the `out` value under that name and leaves the folder out of the view. The folder's resources are still emitted, and the package's own build still reads them as `self.crds.<name>`. Consumers read `dep.out.crds.<Kind>`.

Two build entries that return the same part name are an evaluation error naming the part (`eval/instance.nix`); rename one, or use `partsOverlays` to replace a part on purpose. Put user-keyed sets under a folder part (`proxyClasses.<name>`).

### 5.4 Warning system

`scope.mkDeployment`/`mkStatefulSet`/`mkDaemonSet` emit `builtins.trace` warnings for:

- **Redundant requires** — resource is already reached via `"${self.x}"`; drop from `requires`.
- **Duplicate requires** — same resource listed twice.
- **Orphaned resources** — defined in `self` but unreachable from `root`.

Fix all warnings before committing.

### 5.5 Inline-attrset packages

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
| `scope.networkPolicyEnforcer` | attrset or null | The network-policy enforcer's `out`, with its rule builders under `netpol`; null when network policy is off, no enforcer exists, or this is the enforcer's own instance |
| `scope.networkPolicyEnforced` | `{ ingress; egress; }` or null | The directions `networkPolicy.directions` enforces, as booleans, when `scope.networkPolicyEnforcer` is set, else null. A policy section for a direction that is false isolates pods that default deny leaves open in that direction; `kix.operandPolicy` drops such sections |

### 6.2 Resource builders

| Symbol | Signature / Notes |
|---|---|
| `scope.mkResource attrs` | Create a namespaced K8s resource — see §7 for fields. Refuses Deployment, StatefulSet, DaemonSet and Job: a workload is sealed by its typed builder below or not at all |
| `scope.mkClusterResource attrs` | Same, cluster-scoped (omits `metadata.namespace`) |
| `scope.mkDeployment attrs` | Workload wrapper. Sets apiVersion/kind, copies `selector.matchLabels` to `template.metadata.labels`, validates, runs per-workload CNP generation. Pipe-friendly. `name` required. |
| `scope.mkStatefulSet attrs` | Same; expands `headlessService` shorthand (auto-creates the headless Service) |
| `scope.mkDaemonSet attrs` | Same |
| `scope.mkJob attrs` | Same; the selector may be omitted (template labels stand in) |
| `scope.mkHelmWorkload attrs` | Helm-sourced workload (used internally by `importChart`). Runs the pod-spec validators `mkDeployment` runs, except the DI-tracked reference check: chart names are plain strings, and the cross-resource checks resolve them instead |
| `scope.mkOptional cond builder` | Gate a resource on a boolean. `builder` may be a thunk `(_: ...)` to avoid eager eval when `cond` is false |
| `scope.mkSecret { ... }` | Secret with enriched `out` (see §21). **Always** use this instead of `scope.mkResource { kind = "Secret"; }` |
| `scope.mkSecretRef { ... }` | Reference an externally-managed Secret (Vault, ESO, cert-manager). Emits a PackageInstance import marker; deploy verifies the Secret exists before applying dependents. See §21 |
| `scope.mkServiceRef { name, selector, ports, labels?, requires? }` | Reference an externally-managed Service (operator-provisioned). `out.{name, fqdn, port, labels}` carry context (`out.fqdn` is `${name}.${ns}.svc.${clusterDomain}`, the same form as a rendered Service); `out.{selector, ports}` are the declared shapes. The marker is Ready when the Service has ready endpoints |
| `scope.mkWebhookService { ... }` | Builds Service + ValidatingWebhookConfiguration + MutatingWebhookConfiguration in one call |
| `scope.mkCRD spec` | Create a CustomResourceDefinition. Pair with `crd.fromKind` builders (§22) |
| `scope.mkCRDRef { group; kind; plural; version; ... }` | CRD marker (no CRD resource). `version` is required: the API version the CRD serves. Use when the CRD is owned externally (§22) |
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
  ownership.cede = [ ... ];  # field paths another controller takes over after creation (see below)
  clusterDomain = "...";     # rarely overridden; the scope passes the cluster's clusterDomain
}
```

**Ceded fields.** An operator that rewrites an object kix applied takes ownership of the fields it rewrites, and the next server-side apply of the same object meets a 409 conflict on them; `--force-conflicts` takes them back for the whole deploy and hides real conflicts everywhere else. `ownership.cede = [ "spec.versions" ]` says which fields the resource expects to lose: kix sets them at creation, and when a later apply conflicts only on ceded paths it applies again without those fields, so the operator keeps them. A conflict on any other field still fails. Paths use the apiserver's own syntax without the leading dot, with `*` for any list element (`webhooks[*].rules`); `scope.mkCRD` takes the same argument. cdi cedes `spec.versions` (the operator drops a deprecated version). Stamped as `kix.run/cede-fields`.

An operator that writes every entry of an object Kix only has to create, such as StackGres's webhook configurations, gets a metadata-only resource instead (`stackgres-operator`'s `validatingWebhook` and `mutatingWebhook`): Kix owns the labels, the operator owns `webhooks`, and no field is applied by both. Order the operator after the shells (`requires`) so it takes its update path. The operator writes the entries after it reports ready, so custom resources of its kinds still wait for its webhook-check Job (§22).

**`extra.*` shadowing check.** `extra` may NOT redefine `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, `spec` (when `spec != {}`), `data` (when `data != {}`), `stringData` (when `stringData != {}`). The check fires at eval time with a remediation hint. `metadata.labels` and `metadata.annotations` are deliberately allowed because they merge additively with scope-injected values.

**Namespace handling.** `mkResource` doesn't take a namespace arg directly; it comes from `scope`. `mkClusterResource` sets the cluster-scoped sentinel, which omits `metadata.namespace`; it is for cluster-scoped kinds only, and a namespaced kind built with it fails cross-resource check 18 (§17.4).

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

The `kix` arg to packages comes from `kix/lib/vocab/compose.nix` (`kixlib`).

### 9.1 Primitives

| Symbol | Signature |
|---|---|
| `kix.port name containerPort` | `→ { name, containerPort, protocol = "TCP" }` |
| `kix.mkEnvVars { K = "v"; OPT = null; }` | `→ [{ name, value }]`. Null values filtered (`lib.optionalAttrs` plays nicely). A value that is a `valueFrom` source renders as one: `{ PASSWORD = secret.out.keyRef "password"; }`. This is also how a `kix.healthCheck` probe receives a credential, since its `env` goes through `mkEnvVars`. An attrset with no `valueFrom` throws. |
| `kix.mkEnv attrs rawList` | `(mkEnvVars attrs) ++ rawList`. Combines named env vars with raw entries (e.g. `valueFrom.secretKeyRef`) |
| `kix.mergeGuarded { who; locked; what ? "extraSpec"; } base overrides` | `lib.recursiveUpdate base overrides`, refusing at eval when `overrides` carries any path in `locked` (a list of attribute paths, e.g. `[ [ "configuration" "zookeeper" ] ]`), or sets an ancestor of one to a value that is not an attribute set (`configuration = null` would remove `configuration.zookeeper`). For `extraSpec` and `settings` escape hatches: the paths the package computed for correctness cannot be clobbered silently. The error names `who`, the path (and the ancestor that replaced it) and says to use the owning option |
| `kix.mergeEnv { who; owned ? [ ]; defaults ? { }; } env` | `defaults // env // <every owned group's vars>`, for `kix.mkEnvVars`. `owned` is a list of `{ vars ? { }; names ? [ ]; from; fix; }`: `vars` are added and guarded, `names` are guarded only (delivered another way, such as `envFrom`). A guarded key in `env` throws, also when `null`, one line per group: `<who>: env sets DB_HOST, which comes from <from>. <fix>` |
| `kix.guardArgs { who; option ? "extraArgs"; owned; } args` | Returns `args` unless one sets an owned flag (`owned` maps flag → reason and fix). An argument sets a flag when it equals it or starts with `"<flag>="`, so `--ingress-class-by-name=true` passes a `--ingress-class` guard. A one-letter flag (`-c`) also matches `-c<value>`. Every hit is one line: `<who>: extraArgs sets "<arg>", which the package owns: <owned.<flag>>` |
| `kix.contracts.gateway` | The `out` a `gateway` provider publishes (`kix/lib/vocab/gateway.nix`): `gatewayRef` (`{ name; namespace; }`), `listeners` (the Gateway's rendered `spec.listeners`), and `podSelector` and `podNamespace` (the data-plane pods, both null when the provider cannot tell). A provider passes its out through `check who out`, which requires every field (envoy-gateway and traefik use it). `kix.expose` calls `require who dep`, which requires only `gatewayRef`, so a `kix.mkImport` stand-in may publish just that, and checks the shape of the rest. `claims dep` says whether the resolved instance offers itself as a gateway (`out.gatewayRef`, or the `gateway` alias on the instance or in its package's `meta.defaultAliases`); `kix.expose` ignores one that does not, such as an OpenTelemetry Collector named `gateway` |
| `kix.contracts.postgresDatabase` | The `out` a `database` provider publishes (`kix/lib/vocab/postgres-database.nix`): `host` (string), `port` (string; pass an integer through `toString`), `database` (string), `credentials` (a Secret instance with `out.keyRef`; when it declares keys, `username` and `password` among them), `username` (string), `extensions` (names or `{ name; version; }`), and `tls` (bool, or null when the provider cannot tell). A provider package passes its out through `check who out`, which requires every field and throws naming each missing or misshapen one. A consumer sets `deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions who dep;`, which requires `host`, `port`, `database`, and `credentials`, so a `kix.mkImport` stand-in may omit the other three, and checks the shape of those it publishes. The message names the consumer, the instance the dependency resolved to, and each field. The assertion is evaluated after the build, so a field the build reads and the `out` lacks fails first with Nix's missing-attribute error; the assertion reports misshapen fields and absent fields the build does not read. `fields` and `problems out` expose the table |
| `kix.contracts.oidcProvider` | The `out` an OpenID Connect provider publishes (`kix/lib/vocab/oidc-provider.nix`): `issuerUrl` (a function from a realm name to the issuer URL) and `endpoints` (a function from a realm name to `{ authorizationUrl; tokenUrl; userinfoUrl; }`; the authorization URL is public, the other two are what the application's server dials, which keycloak gives as its Service address so the egress is derived). keycloak passes its out through `check who out`, which requires both. A consumer sets `deps.oidcProvider.assertions = dep: kix.contracts.oidcProvider.assertions who dep;`, which requires `issuerUrl`, and calls `requireClient { who; oidc; provider; client; }`, which throws when `oidc.enabled` is set without a provider, a client secret, or `oidc.realm`, and returns `{ issuerUrl; endpoints; }` for the realm (`endpoints` throws on read when the provider lacks it). `clientKeys` is `[ "clientId" "clientSecret" ]`, for `kix.checkSecretKeys` on the `oidcClient` dependency. keycloak answers no alias: two instances answering one would fail every optional `oidcProvider` dependency in the cluster, so a cluster wires `deps.oidcProvider = ref.<ns>.<instance>` |
| `kix.options.oidc { scopes; autoLogin ? null; }` | The `oidc` option set of an application that signs users in through an `oidcProvider`: `enabled` (default false), `realm` (null; required while enabled), `scopes` (the application's default list; one without `openid` is refused), and `autoLogin` (default false; only when the application has such a setting, named in `autoLogin`). harbor adds `groupsClaim` and `adminGroup`, which its assertion reads; grafana and immich take role mapping through `settings` (`auth.generic_oauth.role_attribute_path`, `oauth.roleClaim`) |
| `kix.contracts.otlpEndpoint` | The `out` an `otlp` provider publishes (`kix/lib/vocab/otlp-endpoint.nix`): `otlpGrpcUrl` and `otlpHttpUrl` (strings, `scheme://host:port` with no path; an OTLP/HTTP exporter appends `/v1/traces` and the other signal paths itself) and `tls` (bool, or null when the provider cannot tell). A provider passes its out through `check who out`, which requires every field. A consumer sets `deps.otlp.assertions = dep: kix.contracts.otlpEndpoint.assertions who dep;`, which requires the two URLs, so a `kix.mkImport` stand-in may omit `tls`. `tempo` and `otel-collector` publish it; `alias` is `"otlp"`. Tempo does not answer the alias by default, so a consumer names it with `ref`, or the cluster adds `aliases = [ "otlp" ]` to the instance. |
| `kix.checkSecretKeys { who; arg; dep; keys ? [ ]; anyOf ? null; }` | Returns `dep` (a secret dependency; `null` passes through) once `dep.out.keys` declares every name in `keys` and, with `anyOf` (a list of key groups), every name of one group. Read the secret through the result so the check runs before any `keyRef`; a `deps.<x>.assertions` key check never shows, because `keyRef` throws first. Message: `<who>: deps.<arg> resolved to secret "<name>", which declares <keys or no keys>; this package reads <missing>. Add them to that instance's keys (a SOPS secret lists them in keys), or wire another secret with deps.<arg> = ref.<ns>.<instance>.` |
| `kix.parseQuantity resource q` | The Kubernetes quantity `q` in millicores when `resource` is `"cpu"`, in bytes otherwise, rounded down, as an integer; `null` when `q` is not a quantity. Same grammar as `kix.types.quantity` (non-negative decimal or integer, optional suffix `m k M G T P E Ki Mi Gi Ti Pi Ei`; no sign, no exponent). A value above the signed 64-bit range (`"8Ei"`), or with more than 18 significant digits (leading zeros and trailing fraction zeros do not count), throws, and the error says which limit it exceeds; the type refuses it too. The type checks the range in bytes, so a cpu value can pass it and still throw in millicores (`"2Ei"`). Discards string context, so it works on `dep.out.size` |
| `kix.untrackedRef "name"` / `kix.untrackedRef { kind; name; by; apiVersion? }` | A name Kix does not render. The string form is a bare claim: an inert marker that satisfies the ref check and is filtered out of `kix.run/depends-on`, listed by the `untrackedReferences` audit. The attrset form (experimental, 2026-09-20) names the creator (`by`, a Job or workload resource) and the kind: the referring resource depends on the creator, and is stamped `kix.run/expects` so `kix deploy` waits for the object to exist before applying it, and the audit leaves the name out when no bare reference to it exists in the same namespace (`ingress-nginx` does this for the Secret its admission Job mints). `by` rejects built-in kinds that create nothing (ConfigMap, Secret, Service, PVC, ServiceAccount, RBAC, NetworkPolicy, APIService and similar, listed in `core/markers.nix` `passiveKinds`, matched by API group); every other kind, including any custom resource, is accepted; a Namespace is accepted because the control plane creates `kube-root-ca.crt` and the default ServiceAccount in it. `kix.untrackedRef { name; by = "self"; }` says the resource holding the reference creates the object (an operator mounting an optional Secret it mints, as in `kubevirt` and `stackgres-operator`): it adds no dependency and no `kix.run/expects`, takes no `kind`, fails in a passive kind, and fails in a workload's volume, `env`/`envFrom` ref or `serviceAccountName` unless that reference sets `optional = true`, since the pod cannot start to create what it requires. The audit leaves the name out only when exactly one resource in the cluster carries a self reference to it; a self reference passed to another resource through `out` lists the name |
| `kix.providedLoadBalancerClass { class; by; }` | The `spec.loadBalancerClass` value a load balancer provider publishes on its `out`: `class` with a marker and the context of `by`, the resource that serves it. A Service naming it depends on `by`, skips the `loadBalancer` role check, and gets no external-ingress allowance (§16.7). Refuses a missing or non-resource `by` |
| `kix.keep container` | Marks an attrset "never collapse to absent": it renders as `{}` even when every member is null, and the protection survives later merges that introduce fresh nulls (additive `_kixKeep` marker, resolved at `mkResource`, never rendered). Lists are normalized eagerly instead, since merges replace lists whole. Use in constructors of presence-meaningful fields (`emptyDir`, selectors) built from optional arguments; a hand-written empty needs no keep, a literal `{ }` renders as-is (§7) |
| `kix.keys.<name>`, `kix.keyValues.<name>` | Kix's own annotation keys and the values Kix compares them against, from `core/annotations.nix`. A package Job that should be deleted and created again on change sets `annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;` |
| `kix.operandPolicy { scope; name; spec; }` | A network policy over pods an operator creates from a custom resource, labelled derived and `operator-managed-workload`. Drops the sections of a direction the cluster does not enforce; null when the scope has no enforcer or no section is left (§16.6) |

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
| `kix.service.fromWorkload { name, type?, ports?, outputs?, ... }` | Pre-seal Service attrset from a workload. Auto-derives selector from `workload.out.selector` and ports from container spec. **Validates** that any user-supplied string `targetPort` matches a named container port, then **writes the container port number** in its place: the netpol layer copies `targetPort` into every consumer's egress rule and cilium drops egress on a named port (verified on 1.19). A hand-written Service must use numbers too; the cilium translator warns when it sees a name. Pipe to `scope.mkResource` |
| `kix.ingress.fromService { name, host, path?, pathType?, port?, className?, tls? }` | Pre-seal Ingress from a Service. Auto-derives backend name + port |
| `kix.httpRoute.fromService { name, host, parentRef, path?, pathType?, port?, timeouts? }` | Pre-seal HTTPRoute (Gateway API) from a Service; build it with `scope.mkCR` from a `scope.mkCRDRef` for `gateway.networking.k8s.io/HTTPRoute` |

Where `parentRef` is `{ name, namespace? }` — typically `gateway.out.gatewayRef`.

### 9.4 Composable build entries

These return functions whose own DI args are auto-discovered.

**`kix.expose`**: auto-creates `Ingress` or `HTTPRoute` based on which DI dep is wired:

```nix
(kix.expose {
  service ? null,                # string: part name in self (single-backend mode)
  paths ? null,                  # list of { path, pathType?, service, port? }: several backends behind one host
  partName ? "route",            # the Ingress or HTTPRoute part
  exposurePart ? "exposure",     # record part: { via; host; scheme; url; urlOrNull; }
  defaultAnnotations ? {},       # package-level Ingress annotations
  port ? null,                   # override auto-derived service port
  timeouts ? null,               # Gateway mode only: HTTPRoute rule timeouts, e.g. { request = "0s"; }
  deriveHost ? true,             # false: route only when config.ingress.host is set
})
```

- `gateway` DI dep present → emits `HTTPRoute` (TLS is the Gateway's concern), built with `scope.mkCR` from a CRD ref part `<partName>Crd` (`routeCrd`); two `kix.expose` calls in one instance share one marker.
- `ingressNginx` DI dep present → emits `Ingress` with optional TLS via `clusterIssuer`.
- Both present → fail loudly (ambiguous; cluster must wire exactly one).
- Neither present → no exposure resource emitted.
- The host is `config.ingress.host`, else `<instance>.<cluster.domain>`. With `deriveHost = false` only `config.ingress.host` counts: an instance without it gets no route and `exposure.via` is null, with no error. Grafana uses this because its route also serves its unauthenticated `/metrics`.
- `service` and `paths` are mutually exclusive. `paths` renders an Ingress with a rule per path, or one HTTPRoute with a rule per path in Gateway mode; `pathType` uses the Ingress words (`Prefix`, `Exact`) in both and is translated for the Gateway.
- The record part (`self.exposure`) describes the rendered route: `url` is `<scheme>://<host>[:port]`. Ingress: `https` when a `clusterIssuer` is wired, else `http`. Gateway: from the listener the HTTPRoute attaches to (protocol, hostname, `allowedRoutes.namespaces.from`); no matching listener fails; a gateway without `out.listeners` gives `scheme = null`. Reading `url` without a route or a scheme fails evaluation with a message naming the instance and the cause (nothing wired, no host, or the Gateway that publishes no listeners); a package that works without a URL reads `urlOrNull`, which is null then (metabase, n8n, and harbor, which falls back to its own `externalURL` message). The record carries `_type = "kix-exposure"` so the part walkers do not force `url`. The TLS Secret is `<instance>-tls`.
- With `networkPolicy.enable` on, the Ingress path also emits one policy per backing Service, opening that Service's pod port to the controller's pods and nothing else. An Ingress routes but opens nothing, so without it a default-deny cluster answers every request through the Ingress with a 504 that evaluation cannot see. The controller supplies the two facts through its root `out`: `podSelector` and `podNamespace`. A controller package that publishes neither gets a warning and no policy. In Gateway mode the policy is `<service>-from-gateway` and comes from the gateway's `out.podSelector` and `out.podNamespace` (`kix.contracts.gateway`); traefik publishes its own pods. envoy-gateway publishes the labels Envoy Gateway puts on the proxy pods and its `proxyNamespace` option (`envoy-gateway-system` by default, the controller's namespace). The policy is ingress-only, so it is not written when `networkPolicy.directions = "egress"`. A Service without a selector gets no policy and a warning, because an empty selector would admit the controller to every pod in the namespace. With TLS from a `cluster-issuer` whose ACME solver uses `http01`, the Ingress path also emits `<instance>-acme-solver-from-ingress-controller`, admitting the controller to cert-manager's solver pods (`clusterIssuer.out.http01SolverSelector`) on TCP 8089 in the instance's namespace. An imported issuer without `out.http01SolverSelector` gets a warning and no solver policy. cert-manager's self-check fetches the challenge through the public URL first, and where Cilium replaces kube-proxy that request can still be dropped under default deny (the public-URL hairpin).
- In Gateway mode `kix.expose` holds the `gateway` dependency to `kix.contracts.gateway` and throws when its `out` lacks `gatewayRef` or carries a misshapen field. The `gateway` argument also resolves to an instance merely named `gateway`; one that neither publishes `out.gatewayRef` nor answers the `gateway` alias is ignored, as if no gateway were wired. With a network-policy enforcer and a gateway whose `out.podSelector` is null (envoy-gateway with another `controllerName` or `proxyNamespace = null`), `kix.expose` warns, because nothing admits the proxy pods to the backend.

**`kix.monitor`**: auto-creates `ServiceMonitor` + optional `PrometheusRule` when `prometheus` DI dep is present:

```nix
(kix.monitor {
  service,                       # string: part name in self
  port ? "metrics",              # name (string) or number (int)
  path ? "/metrics",
  scheme ? "http",               # primary endpoint only
  tlsConfig ? null,              # primary endpoint only; a ServiceMonitor endpoint tlsConfig
  params ? null,                 # primary endpoint only; query parameters, { format = [ "prometheus" ]; }
  honorLabels ? null,            # primary endpoint only; true keeps the target's own `namespace` and `pod` (kube-state-metrics)
  alerts ? {},                   # { alertName = { expr, "for"?, keep_firing_for?, severity?, description?, summary?, runbook_url?, labels?, annotations? }; }
  extraEndpoints ? [],           # each over { scheme = "http"; path = "/metrics"; } and metrics.interval
  extraLabels ? {},
  name ? null,                   # ServiceMonitor name; default the instance name. Rules are `<name>-alerts`.
  monitorPart ? "serviceMonitor",  # part names, so a package with several metrics
  rulesPart ? "prometheusRules",   # Services can call kix.monitor once per Service (harbor)
})
```

The builder consumes `prometheus.out.mkServiceMonitor` and `prometheus.out.mkPrometheusRule`, which the prometheus package exposes on its `out`. `metrics.enabled` and `metrics.interval` are read from `config.metrics` (use `options.metrics = kix.options.monitor;`). `scheme`, `tlsConfig`, `params`, and `honorLabels` set the primary endpoint's; each `extraEndpoints` entry defaults to `scheme = "http"`, `path = "/metrics"`, and the instance's `metrics.interval`.

**`kix.alerts`**: the PrometheusRule half of `kix.monitor` on its own, for a package whose scrape is not one `kix.monitor` ServiceMonitor: a PodMonitor it builds with `prometheus.out.mkPodMonitor` (cnpg-cluster, stackgres-cluster, clickhouse-cluster), or a scrape the operator configures. It renders under the same conditions, a `prometheus` dependency and `metrics.enabled` not false, and renders nothing when `alerts` is empty. A package whose scrape the operator configures has no scrape interval to set, so it declares `metrics = kix.options.alerts;` (only `enabled`) instead of `kix.options.monitor` (the VictoriaMetrics packages).

The PackageInstance requires every part of kind ServiceMonitor, PodMonitor, PrometheusRule, or VMRule, because no other part references them. A package does not list them in `root.requires`, including a PodMonitor it builds itself or a monitor part a `partsOverlays` entry replaces.

```nix
(kix.alerts {
  alerts,                        # as kix.monitor's
  name ? null,                   # rule name `<name>-alerts`; default the instance name
  extraLabels ? {},
  rulesPart ? "prometheusRules",
})
```

#### Writing alerts

The principles are in BEST-PRACTICES §9.6. The `package-review` skill has the review items (`Mo`) and the research steps to follow before writing a package's alerts. This section is the mechanics.

**What `kix.monitor` and `kix.alerts` render.** Each `alerts` entry becomes one rule in a single group named `<name>-alerts`, inside a PrometheusRule of the same name. Only `severity` has a default, `warning`. The builder adds no `for`, no labels, and no annotations, so the package sets every one. It reads only the keys in the signature above and ignores any other. The prometheus package's Prometheus selects every PrometheusRule in every namespace. Under VictoriaMetrics, the operator converts each PrometheusRule into a VMRule, and `victoria-metrics-alert` evaluates every VMRule. The VictoriaMetrics packages render their own alerts as VMRules, by handing `kix.alerts` a `prometheus` whose `out.mkPrometheusRule` is the operator's `mkVMRule`, so they do not depend on the converter and a prometheus-operator Prometheus on the same cluster never loads them.

`alerts` is an attrset keyed by alert name, so a package cannot render two rules with one name. kube-prometheus pairs a `warning` and a `critical` rule under one name, so that inhibition on equal `alertname` drops the warning while the critical fires. A package gives the two levels distinct names (`DiskPoolUsageHigh`, `DiskPoolUsageCritical`) instead.

**Names.** CamelCase, starting with the component (`ClickHouseReplicaReadOnly`, `VeleroBackupMissing`), so a package's alerts sort together. The name states the condition, not the cause.

**Selectors and labels.** Bind the selector once in a `let` and use it in every expression, as Mo5 describes:

```nix
let
  metricsService = "${scope.instanceName}-metrics";
  sel = ''namespace="${scope.namespaceName}",service="${metricsService}"'';
in
```

A PodMonitor's series carry no `service` label. Prometheus Operator and the VictoriaMetrics operator both set `job` to `<namespace>/<PodMonitor name>`, so select on that instead, and aggregate `by (namespace, job)` wherever the patterns below say `by (namespace, service)`:

```nix
sel = ''namespace="${scope.namespaceName}",job="${scope.namespaceName}/${podMonitorName}"'';
```

Aggregate with `by (namespace, service, ...)`, and keep `namespace` in every result. A bare `sum(...)` drops every label. The alertmanager package's default route groups by `namespace` and `alertname`, and inhibition rules usually compare `namespace`. An alert without it groups and inhibits across the whole cluster. Labels are the alert's identity. Never put a value in a label, because each new value starts a new alert. Values go in annotations.

`absent()` keeps labels only from a plain selector. `absent(up{${sel}} == 1)` returns a series with no labels at all, so prefer the form below.

**Patterns.**

```nix
# The component stopped reporting: every target down, or no target at all.
# Both branches carry namespace and service.
expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
"for" = "10m";

# A metric the other alerts rely on disappeared while the target is up.
expr = "count by (namespace, service) (up{${sel}} == 1) unless on (namespace, service) count by (namespace, service) (foo_ready{${sel}})";

# Last success too old. `kix.schedules.staleAfter schedule` gives two periods
# plus two hours as a duration ("50h" for a daily schedule), or null when the
# period cannot be read; make a threshold option required then. One missed
# run stays quiet while the failure alert reports it. The gauge's own window
# is the age, so a short `for` only rides out a scrape gap.
expr = "time() - max by (namespace, service, schedule) (foo_last_success_timestamp_seconds{${sel}}) > ${toString (kix.durations.toSeconds maxAge)}";
"for" = "5m";
```

A last-success alert evaluates to nothing when its series is missing, and the down alert does not fire while the target is up. Pair it with the missing-metric pattern over the same series. Some programs publish the timestamp only after their first success since start (Velero does), so a missing-metric alert would fire after every restart. Build the alert from the success and attempt counters instead, but only for an age that fits inside the Prometheus retention (7d by default), since `offset` and `increase` see no older sample. `VeleroBackupMissing` uses the counters up to 6d and the timestamp past that, where it stays silent after a restart until the next success.

The down pattern fires only when every target is down. One replica of several down is left to kube-prometheus's `TargetDown` (`warning`, more than 10% of a job's targets down for 10 minutes). A per-target `up == 0` alert at `critical` on a DaemonSet pages for one node, which the generic node alerts already report. When the component can run with zero replicas by design, or its metrics Service can be switched off, gate the rule on the same configuration, or `absent()` fires.

A ratio alert, such as errors over requests, divides by traffic. At ten requests an hour one failure is a 10% error rate. Add a floor: `... > 0.05 and sum by (namespace, service) (rate(foo_requests_total{${sel}}[5m])) > 1`, with the floor an option when no default fits every site.

Apply `rate()` or `increase()` to the raw counter first and aggregate second: `sum by (namespace, service) (rate(foo_total{${sel}}[5m]))`. A rate over an aggregated subquery, `rate(sum(foo_total)[5m:])`, reads any drop in the sum as a counter reset. Cover at least four scrape intervals with a range window, so a failed scrape and misaligned timing still leave enough samples ([Robust Perception](https://www.robustperception.io/what-range-should-i-use-with-rate/)). `[5m]` is safe for scrape intervals up to 75 seconds.

**`for`.** Use at least `5m`, so a restart or a rollout does not fire the alert. A down alert uses `10m`, like kube-prometheus's `TargetDown`. A threshold on a gauge that moves around uses `15m`. Leave `for` out only when the expression already spans a long window, such as `increase(foo_failures_total[1h]) > 0`, and say so in a comment. `keep_firing_for` holds an alert after its condition clears, which stops a flapping condition from resolving and refiring. Prometheus 2.42, prometheus-operator 0.66, and vmalert all support it.

**Thresholds.** Derive a threshold from evaluated configuration where the package has one: `resources.limits.memory` through `kix.parseQuantity "memory"`, a replica count, or a schedule. Otherwise extend the monitor options with a typed threshold, as cnpg-cluster does, and derive its default where the configuration allows:

```nix
metrics = kix.options.monitor // {
  maxBackupAge = lib.mkOption {
    type = lib.types.nullOr kix.types.promDuration;
    default = null;
    description = "How long the cluster may go without a completed base backup before CNPGBackupMissing fires ... Null derives it from `backup.schedule` with `kix.schedules.staleAfter` ...";
  };
};
```

**Annotations.** `summary` is one sentence with no template, so every firing of an alert shares it and Alertmanager can group them. `description` uses `{{ $labels.<name> }}` and `{{ $value | humanize }}` (also `humanizePercentage` and `humanizeDuration`) to name the instance and the value. It says what the condition means and what to check first. Set `runbook_url` only to a maintained upstream runbook for the same condition. Nix interpolates `${...}`, not `{{ ... }}`, so templates need no escaping.

**VictoriaMetrics compatibility.** The same rule must work under vmalert:

- Use only template functions that both Prometheus and vmalert define. `float64` is in neither. Prometheus refuses the rule file at load, prometheus-operator refuses the whole PrometheusRule, and the VictoriaMetrics operator's converter refuses the whole rule group. `promtool check rules` reports it. Format numbers with `printf` or the `humanize` functions instead.
- Do not set `query_offset`. The converter maps it to vmalert's `eval_offset`, which means something else.
- Do not compare `increase()` or `rate()` with exact equality. Prometheus extrapolates both and VictoriaMetrics does not, so their values differ slightly. Use `> 0`, or a threshold with margin.
- vmalert restores how long an alert has been pending from remote read after a restart. The `victoria-metrics-alert` package sets `remoteRead.url`, so a long `for` survives restarts there. A vmalert without remote read starts every pending alert over.

**Routing.** The alertmanager package's default settings send everything to a `null` receiver and define no inhibition rules. A site that wants pages writes `settings` with its receivers, and usually a route on `severity`. Packages make that possible by setting `severity` on every rule and keeping `namespace` on every alert. The site also routes `Watchdog`, the always-firing alert in `prometheus-default-rules`, to an external heartbeat service that pages when it stops arriving. Nothing else notices when Prometheus, Alertmanager, or the route to the receiver fails.

**Tests.** A package that ships alerts has a unit test in `kix/lib/tests/units/<package>.nix`, like `reloader-metrics`. It checks that the PrometheusRule renders under the expected name, that every expression contains the instance's selector, and that nothing renders without a `prometheus` dependency or with `metrics.enabled = false`. A unit test does not catch a rule that never matches, so every cluster also gets the flake check `rules-cluster-<name>` (`kix/checks.nix` `rulesCheck`, wired in `kix/lib/mkFlake.nix`). It writes the `spec` of each rendered PrometheusRule and VMRule, which is a Prometheus rule file, to `<namespace>/<file>` and runs `promtool check rules` over them, so a PromQL syntax error, a bad duration, or an unknown template function fails the check. promtool also prints a lint warning, with the word `FAILED`, for a duplicated recording rule; it does not fail the check, and the vendored `kube-apiserver-availability.rules` group has one.

When a cluster file has a sibling with the same base name and the suffix `.rules-test.yaml` (`clusters/test-foo.nix` and `clusters/test-foo.rules-test.yaml`), the check also runs `promtool test rules` on it, from the directory of rendered rules:

```yaml
rule_files:
  - observability/agent-alerts-prometheusrule.yaml   # <namespace>/<file> in the cluster's manifests
tests:
  - interval: 1m
    input_series:
      - series: 'up{namespace="observability",service="agent",instance="10.0.0.1:8888"}'
        values: '1 1 0x14'
    alert_rule_test:
      - eval_time: 14m
        alertname: OtelCollectorDown
        exp_alerts:
          - exp_labels: { severity: critical, namespace: observability, service: agent }
            exp_annotations:
              summary: An OpenTelemetry Collector is down.
              description: Prometheus has scraped no collector of observability/agent for 10 minutes; telemetry sent to it is lost. Check the instance's pods.
```

`clusters/test-otel-collector.rules-test.yaml` is the full example. Give each alert input series that break the condition and series that stay healthy (`exp_alerts: []`). Set `eval_time` past `for` plus one evaluation. `exp_labels` must list every label, including `severity`, and `exp_annotations` every annotation with its templates rendered. The check refuses a test file without `rule_files` and an entry that matches no rendered file, because promtool reads the entries as globs and would otherwise load nothing. The [Prometheus unit-testing docs](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/) give the format.

Run it with `nix build ./clusters#checks.x86_64-linux.rules-cluster-<name> --extra-experimental-features pipe-operators`. Before shipping, check every metric name against the program's source or a scrape at the version the package pins. A misspelled metric name passes both checks.

**`kix.healthCheck`**: a post-deploy probe, a Job in the package's namespace that runs a script against addresses passed in as env vars from `out.*` values. Every callback receives the same `{ self, config, deps }`.

```nix
(kix.healthCheck {
  script,                        # the probe body, usually builtins.readFile ./health-check.py
  env ? (_: {}),                 # -> { NAME = value; }; nulls dropped; RETRY_FOR is added by the helper
  when ? ({ config, ... }: config.healthCheck.enabled or true),    # false renders nothing
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

The probe reads what it expects off the resource it checks, never off the option that produced it: `config.replicaCount` (the package's option, named after the VMAgent field) is what the author asked for, `self.vmAgent.out.replicas` is what the CR says after `extraSpec` had its way.

### 9.5 Reusable option sets

```nix
options.ingress = kix.options.ingress;       # { host = nullOr str; annotations = attrsOf str; }
options.metrics = kix.options.monitor;       # { enabled = bool (default true); interval = nullOr str; }
options.healthCheck = kix.options.healthCheck;  # { enabled = bool (default false); retryFor = int (90) }; kix.healthCheck reads both

# Container resources. The arguments are the package's defaults (cpu,
# memory, ephemeral-storage); each sits on its field, so an instance that
# sets limits.cpu keeps the requests. null removes a default. The value is a
# ResourceRequirements with unset fields absent (no nulls, no empty maps).
# Other names an instance may set: hugepages-<size>, and extended resources
# containing "/" (nvidia.com/gpu); a misspelled name throws.
options.resources = kix.options.resources {
  requests = { cpu = "100m"; memory = "128Mi"; };
  limits.memory = "256Mi";
};

# Extra env vars: attrsOf (null or a string or a valueFrom source).
# A value is a string, a fieldRef, or a secretKeyRef naming a Secret managed
# outside Kix with kix.untrackedRef. A credential that comes from a
# dependency is wired by the package. Render it through kix.mergeEnv.
options.env = kix.options.env;

# A size or other quantity: "500m", "1.5Gi", 2. No sign, no exponent.
options.size = lib.mkOption { type = kix.types.quantity; default = "10Gi"; };

# A package's image. Takes the defaults, returns one mkOption whose type is a
# submodule: { repository, tag, digest = null, pullPolicy = "IfNotPresent",
#              sourceRev = null, promotedBy = null, resolvedAt = null, note = null }
# `pullPolicy = null` leaves imagePullPolicy to Kubernetes. `description`
# replaces the generic option description. An instance that sets some
# fields keeps the package's defaults for the rest. The package's digest is
# kept while `image.tag` equals the package's tag and dropped when the tag
# changes, since a digest belongs to the tag it was resolved from.
options.image = kix.options.image {
  repository = "docker.io/library/nginx";
  tag = "1.27-alpine";
};

# A package that runs the user's image declares no default. A null
# repository or tag leaves that field required; the instance sets it, and
# evaluation names the missing option otherwise.
options.image = kix.options.image { };

# An image released with another one: the package's `config` sets its tag
# from the other option, and `tagText` is the Nix expression the option
# reference shows as the tag's default. `tag` stays the declared default the
# digest rule compares with, so the component's own digest is dropped once
# the followed tag moves. Declare both tags from one binding
# (`release = "0.27.3";` in the package's `let`): a follower declared with an
# older tag would render the main tag with no digest. The kix/lib test
# t128 fails when a shipped package's `config` changes any declared image.
options.exporter.image = kix.options.image {
  repository = "docker.io/altinity/metrics-exporter";
  tag = release;
  tagText = "config.image.tag";
};
config = { config, ... }: {
  exporter.image.tag = lib.mkDefault config.image.tag;
};
```

Use these in your package's `options` so cluster authors see consistent shapes across packages.

Toggles are named `enabled`, as in `kix.options.monitor` and `kix.options.healthCheck`.

Escape hatches, by what the package builds:

| Shape | Option | Merge |
|---|---|---|
| Helm chart | `values` | `lib.recursiveUpdate` over the package's values |
| A resource or CR `spec` | `extraSpec` | `kix.mergeGuarded`; locked paths in the option description |
| The program's own config file | `settings` | `kix.mergeGuarded` over the built-in config |
| Command-line flags | `extraArgs` (`listOf str`) | appended, through `kix.guardArgs` |
| Anything else | instance `partsOverlays`, resource `extra` | |

A program config whose package default names its own parts (alertmanager's routing tree names its `null` receiver) replaces as a whole instead of merging; the option description says so.

To default entries of a typed collection (`attrsOf str`) so that an instance adds to them, declare the option with `default = { }` and set each entry in the package's `config` with `lib.mkDefault` (priority 1250, per attribute). When the package computes a default in the build instead, give the option a `defaultText` naming that value.

## 10. Top-level `kix.*`

These come from `kix.lib` (top-level), distinct from the per-package `kix` arg (`kixlib`).

| Symbol | Signature / Use |
|---|---|
| `kix.buildCluster { name, modules, specialArgs? }` | Top-level cluster orchestrator. Returns `{ activation, instances, namespaces, rawManifests, ... }` |
| `kix.mkEnv envName envConfig instanceSets` | Stamp instance sets into env-prefixed namespaces (§18) |
| `kix.mergeFragments { fragments, namespacePolicies? }` | Merge multiple cluster fragments. Instance collisions error; namespace configs deep-merge |
| `kix.helmChart { repo, name, version, hash, releaseName?, root?, includeCrds?, strip?, patchResources?, metaExtra? }` | Tier-1 inline Helm chart (§12) |
| `kix.mkImport { from?, out?, kind?, apiVersion?, roles?, crds? }` | Import marker: DI prefers managed > import; `crds` hands out CRD handles (§23) |
| `kix.flavors.{k3s,kind,kubeadm,eks,gke,gke-autopilot,aks,openshift,rke2,talos,scaleway,ovh}` | Platform flavor modules (§15) |
| `kix.modules.monitoring` | Reusable Prometheus/Grafana/Loki module (see `kix/lib/modules/monitoring.nix`) |
| `kix.rules.{security,reliability,governance,architecture}` | Built-in scorecard rule sets (§17) |
| `kix.pins <path>` | Read a committed pin file (JSON): `{ get, ref, keys, all, instances, file }`. Usually unnecessary: declare `pins = ./pins.json;` in `mkFlake` and take a `pins` argument (§29). Pass it to `kix.buildCluster { pins = ...; }` to apply its instance pins (§29.2a) |
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

`kix.helmChart` returns an inline package with `options.values` (deep-merged with package-level defaults at eval). Root: the only Service, else the only Deployment/StatefulSet/DaemonSet; otherwise evaluation fails and asks for `root = { kind; name; }`.

### 12.2 Tier 2 — package using `scope.helm.importChart`

For full DI control, custom root selection, CRD refs, capability declarations, intra-chart patching, and dep config injection:

```nix
# kix/packages/<pkg>/default.nix
{ scope, lib, kix }:
let
  release = "1.2.3";
  chart = scope.helm.fetchHelmChart {
    repo = "oci://registry-1.docker.io/bitnamicharts";
    name = "valkey";
    version = release;
    hash = "sha256-...";
  };
in
{
  meta.version = release;
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
| `autoRoot` | The only Service, else the only workload; throws when ambiguous |
| `mkParts { root, extraParts?, extraRequires?, out? }` | Build complete parts tree. `extraParts` may not reuse a chart part key or `root` |

`importChart` strips `helm.sh/*`, `meta.helm.sh/*`, `app.kubernetes.io/managed-by: Helm`, default strategy/updateStrategy, and test hooks. Foreign-namespace resources are respected when explicitly set.

### 12.3 Tier 3 — native package (no Helm)

Full DSL control. Use when the upstream chart is too large/complex/messy or you want to express the package idiomatically. Reference: `kix/packages/reloader/` (single Deployment, derived RBAC and leader election, flags guarded at evaluation, an `out` transformer).

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

When a required dependency has no instance, `eval/auto.nix` looks its argument name up in `availablePackages`. An optional dependency places no demand, even when its name is a registry role: it resolves to an active instance or import, or is null. An inactive optional instance or import answers no dependency, so a consumer never reads the `out` of an import whose marker is not emitted. A dependency wired with `deps.<arg>` places no demand on the shelf; when it is `ref.<ns>.<inst>` to an optional instance, that instance is activated. An entry answers its own name, its `meta.roles`, its `meta.defaultAliases` and its entry `aliases`. A shelf package is placed once per requesting namespace (or in `autoNamespace`, or in its entry's `namespace`). A package that runs once per cluster, one whose `meta.conflictsWith` names one of the keys it answers with a `cluster:` prefix or that claims a role, is refused when that would place it in more than one namespace: the error names each requester and asks for one declared instance (`instances.<ns>.<name>.package = packages.<name>;`), which every consumer then resolves to. When more than one entry answers a demanded name, the build stops and lists every claimant with the source of its claim; an unused contested name is fine, so `availablePackages = packages` keeps working. Select one implementation with an optional instance named after the dependency, which is checked before the shelf and created only on demand:

```nix
instances.data.clickhouse = {
  package = packages.clickhouse-cluster;
  optional = true;
};
```

or remove the other claimants from `availablePackages`. Optional instances answering one demanded name are chosen as `resolveArg` chooses: an instance with `meta.scope = "namespace"` in another namespace is skipped, an optional import yields to a managed optional instance, and one in the requester's namespace wins over others. A tie that remains is refused.

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
  aliases        = [ "cache" ];          # extra DI resolution keys
  config         = { ... };              # deferredModule — multiple modules merge
  deps           = { explicit = ref; };  # override DI resolution; collisions are errors
  partsOverlays  = [ (scope: self: base: ...) ];
  extraDeps      = [ ref.apps.contract ];  # kix.mkImport instances only; resources or refs
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
| `namespaces` | attrset | `{}` | Per-ns labels, annotations, ResourceQuota, NetworkPolicies, `podSecurity` level |
| `globalPartsOverlays` | list | `[]` | Parts overlays applied to ALL instances |
| `k8sVersion` | `nullOr str` (version) | `null` | Target K8s version (e.g. `"1.31"`, `"v1.31.2-gke.1209000"`) for `meta.k8s` checks |
| `cluster.domain` | `nullOr str` | `null` | Public base domain — `kix.expose` derives `<instance>.<domain>` |
| `cluster.provider` | `nullOr str` | flavor-set | Distribution name (informational) |
| `cluster.roles` | `attrsOf submodule` | flavor-set | Environment role bindings per registry role: `{ binding = "absent" | "shadowable" | "exclusive"; provider? }` (§15) |
| `cluster.capabilities.*` | various | flavor-set | 8 substrate axioms — see §15 |
| `cluster.maintenance` | submodule | `{}` | `{ enable, reason?, until? }` — maintenance window marker |
| `cluster.network` | submodule | – | `{ podCidr, serviceCidr, dnsUpstream }`. `podCidr` is the cilium package's IPAM pool in chart delivery with cluster-pool IPAM (the kind, k3s, and rke2 flavours set their defaults); `dnsUpstream` is read by the coredns package's forward plugin (empty means /etc/resolv.conf). An environment-installed Cilium is the `platform-cilium` import (§16.3) |
| `cluster.nodes` | attrset | `{}` | Static node inventory: `{ nodeName: { roles, cpu?, memory?, labels, taints? } }` |
| `scorecard` | submodule | on, full rule set, capped at warning | `{ enable, rules, maxSeverity, ruleDefaults, ruleOverrides, knownAnnotationDomains }` (§17) |
| `networkPolicy` | submodule | `{}` | `{ enable, defaultDeny, directions, platformIntents }` (§16) |

`clusterDomain` and `cluster.domain` serve different purposes:

- `clusterDomain` is the Kubernetes DNS suffix and defaults to `cluster.local`.
  `mkResource` uses it to build `out.fqdn` as
  `<name>.<namespace>.svc.<clusterDomain>`. Change it only if Kubernetes was
  installed with a different cluster domain.
- `cluster.domain` is the public base domain and defaults to `null`. When an
  instance does not set `ingress.host`, `kix.expose` uses this option to derive
  `<instanceName>.<cluster.domain>`. A package that calls `kix.expose` with
  `deriveHost = false`, such as Grafana, is routed only when the instance sets
  `ingress.host`. When `cluster.domain` is null, an instance without
  `ingress.host` gets no route.

Kix does not currently detect when these values are exchanged. Doing so
produces invalid addresses without an evaluation error.

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
| `kubeadm` | kubeadm | yes | no | no | yes | yes | yes | (none): user installs CNI | DNS |
| `eks` | eks | yes | yes | yes | yes | yes | yes | aws-vpc-cni | DNS (no storage: the EBS CSI driver is an add-on) |
| `gke` | gke | yes | yes | yes | yes | yes | yes | gke-native | DNS, storage (pd-standard) |
| `gke-autopilot` | gke-autopilot | yes | yes | yes | yes | **no** | **no** | gke-native | DNS, storage; restricted SCC |
| `aks` | aks | yes | yes | yes | yes | yes | yes | azure-cni | DNS, storage (default) |
| `openshift` | openshift | yes | yes | yes | yes | yes | **no** | ovn-kubernetes | DNS; restricted SCC |
| `rke2` | rke2 | yes | yes | no | yes | yes | yes | canal (default); `cluster.flavor.rke2.cni` selects it | DNS (CoreDNS), snapshot controller |
| `talos` | talos | yes | no | no | yes | yes | yes | flannel | DNS |
| `scaleway` | scaleway | yes | yes (paid) | yes | yes | yes | yes | cilium (Kapsule-managed) | DNS, storage (sbs-default) |
| `ovh` | ovh | yes | yes (paid) | yes | yes | yes | yes | canal | DNS, storage (csi-cinder-high-speed) |

**Capability flags** (full list, all on `cluster.capabilities`): `multiNode`, `availabilityZones` (list), `nodeAutoscaling`, `managedControlPlane`, `gpu`, `privilegedContainers`, `podSecurityEnforcement` (`"privileged" | "baseline" | "restricted" | null`), `daemonSets`. Flags are three-valued substrate axioms: `null` = unknown (relying workloads warn), `false` = hard error, `true` = pass.

A package that cannot run without a capability may refuse it in its own words before the lib's generic check fires: `falco` reads `clusterConfig.cluster.capabilities` in its build and throws, naming `daemonSets` and `privilegedContainers`, when either is false (GKE Autopilot, and `privilegedContainers` on OpenShift).

**Availability level, pod spread and PDBs** (`kix/lib/plugins/availability/module.nix`, v2_discussions/145; spread mechanism from archive/143). `cluster.availability.default = "none" | "pod" | "node" | "zone"` names the largest failure a workload must survive without downtime. It is derived from the capabilities when unset (`multiNode = false` gives `none`, two or more `availabilityZones` give `zone`, otherwise `node`; unknown capabilities derive `node` with one warning), capped by them (asking `zone` without zones is an eval error), and overridable per instance with `instances.<ns>.<inst>.availability`, which may exceed the cluster default up to the substrate. `cluster.availability.substrate` (read-only) is the derived maximum. Every package receives the resolved level as its `availability` function argument, and every replica-shaped option default maps it: `kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; }`, `kix.availability.atLeast "node" availability`. An explicit instance value still wins. A ceiling is the highest level a workload supports: `none` (one pod at a time: a single writer, no coordination between pods), `pod` (survives a pod crash or rolling update, not a node loss), `node` (survives a node loss, not a zone loss). `meta.availability.max` is for a limit of the program itself that holds for every workload and that no configuration lifts; a request above it is lowered with a warning. A limit that depends on configuration, on what the package wires, or on one workload goes on that builder call instead (`scope.mkDeployment { availability.max = "none"; ... }`), computed from `config` where needed: that workload is sealed at the lower level and warns once when it caps, the rest of the instance and the package's `availability` argument keep the requested level, and the one-replica warning judges each workload at its own level (a quorum store beside a single-replica controller keeps hard spread). A workload's effective ceiling is the lower of the two; the sealed resource carries it as `_availability.{ceiling,ceilingFrom}`. A Deployment or StatefulSet with more than one replica under an effective ceiling of `none` is an evaluation error naming the workload and the ceiling's source; it judges the final manifests, so chart workloads, instance options, and `partsOverlays` are covered. A `partsOverlays` entry that rebuilds the workload without `availability.max` drops a builder ceiling (the escape); a package ceiling has none. Ceilings are validated where written: an unknown level, an unknown key beside `max`, or `availability` on `mkDaemonSet` fails evaluation. `meta.availability` takes only `max`. Under a package ceiling the package never sees a higher level, so `kix.availability.atLeast` refuses a threshold above the ceiling, which is always false (`underCeiling` in `core/availability.nix`, handed to the package by `eval/instance.nix`). The error names the instance and points at a builder ceiling. Every Deployment or StatefulSet with `spec.replicas > 1` gets `topologySpreadConstraints` on `cluster.topology.failureDomainKeys` (read-only: `[ zoneKey hostKey ]` with more than one zone, `[ hostKey ]` otherwise, `[ ]` on `multiNode = false`; `cluster.topology.zoneKey` and `cluster.topology.hostKey` default to the well-known labels `topology.kubernetes.io/zone` and `kubernetes.io/hostname`, and a cluster whose nodes are labelled by hand sets its own) and a `PodDisruptionBudget` (`maxUnavailable = 1`). Strictness is a lowering of the level: `zone` is DoNotSchedule on the zone key, `node` is DoNotSchedule on hostname, `pod` and `none` are ScheduleAnyway everywhere; an explicit replica count above one at the level `none` still gets best-effort spread and a PDB (under the ceiling `none` it is an error). Author-written `topologySpreadConstraints` on a workload switch off both derivations for it; an author PDB over the same pods is kept. A workload that switches the derivations off and then has no PDB selecting its pods warns, naming the workload; the plugin says it because the plugin is where the skip is decided (`reliability.hasPDB` stays retired for that reason, not because rules cannot see derived resources: since 2026-09-20 manifest and package rules score the shipped set, derived PodDisruptionBudgets and materialised network policies included). On `multiNode = false`, a hand-written `requiredDuringScheduling` anti-affinity or `DoNotSchedule` spread on a multi-replica workload is an eval error; on `multiNode = null` it warns. A root-reachable workload with one replica under `node` or above warns (the package did not map the level). Packages whose pods an operator renders put the same rule in the CR's pod spec with `kix.availability.spreadConstraints { level = availability; selector = <operand labels>; topology = clusterConfig.cluster.topology; }`; the victoria-metrics packages still read `clusterConfig.cluster.topology.failureDomainKeys` for their CR's anti-affinity. With `maxSkew = 1` a hard constraint means even distribution, not one pod per domain: five replicas across three zones is 2/2/1.

The old role-backed bools (`cni`, `networkPolicyAPI`, `loadBalancer`, `persistentStorage`, `rwxStorage`, `volumeSnapshots`, `ingressController`) are gone (v2_discussions/127): role providers derive from `meta.roles`, the environment's claim on a role is a `cluster.roles.<name>.binding`, and no provider publishes rwx or snapshot facts yet (housekeeping/2026-10-01-rwx-claims-unchecked-against-provider.md). The CNI/LB/storage columns in the table above describe role bindings and platform imports, not capability flags.

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

On RKE2, select the CNI with `cluster.flavor.rke2.cni` (the `cni` list of RKE2's server config) rather than overriding the binding:

```nix
modules = [
  kix.flavors.rke2
  {
    # Must match the `cni` list of RKE2's server config.
    cluster.flavor.rke2.cni = [ "cilium" ];
    instances.kube-system.cilium.package = packages.cilium;
  }
];
```

The flavour declares the platform import `kube-system/platform-cilium` with `out.helmChartConfig = { name = "rke2-cilium"; namespace = "kube-system"; }`, and the instance, which takes it as its `platform-cilium` dependency, writes HelmChartConfig kube-system/rke2-cilium instead of installing a second Cilium; RKE2's chart uses `kubernetes` IPAM, so a cluster that wants cluster-pool sets `values.ipam.mode` and the pool together.

**Platform imports.** Flavors declare instances for platform-managed services:
- `platform-dns` (alias `dns`): all flavors, `optional = true` on every flavor except kind. Workloads order after DNS only when the `dns` provider is active; an optional platform-dns import that nothing demands adds no dependency and no "no DNS instance" warning.
- `platform-cilium` (role `cni`): RKE2 when `cluster.flavor.rke2.cni` names cilium. Its `out.helmChartConfig` names the HelmChartConfig a `cilium` instance writes.
- `platform-storage` (role `storageClasses`): kind, k3s, GKE, GKE Autopilot, AKS, Scaleway, and OVH, the flavors whose provider creates the StorageClass on every new cluster. The import names the class (`kind = "StorageClass"`, `apiVersion = "storage.k8s.io/v1"`, and `out.name`), so the deploy waits for it. EKS, kubeadm, RKE2, Talos, and OpenShift bind `storageClasses` `absent`.
- `platform-snapshot-controller` (role `snapshotController`, with `crds` for the three snapshot.storage.k8s.io kinds): RKE2.

The storage, snapshot, and Cilium imports are not optional. Packages take `storageClasses`, `snapshotController`, and `platform-cilium` as optional dependencies, and an optional dependency neither activates an optional import nor resolves to an inactive one, so an optional import would leave those dependencies null, emit no marker for the StorageClass check or the CRD markers its handles need, and make a `cilium` instance under a shadowable `cni` refuse to evaluate. An optional import becomes active, and its marker is emitted, when a required dependency or a `deps` ref of an active instance demands it. If a cluster installs its own `coredns` or `storage-classes` instance, the explicit instance wins: it claims the role, and DI prefers a managed provider over an import. Under network policy, coredns runs in `kube-system`. A `storage-classes` class annotated `storageclass.kubernetes.io/is-default-class` is refused where the flavor imports a default class.

**Resource metrics API.** The `metricsApi` role stands for metrics.k8s.io and has no out contract. rke2, k3s, gke, gke-autopilot, and aks bind it `exclusive` (their environment runs metrics-server; no import); kind, kubeadm, talos, and eks bind it `absent`; openshift, ovh, and scaleway leave it `null`. `scope.mkResource` checks every HorizontalPodAutoscaler that reads the API (autoscaling/v1, autoscaling/v2 with no `metrics`, or a `Resource` or `ContainerResource` metric) against the role, the way `checkLoadBalancer` checks LoadBalancer Services: `absent` with no provider instance is an evaluation error, `null` a warning. A package that reads the API from a config file calls `scope.requireMetricsApi "<what reads it>"` (the descheduler does, for a `KubernetesMetrics` provider). The `metrics-server` package claims the role: `instances.metrics-server.metrics-server.package = packages.metrics-server;`, plus `config.extraArgs = [ "--kubelet-insecure-tls" ];` where kubelets serve self-signed certificates (kind, Talos without kubelet certificate rotation).

**Registry mirror and containerd.** The `registryMirror` role stands for a node-local OCI registry mirror that containerd tries first, and has no out contract. kind binds it `absent` and the other flavours leave it `null`. k3s and rke2 embed Spegel but run it only with `embedded-registry: true`; a cluster that turns it on sets the binding to `exclusive`, which refuses a `spegel` instance. The `spegel` package claims it. Kix cannot read or change the nodes' containerd configuration, so `cluster.containerd` declares it: `socket`, `registryConfigPath` (the CRI `config_path`), and `contentPath` default to containerd's paths, Talos and GKE move `registryConfigPath`, k3s and rke2 set all three to their paths under `/var/lib/rancher` and `/run/k3s`, and `discardUnpackedLayers` is `true` on kind, Talos, EKS, and GKE, `false` on AKS, Scaleway, k3s, and rke2, and `null` (unknown) elsewhere. Spegel serves layers that containerd keeps, and a pod becomes ready only once it has a peer, so the package refuses `discardUnpackedLayers = true` and `cluster.capabilities.multiNode = false`, and warns on `null`. A kind cluster for Spegel has a worker node and a `containerdConfigPatches` entry setting `discard_unpacked_layers = false` in `[plugins."io.containerd.grpc.v1.cri".containerd]`, the table kind's node image sets it in (containerd 2 copies that table over the newer `io.containerd.cri.v1.images` one), and declares both facts (`clusters/test-spegel.nix`).

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
| LoadBalancer Service or hostNetwork pod | External ingress allowance, except for a LoadBalancer Service whose `loadBalancerClass` comes from `kix.providedLoadBalancerClass` (see §16.7) |
| A Prometheus CR and the ServiceMonitors, PodMonitors, and Alertmanagers it selects | The server pods' egress to every target, plus an ingress CNP at each target admitting them (see §16.8) |

### 16.2 What's NOT discovered

- Cross-package edges hidden inside Helm templates that don't appear in JSON string context (warned via "Helm opacity" message).
- hostNetwork pods bypass CNI policy (warning emitted).
- Pods an operator creates at runtime (proxies, nameservers, data-path pods). The package writes their policies with `kix.operandPolicy`; see §16.6.
- A scraper's connections to its targets, which no workload names. The netpol plugin derives them for Prometheus from the monitors it selects; see §16.8.
- Addresses a package's passthrough config dials that no dependency supplies (an otel-collector exporter written in `settings`, a Vector sink endpoint the instance overrides where unlocked). An address from `dep.out` written into a ConfigMap the pod mounts does carry the edge; one typed into `settings` does not, and under default deny the instance needs its own policy for it.

A host-network pod gets no derived edge. Its traffic reaches other pods as from the host or a remote node, so the rules derived from the addresses it dials admit nothing. A package whose host-network pods talk to its own pods declares the ports once as an intent (§16.5), as mayastor's `hostNetworkPeers` does: `meta.network.intents.hostNetworkPeers = { ingress = [ { from = "all-pods"; ports = [ { port = 2379; protocol = "TCP"; } ]; } ]; egress = [ ... ]; };`. `all-pods` is Cilium's `cluster` entity, which includes `host` and `remote-node`.

### 16.3 Cluster-side wiring

The enforcer is auto-discovered: any package with `meta.roles ∋ "network-policy-enforcer"` becomes the cluster's enforcer. `kix/packages/cilium` is the one shipped enforcer. It exposes `out.crds.CiliumNetworkPolicy` and `out.crds.CiliumClusterwideNetworkPolicy`, and `out.netpol.mkPolicy` builds every generated CNP through the first, so the CNP → CRD reference → enforcer edge is wired transitively. The instance installs the chart (cni binding `absent`), or, with a shadowable `cni` binding, takes the environment's Cilium as its optional `platform-cilium` dependency: a `kix.mkImport { roles = [ "cni" ]; out.helmChartConfig = ...; }`. When the import's `out.helmChartConfig` is `{ name; namespace; }` the instance writes its values into that HelmChartConfig, which the environment merges into its bundled chart; the rke2 flavour declares `kube-system/platform-cilium` naming `kube-system/rke2-cilium` when `cluster.flavor.rke2.cni = [ "cilium" ]`. When it is `null` the instance only uses the environment's Cilium. A shadowable binding without the import, the import on another binding, and an import without `out.helmChartConfig` are evaluation errors. Cilium as an enforcer beside another CNI is not supported: the package always claims `cni`.

### 16.4 Default-deny

```nix
networkPolicy = {
  enable = true;
  defaultDeny = true;     # a deny-all policy in every Kix namespace
  directions = "both";    # "both", "ingress", or "egress"
};
```

`directions` is the one setting for which directions Kix enforces: default deny, the derived workload, instance, and scrape policies, and `kix.operandPolicy` (through `scope.networkPolicyEnforced`) all read it through the read-only `networkPolicy.enforced` (`{ ingress; egress; }`), and none of them emits a section for a direction outside it. `namespaces.<ns>.networkPolicies.<name>` adds a Kubernetes NetworkPolicy `<ns>-<name>` with that spec.

**Pod Security Standards.** A package whose pods need a level declares it: `meta.podSecurity = "privileged"` (kubevirt's virt-handler). The namespace gets `pod-security.kubernetes.io/enforce` at the most permissive level any of its instances needs, and nothing when none declares one. `namespaces.<ns>.podSecurity` sets the level by hand; setting it stricter than an instance in that namespace needs is an eval error naming the instance, rather than a pod the apiserver refuses with a message naming the pod.

**Namespace quotas.** Kubernetes enforces a ResourceQuota when objects are created at runtime. Kix checks quotas at build time and fails the build when the minimum resources required by a namespace's workloads exceed a quota. For each namespace, it sums the minimum pods each workload runs: 1 for a Pod; `spec.replicas` for a Deployment, ReplicaSet, StatefulSet, or ReplicationController (or the `minReplicas`, defaulting to 1, of a targeting HorizontalPodAutoscaler); `spec.parallelism` for a Job (capped by `spec.completions`, or 0 while `spec.suspend` is true); and, for a custom resource, the usage its CRD's `usesAtLeast` returns (§22). Each pod counts the sum of its regular containers' requests and limits, with an omitted request defaulting to the limit; init containers are excluded so the computed minimum never exceeds what Kubernetes charges. Kix compares this total against `namespaces.<ns>.resourceQuota`, a consumer namespace's quota from its platform interface (§23.1), and any unscoped ResourceQuota rendered by an instance in the namespace (skipping quotas with `scopes` or `scopeSelector`). Every key a quota sets is checked, with `cpu`, `memory`, and `ephemeral-storage` mapped to `requests.*`; a key nothing reports counts as 0, and built-in workloads report only pods, requests, and limits. When a quota is exceeded, the error message names the namespace, each exceeded key with the minimum usage and quota, the counted workloads, and any uncounted workloads in the namespace (DaemonSets, CronJobs, and custom resources whose CRD sets `factBehavior.endpoint = "terminate"` without `usesAtLeast`).

The build checks every pod template (Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet, ReplicationController, Job, CronJob, init containers included) in a namespace with a level against the Pod Security Standards, and fails on each workload that breaks it, naming the instance, the workload, and each container and field with the value to set:

```
- kix: instance acme-app/echo: Deployment echo breaks Pod Security level "restricted", which namespace acme-app enforces (set by prod's interface). Kubernetes would refuse its pods. Change:
    container 'nginx': securityContext.allowPrivilegeEscalation is unset; set it to false
    container 'nginx': securityContext.seccompProfile.type is unset here and on the pod; set RuntimeDefault (or Localhost) on the container or in the pod's securityContext
    container 'nginx': securityContext.capabilities.drop does not include ALL; set it to [ "ALL" ]
```

`baseline` covers host namespaces, `privileged`, Windows HostProcess, hostPath volumes, host ports, capabilities added beyond the baseline set, an `Unconfined` seccomp profile, and `procMount`. `restricted` adds volume types, `allowPrivilegeEscalation: false`, `runAsNonRoot` (pod or container), `runAsUser` 0, a `RuntimeDefault` or `Localhost` seccomp profile (pod or container), and `capabilities.drop` including `ALL` with nothing added but `NET_BIND_SERVICE`. AppArmor, SELinux options, sysctls, and the restricted exemptions for a Windows pod are not checked; admission still refuses those at deploy (`eval/pod-security.nix`).

Each default-deny CNP carries one empty rule per denied direction (`ingress: [ { } ]`), which is what puts the namespace's endpoints into default deny with nothing allowed. An empty list is not the same: cilium 1.19 rejects it as invalid and enforces nothing.

### 16.5 Package intents

Connectivity the graph cannot derive is declared on the package, once, and applies to every workload in it:

```nix
meta.network.intents.<name> = {
  ingress = [ { from = "world" | "all-pods" | "apiserver"; ports = [ { port = 8080; protocol = "TCP"; } ]; } ];  # ports optional
  egress  = [ { to = "world" | "all-pods" | "apiserver" | "dns"; ports = [ ... ]; entities = [ ... ]; } ];  # ports optional; entities with "world" only
};
```

An intent applies to every workload the package renders, not only the one that needs it (housekeeping/2026-10-01-netpol-intents-apply-to-every-workload.md).

`all-pods` is cilium's `cluster` entity. An ingress controller needs `egress = [ { to = "all-pods"; } ]` because its backends are whatever the cluster's Ingress objects name. The other half of that edge is written for you: `kix.expose` emits the ingress rule on the backend, so a fronted backend declares no intent of its own. Ports in rules and in Services are numbers: cilium resolves a named port on an ingress rule but drops egress on one.

`from = "apiserver"` admits the Kubernetes API server (Cilium entities `kube-apiserver`, `remote-node`, `host`, the same as the `apiserver` egress target), for an admission webhook or an aggregated API. cert-manager's webhook declares `webhook.ingress = [ { from = "apiserver"; } ];`, and kubevirt admits the API server to virt-operator's webhook on 8444 the same way, with a port.

A rule to or from `world` may name `entities`, Cilium entity names (`world`, `host`, `remote-node`, ...) that the Cilium enforcer's external rule reads; the default is `[ "world" ]`. coredns uses it to reach resolvers on its own or a peer node.

Pods an operator launches outside Kix get no derived policy. cert-manager's ACME HTTP-01 solver pods are the common case. `kix.expose` admits the ingress controller to them for the Ingresses it builds with TLS from a `cluster-issuer` that has an `http01` solver (its `out.http01SolverSelector`). For any other Certificate, give them a cluster-wide platform intent selecting `acme.cert-manager.io/http01-solver=true` (cert-manager's `out.operandSelectors.acmesolver`) with `ingress = [ { from = "all-pods"; ports = [ { port = 8089; protocol = "TCP"; } ]; } ]`. It relies on the ingress controller's egress to all pods. See `declare-platform-intents-for-non-kix-managed-pods.mdx`.

### 16.6 Operand policies

Derived policy covers the workloads a package renders. Pods an operator creates from a custom resource (ClickHouse replicas, Keeper, a StackGres cluster) are invisible to it, so the package that writes the CR writes their policy with `kix.operandPolicy { scope; name; spec; }`. `spec` is in the enforcer's format and carries the pod selector (`endpointSelector` for Cilium); the operator's `out.operandSelectors` give the labels. Under `networkPolicy.directions = "ingress"` the helper drops `egress` and `egressDeny` from the spec, and under `"egress"` it drops `ingress` and `ingressDeny`: default deny leaves that direction open, and a section for it would isolate the pods to what the section lists. The helper returns null when network policy is off, no enforcer exists, or no section is left, so add only non-null results to `root.requires`. For the other end of an edge in a dependency's namespace, pass `scope = scope.forService dep`. tailscale's `proxyPolicies` are another example: the operator creates proxies, egress proxies, ProxyGroups, the DNSConfig nameserver, and Recorders in the package's own namespace, and the package selects them by the labels the operator puts on them, with rules from the enforcer's `netpol.translateIntentRules`.

Pods an operator creates in a consumer's namespace are the consumer's to allow; the operator package publishes their labels as `out.operandSelectors` and, where the rule needs the operator's namespace, a builder (cdi `out.mkImporterPolicy`).

### 16.7 Provider-opened backends and provider load-balancer classes

When a provider's pods call a consumer's backend (tailscale proxies, an ingress controller), the policy belongs on the backend, in the consumer's namespace. `kix.expose` writes it for an ingress controller. A provider that the consumer wires directly exposes a builder for it: `tailscale.out.mkBackendPolicy scope { service; port ? null; name ? service.name; }` returns a policy `<name>-from-tailscale` that admits `out.podSelector` from `out.podNamespace` on the pod port behind `port` (a Service port number or name; every port when null), with `extraDeps = [ service ]` so the policy is reachable. It refuses a Service without a selector, whose policy would select every pod in the namespace, and returns null when the cluster does not enforce ingress. `tailscale.out.mkIngress` returns `{ ingress; policy; }` so the policy cannot be forgotten; its policy, `<ingress name>-ingress-from-tailscale`, covers the default backend and every path to the same Service.

A load balancer provider publishes the class it serves as `kix.providedLoadBalancerClass { class; by; }`, where `by` is the resource that serves it (tailscale: `out.loadBalancerClass`, `by = self.deployment`). The value is the class string with a marker and the context of `by`, so a Service that names it depends on the provider. A LoadBalancer Service whose `spec.loadBalancerClass` carries the marker, and equals the class the marker records, is served by that provider: `checkLoadBalancer` skips the cluster's `loadBalancer` role for it, and derived policy gives its pods no ingress from outside the cluster (`core/markers.nix` `isProvidedLoadBalancerClass`, read by `scope/validators.nix` and `plugins/netpol/derive.nix`). The provider opens the backend with its own builder. Any other class, a raw string, one wrapped in `kix.untrackedRef`, one interpolated from another resource's `out`, or a string derived from the provider's value (`"${tailscale.out.loadBalancerClass}-internal"`, which keeps the marker), gets the role check and the external-ingress allowance.

### 16.8 Scrape policies

The netpol cluster processor derives the path from each scraper to what it scrapes (`kix/lib/plugins/netpol/scrape.nix`). A scraper is a Prometheus CR or a VictoriaMetrics VMAgent CR; the VMAgent rules follow the Prometheus ones below. It reads every built resource after the instances are evaluated, because the edge is a label join no single instance sees: a Prometheus CR selects monitors with `serviceMonitorSelector`, `podMonitorSelector`, and their namespace selectors (a null monitor selector selects nothing, `{}` everything; a null namespace selector means the Prometheus's own namespace), a ServiceMonitor selects Services by their labels, and a PodMonitor selects pods. `spec.alerting.alertmanagers` entries are looked up by namespace and name.

For each Prometheus CR it emits `<name>-scrape-egress` in the server's namespace, selecting the server pods, with one rule per target, and `<ns>-<name>-scrape-<target>-<hash>` in each target's namespace, admitting the server pods on the target's pod ports. The hash covers the server's namespace and name and the target, so names stay distinct where the readable parts join ambiguously (Prometheus `c` in `a-b` and `b-c` in `a`) and for same-named PodMonitors in different namespaces. The server pods are named by the Prometheus CRD's `factBehavior.podSelector`, which the prometheus-operator package declares; the prometheus package opens DNS and the API server for them with `kix.operandPolicy`. Targets resolve against what Kix built:

- A Service port's `targetPort` gives the pod port; a named port is resolved through the container ports of the Kix workloads behind the Service selector, to every number they declare it with (two Deployments behind one Service may give `metrics` two numbers, and the rules carry both).
- A named port that no Kix workload declares (pods an operator creates) stays a name. The target's ingress rule keeps it, because the receiving pod resolves it. Cilium drops egress on a named port, and a rule without ports would admit every port, so the egress rule carries only the target's numeric ports, and a target with none gets no egress rule. Give such a monitor endpoint the number: `portNumber` on a PodMonitor endpoint (stackgres-cluster and arc do), or a numeric `targetPort`.
- A target whose Kix workloads run on the host network (node-exporter) gets an egress rule to the `host` and `remote-node` entities on its port (`netpol.mkHostNetworkEgressRule`) and no ingress policy. A host-network target whose port is a name no Kix container declares gets no egress rule.
- A target Kix did not build gets an egress rule for the selector its Service names. That covers pod-network platform pods such as kube-dns. Kix derives nothing for the kubelet, the API server, or control-plane static pods on the host network; the server reaches them only through its API server rule, which admits every port on `host` and `remote-node` (housekeeping/2026-10-01-apiserver-egress-rule-allows-every-host-port.md).
- `namespaceSelector.any` covers every Kix namespace, including one that holds only custom resources whose operator creates the pods.
- A PodMonitor whose selector uses `matchExpressions` gets no policy; Kix builds policy selectors from `matchLabels`.
- A Prometheus CR whose CRD declares no `factBehavior.podSelector` gets no policy; the message names the `cluster.factBehavior` override.

The last three cases, and a target port that is a name no Kix container declares, are scrape paths Kix cannot derive. With `networkPolicy.defaultDeny` on they fail evaluation, one line per path, because the scrape would be dropped (or, for a host-network target, would depend on the server's API server rule). Without default deny they are warnings.

`networkPolicy.directions` limits the output: under `"egress"` no target ingress is emitted, and under `"ingress"` no server egress is emitted, and `kix.operandPolicy` drops the egress section of the prometheus package's server policy, so the server pods keep open egress. With `networkPolicy.defaultDeny = false` a target ingress policy would be the first ingress policy on its pods and close them to every other client, so it is emitted only when another Kix policy (derived, operand, or platform intent) already isolates every pod behind the target for ingress. A Kubernetes NetworkPolicy, including `namespaces.<ns>.networkPolicies`, counts when its `policyTypes` include `Ingress` or are absent. The check matches each policy's selector against the labels of the pods Kix built behind the target, which can carry more than the Service selector. Pods Kix did not build are known by the target's selector alone, so a policy isolates all of them only when the target's selector implies its selector; a `NotIn` or `DoesNotExist` on a key outside the target's selector may isolate only some. When the policy isolates only some of the pods, or may, the target gets no scrape ingress and a warning.

A VMAgent selects VMServiceScrapes with `serviceScrapeSelector` and `serviceScrapeNamespaceSelector`, and VMPodScrapes with the `podScrape` pair, as the VictoriaMetrics operator does: with both of a pair unset it selects everything when `selectAllByDefault` is true and nothing otherwise, an object selector alone reads only the VMAgent's namespace, and a namespace selector reads the namespaces it matches (`{}` all). It also selects ServiceMonitors and PodMonitors through those pairs while the operator converts them, which the operator's `VM_ENABLEDPROMETHEUSCONVERTER_SERVICESCRAPE` and `_PODMONITOR` variables decide; a build in which no workload sets them counts as converting, the operator's default. The scrape objects the operator creates for its own operands come from `factBehavior.selfScrapes` on their CRDs (victoria-metrics-operator declares them for VMCluster, VMAgent, VMAlert, and VMAlertmanager), so vmagent reaches vmstorage, vmselect, vminsert, vmalert, and Alertmanager on their metrics and config-reloader ports. Its policies are `vmagent-<name>-scrape-egress` and `<ns>-vmagent-<name>-scrape-<target>-<hash>`.

Scrape sources whose targets are free-form addresses get no policy and a warning, with or without default deny, because the path may be opened outside the join (a `networkPolicy.platformIntents` entry, for one): a Prometheus that sets `additionalScrapeConfigs` or `additionalAlertManagerConfigs` or selects a Probe or ScrapeConfig, and a VMAgent that sets `inlineScrapeConfig` or `additionalScrapeConfigs` or selects a VMProbe, VMStaticScrape, VMNodeScrape, or VMScrapeConfig (or a converted Probe or ScrapeConfig).

Not covered: monitors outside Kix, and remote write to a URL that is not a dependency's output.

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

The result is then capped at `scorecard.maxSeverity`.

Configure via `scorecard.{enable, rules, maxSeverity, ruleDefaults, ruleOverrides}`. The scorecard is on by default with the full built-in rule set (`kix.rules`) and `maxSeverity = "warning"`: every finding is printed, none fails the build. Raise the cap to `"error"` for a build that goes red on an error-severity rule; this repository's own flakes do it for every cluster through `mkFlake { clusterModules = [ { scorecard.maxSeverity = "error"; } ]; }`. Setting `rules` replaces the set, so a cluster that wants the built-in rules plus one change to one rule uses `ruleOverrides` (`ruleOverrides.byNamespace."*"."security.nonRoot".severity = "warning"`) rather than copying a category. A package reads the severity a rule resolves to with `kix.scorecard.effectiveSeverity { clusterConfig; rule = "security.nonRoot"; namespaceName; owner ? null; }`: overrides and the cap applied as the scorecard applies them, null when the scorecard is off, the rule is not in `rules`, or an override disables it. vaultwarden and immich use it so that their opt-in root `initChownData` container fails with a message naming the exact `ruleOverrides.byNamespace` entry the migration deploy needs.

### 17.2 Built-in rules

**Security** (`kix.rules.security`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `nonRoot` | manifest | error | All containers `runAsNonRoot` |
| `noPrivileged` | manifest | error | No privileged containers |
| `readOnlyRootfs` | manifest | warning | Read-only root recommended |
| `noHostNetwork` | manifest | error | No `hostNetwork`/`hostPID`/`hostIPC` |
| `noClusterAdmin` | manifest | error | No ClusterRoleBinding to `cluster-admin`, and no ClusterRole rule whose `apiGroups`, `resources`, and `verbs` all contain `"*"`. Skipped for a package holding the `cluster-admin` grant. A namespaced RoleBinding and a one-group wildcard are not checked |
| `noLatestTag` | manifest | warning | Images explicitly tagged (not `:latest` or untagged) |
| `noUnresolvedPlaceholder` | manifest | warning | No `REPLACE_ME`, `CHANGEME`, `PLACEHOLDER`, `TODO`, `FIXME`, `XXX` or unexpanded `${...}` in an image reference (§29) |
| `hasNetworkPolicy` | namespace | warning | Workload namespaces have at least one network policy (NetworkPolicy or a kind from the enforcer's `out.netpol.policyKinds`) |

**Reliability** (`kix.rules.reliability`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `boundedResources` | manifest | warning | All containers declare CPU+memory requests AND limits |
| `hasResourceLimits` | manifest | warning | All containers have limits |
| `hasResourceRequests` | manifest | warning | All containers have requests |
| `hasProbes` | manifest | warning | Workload containers have liveness + readiness probes |
| `gracefulShutdown` | manifest | info | `terminationGracePeriodSeconds` set |

**Governance** (`kix.rules.governance`):

| Rule | Level | Severity | Check |
|---|---|---|---|
| `distinctWorkloadSelectors` | package | error | No workload's `spec.selector.matchLabels` is also a subset of another workload's pod template labels. Two pod sets answering one selector cannot be told apart by readiness, Services, PDBs or network policy |
| `untrackedReferences` | cluster | info | Audit: every name declared external with `kix.untrackedRef` that does not name its creator (`kind` with `by`, or `by = "self"` held by one resource only), listed so the bare claims are reviewable in one place |
| `hasOwner` | package | warning | `meta.owner` set |
| `nonRoot` | manifest | error | Every container resolves to a non-root uid. Reads the container's `securityContext` first, then the pod's, the way Kubernetes does; a non-zero `runAsUser` counts. Skipped for a package holding the `run-as-root` grant |
| `hasDescription` | package | info | `meta.description` set |
| `labelStandards` | manifest | info | Standard labels (`app.kubernetes.io/name`, `managed-by`) |

**Architecture** (`kix.rules.architecture`):

DI-hygiene rules (v2_discussions/128 replaced the old fingerprint-based capabilityOwnership rule):

- `annotationDomainOwnership` — a package's `metadata.annotations` keys under an operator-declared domain (`meta.annotationDomains`, e.g. reflector's `reflector.v1.k8s.emberstack.com`) require a dependency on the declarer, direct or through another dependency (a TLS Ingress carries `cert-manager.io/cluster-issuer`; the consumer depends on the cluster-issuer, which depends on cert-manager, which declares the domain); a domain nobody declares warns as a dead annotation. Reserved suffixes (`kubernetes.io`, `k8s.io`, `kix.run`, `helm.sh`, `kubebuilder.io`) and the cluster's `scorecard.knownAnnotationDomains` are exempt.
- `consistentPortNames` — warning: one port name must mean one number across an instance's workloads. Kubernetes scopes a port name to its pod, so two workloads may legally disagree; Kix's consumers are wider than a pod, and anything that resolves a name without naming the workload it belongs to picks one of the numbers by accident. A warning rather than an error because a vendored Helm chart can carry the clash (cilium's `health` is 9879 on the agent and 9234 on the operator) and the package cannot rename it.
- `unsafeGrants`: info-level audit listing every `meta.unsafe` grant. Five exist: `raw-pvc`, whose absence is enforced as an eval *error* in `scope/validators.nix` rather than by a scorecard rule, and `host-network`, `privileged`, `run-as-root`, and `cluster-admin`, which switch off `security.noHostNetwork`, `security.noPrivileged`, `security.nonRoot`, and `security.noClusterAdmin` for the declaring package. A CNI agent, a CSI node plugin, or a node-level exporter holds the first three of those, an operator whose own namespace runs privileged pods it creates holds `privileged` (tailscale), and a cluster-wide backup tool (velero) holds `cluster-admin`. An application package that trips those rules has a bug, not a grant.

Kix validates `level` and `severity` when loading a rule
(`scorecard.nix#checkLevel`, `#checkSeverity`). This prevents an unknown level
from creating a rule that never runs, and an unknown severity from being
treated as a warning. Severity overrides under `ruleOverrides.byRule`,
`.byOwner`, and `.byNamespace` receive the same validation.

An error-severity finding becomes a failed assertion. Evaluation stops at the
first error, so the cluster does not build and only that finding is reported.
Because no scorecard report is produced, `kix check --sarif` emits one
error-level result for the evaluation failure. It attributes the result to the
rule when the error message identifies one.
- `selectorCoherence` / `fqdnWithoutContext`: selectors and `*.svc` FQDNs must carry store-path context from the owning workload/service.
- `clusterDomainLiteral` (cluster-level, **error**): on a cluster whose `clusterDomain` is not `cluster.local`, no rendered string (outside CRDs) may name `cluster.local`. Build addresses from `out.fqdn`/`out.url` or `clusterConfig.clusterDomain`.
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

Twenty-three checks over the finished manifest list run inside every cluster evaluation (`kix/lib/eval/validate.nix`, called from `buildCluster`). They ask whether the thing a name points at exists and whether labels really match a pod in the build. The scorecard rules ask a different question, whether a value came from the right place, and run before string context is stripped. Check 21 also follows `kix.run/depends-on`: buildCluster passes each manifest's identity hash and the instance that built it, so messages name both instances. Both are needed: a hand-typed selector with a typo gets the same scorecard warning as a correct one, and only these checks tell them apart.

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
| 17 | Workload `priorityClassName` names a PriorityClass in the build | `system-cluster-critical`, `system-node-critical` |
| 18 | A resource of a namespaced kind has `metadata.namespace` (the apiserver would put it in the requester's namespace, where Kix's comparisons with the build never find it) | kinds whose scope Kix does not know: built-in namespaced kinds, custom kinds whose CRD with `spec.scope: Namespaced` is in the build, and kinds a CRD ref marker declares `Namespaced` are checked. `kix deploy` refuses the rest against the cluster's discovery before applying anything |
| 19 | A workload's `volumes[].persistentVolumeClaim.claimName` names a PersistentVolumeClaim in its namespace | |
| 20 | A PVC's `storageClassName`, a StatefulSet `volumeClaimTemplates[].spec.storageClassName`, or a generic ephemeral volume's `ephemeral.volumeClaimTemplate.spec.storageClassName` names a StorageClass in the build or imported, or a PersistentVolume in the build carries it | unset and `""`; classes inside operator CRs (SGCluster, VMCluster, CDI DataVolume) |
| 21 | A resource outside the built-in API groups depends (transitively, through `kix.run/depends-on`) on a CRD, a CRD ref marker or an APIService of its group and kind that serves its version | built-in groups (`""`, apps, batch, policy, autoscaling, the `*.k8s.io` groups Kubernetes serves, kix.run) |
| 22 | A key a container reads by name (`secretKeyRef`/`configMapKeyRef`, volume or projected `items[].key`, first `subPath` segment into a Secret or ConfigMap volume without items) exists. Keys: `kix.run/secret-keys` (mkSecret), `kix.run/import-secret-keys` (mkSecretRef; with no keys listed, a named read fails), ConfigMap `data`+`binaryData` | `optional: true`; `kix.untrackedRef` names; names with no object in the build; Secrets without `kix.run/secret-keys` (chart Secrets); objects ceding `data`/`binaryData`/`stringData`; whole use (`envFrom`, volume without items) |
| 23 | At most one PriorityClass with `globalDefault: true`, one StorageClass annotated `storageclass.kubernetes.io/is-default-class: "true"` (or the beta `storageclass.beta.kubernetes.io/is-default-class`), one IngressClass annotated `ingressclass.kubernetes.io/is-default-class: "true"` | |

**Scope of a lookup.** A reference is looked up in the referrer's namespace only, unless the referenced kind is a built-in cluster-scoped kind (a RoleBinding to a ClusterRole). An import marker of a built-in cluster-scoped kind (a flavor's StorageClass import in kube-system) counts from every namespace. Nothing else falls back to the cluster-scoped bucket. A `kix.untrackedRef` name resolves whatever its kind. Pod selectors follow the same rule: a Service, NetworkPolicy or PodDisruptionBudget matches pod templates in its own namespace only.

**Failure shape.** The eval fails like any other assertion:

```
error: Cluster 'ludo-kind' has 1 failed assertion(s):
  - [validate] Service data/postgres-metrics selector {"app":"pg"} matches no workload pod template
```

`nix build`, `kix build`, `kix deploy`, and `kix check` all stop there.

**Chart custom resources.** A chart's custom resources depend on the chart's own CRDs (`helm-dag` `instance-of` edge). A chart resource of another package's kind (a ServiceMonitor behind a values toggle) fails check 21, because a chart resource cannot take a dependency: turn the toggle off and build the resource with the owner's builder in a package of your own.

**Services for operator-created pods.** Check 4 cannot see pods an operator creates at runtime. Two ways through, in order of preference:

1. `scope.mkServiceRef` for a Service the operator itself creates (`vmselect-<name>`). It carries the selector, ports and the Service's labels, renders as a marker, and no check or rule fires on it. The victoria-metrics-cluster and stackgres-cluster packages do this. Two consequences to know: consumers now wait until the operator's Service has ready endpoints (the per-node readiness timeout, 180s by default, applies to a slow start), and the declared selector should be as wide as the operator's own (a ref that adds an instance label to a Service that selects every instance in the namespace describes fewer pods than the Service reaches).
2. When Kix renders the Service itself (the operator creates none), the Service declares the CR whose pods it selects: `metadata.annotations."kix.run/operand-of" = "<group>/<Kind>/<name>"`. Check 4 accepts the Service when that CR is in the build in the same namespace, and reports the declaration when it is not, and the `selectorCoherence` rule does not flag its selector. An operator that takes a governing Service by name is the cleanest case: the prometheus and alertmanager packages render a headless Service per instance and name it in `spec.serviceName`, so the operator creates no `prometheus-operated` or `alertmanager-operated`, and two instances in one namespace each get a Service over their own pods. A PodDisruptionBudget over operator-created pods declares the same annotation for check 14 (the prometheus and alertmanager packages do, from availability `node` up). Group and kind together, because kind names are not unique across API groups. There is no list of operator kinds anywhere in the checker.

**References to things Kix does not render.** Wrap the name in `kix.untrackedRef` (a ServiceAccount the cluster provides, a ConfigMap another system owns); when a Job or operator in the same package creates it, say so with `kix.untrackedRef { kind = "Secret"; name; by = self.thatJob; }`, which orders the referrer after the creator and makes deploy wait for the object. When the referring workload creates the object itself, write `kix.untrackedRef { name; by = "self"; }`. The value carries an inert marker in its string context; `buildCluster` collects those names before context is stripped, keyed by the referring resource's namespace, and the checks accept them there. A `scope.mkServiceRef` or `scope.mkSecretRef` marker counts as the Service or Secret it describes, in its namespace, and its declared pod selector counts as pods for the Service and NetworkPolicy selector checks. For a cluster-level `kix.mkImport`, pass `kind = "Service"` so the marker carries the kind; a consumer in another namespace wraps the name in `kix.untrackedRef`. A bare string that names nothing in the build fails, and so does a name derived from a resource with a suffix added (`self.sa.out.name + "-typo"`), because the checks look up the resulting name. A suffix on an untracked ref stays untracked, since the author marked it. The StatefulSet headless-Service check reads `clusterIP: None` off a rendered Service and cannot accept a marker.

**Where it sits.** `kix/lib/tests/validate.nix` holds a failing and a passing case per check. The scorecard runs by default and can be capped (§17); these checks are always on and never capped.

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

The namespace prefix is the whole isolation mechanism. A plain dependency auto-instantiated for `dev-app` lands in `dev-app`, because `eval/auto.nix` resolves it into the requesting namespace. Two exceptions, both deliberate: a package that declares its own `namespace` in `availablePackages`, and a cluster that sets `autoNamespace`, are pinned there and so shared by every environment. Role-named deps are keyed by the role rather than by namespace, so one provider serves them all. A package marked one per cluster (`conflictsWith` naming one of its own keys with a `cluster:` prefix, or a role claimant demanded by its package name) that consumers in two environments require is refused: declare it once, and consumers in every environment resolve to it. A copy beside a declared instance that claims the same key without answering the consumer's name is refused by that instance's `conflictsWith`. Two instances that render the same cluster-scoped object, such as a CRD, fail evaluation.

Every environment in one `mkEnv` cluster deploys together, under one activation. When you want them to deploy separately, write one cluster per environment over a shared base module instead (`clusters/example-multi-env/`).

Use only when the environment dimension is genuinely "same shape, different tuning". Don't use for truly distinct shapes — make those separate clusters.

## 19. Multi-component packages

Apps with multiple sub-services (Harbor: core, portal, registry, jobservice, exporter) live in **one package**, not split across packages. They share config, secrets, and internal URLs. Reference: `kix/packages/harbor/`. Deep dive: [`.claude/skills/kix-migration/MULTI_COMPONENT.md`](../.claude/skills/kix-migration/MULTI_COMPONENT.md).

Key patterns:

1. **Shared `let` bindings** — define common values (security contexts, probe bases, internal URLs) once.
2. **Per-component selectors and Service labels** — `scope.selectorLabels // { "app.kubernetes.io/component" = "core"; }` on the workload, and a distinct component label on each Service so `architecture.distinctSameKindLabels` can tell them apart.
3. **Internal URLs carry facts** — components dial each other through `self.<service>.out.fqdn`, never a bare `"${name}-core"` string; that is what gives the consumer its netpol egress and ordering.
4. **Mutual-dial cycles** — when two components dial each other, one Service is built on a literal selector shared with its Deployment, and the Deployment goes in `root.requires`. Pick the side by boot order: the Service that loses its workload edge is the one whose pod must start *later* (Harbor's jobservice fetches its config from core's API and panics until core answers, so the jobservice Service is the literal one), and an explicit `requires = [ self.coreDeployment ]` on that Deployment states the order the graph no longer carries. A component whose own config names its own Service (core's `CORE_URL`) has to be literal regardless.
5. **Secrets are dependencies**: a secret dep is named for its contract (`harborSecrets`) and read through `kix.checkSecretKeys` before the first `out.keyRef`; a password that must appear in a URL goes through `$(VAR)` expansion so no ConfigMap carries it; user `env` goes through `kix.mergeEnv`; a `secret-ref` Secret rolls the pods through an optional `reloader` dependency.
6. **Storage is a DI dep**: the registry's blobs come from `storage`; jobservice's job logs live in the database, so it scales; scratch paths are `emptyDir`.
7. **One `kix.monitor` per metrics Service** — with `name`, `monitorPart` and `rulesPart` so the entries do not collide.
8. **`root.requires` / `root.postHooks`** — `requires` lists what the entry point cannot reach through `self.*` (filter nulls for optional parts); `postHooks` are resources deployed after the rest of the package.
9. **Generated facts**: a value Nix cannot compute from its source (a bcrypt htpasswd line) is written by an init container from the secret, not asked of the user.
10. **Per-workload ceilings**: `availability.max` on one builder call (harbor's registry and exporter) while sibling workloads scale.

## 20. Storage

Storage is first-class via DI: `app → PVC → StorageClass`. Deep dive: [`.claude/skills/kix-migration/STORAGE.md`](../.claude/skills/kix-migration/STORAGE.md).

```nix
# Cluster definition:
instances.kube-system.storage-classes = {
  package = packages.storage-classes;   # claims the storageClasses role; the role name is its alias
  config.classes.local-path = {         # a CSI driver already running in the cluster
    provisioner = "rancher.io/local-path";
    volumeBindingMode = "WaitForFirstConsumer";
  };
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

`size` is required on `persistent-volume-claim`: a generic claim cannot know how much its consumer stores. A package that owns its claim template (valkey `storage.size`, stackgres-cluster `persistentVolume.size`) may default the size. An auto-instantiated claim therefore fails with ``config.size' was accessed but has no value defined``; declare it as an instance. Other PVC spec fields (`volumeMode`, `dataSource`, `dataSourceRef`, `selector`, `volumeName`, `volumeAttributesClassName`) go in `config.extraSpec`; the fields with options are refused there.

### 20.1 StorageClasses

Packages that render StorageClasses describe each class with `kix.types.storageClass { }` and render them with `kix.storage.mkClasses`, which returns the resources and `storageClassName` (taken from the package's own class parts, passed as `parts = self.<part>`, so consumers depend on the class). `storageClassName` is the class a consumer gets when it names none: the class annotated `storageclass.kubernetes.io/is-default-class: "true"` when exactly one is, else the only class. With several classes and no single annotated one, reading it fails the build and the consumer names its class (`persistent-volume-claim` `config.storageClassName`). Annotating a class where `cluster.roles.storageClasses.binding = "shadowable"` is refused, because the environment already has a default class. `storage-classes` takes `config.classes`, a map of `kix.types.storageClass` values keyed by class name, for CSI drivers already running in the cluster.

A StatefulSet that owns per-pod volumes keeps them in `volumeClaimTemplates` and takes an optional `storageClasses` dependency plus a size option (`storage.size`, `kix.types.quantity`): the class is `storage.storageClassName` when set, else `storageClasses.out.storageClassName`, else the cluster default. `kix/packages/valkey` and `clickhouse-keeper` follow this.

### 20.2 Driver packages

A CSI driver package (`zfs-localpv`) publishes its class through `out.storageClassName` and does not claim `storageClasses`; a consumer names it with `deps.storageClasses = ref.<namespace>.<instance>`, or the instance sets `aliases = [ "storageClasses" "zfsLocalPv" ]` (keeping `zfsLocalPv`, which its one-instance check matches on). Its VolumeSnapshotClasses need a provider of the `snapshotController` role: a `snapshot-controller` instance, or the environment's import (the rke2 flavour).

`mayastor` renders replicated NVMe-oF block storage: StorageClasses through `kix.types.storageClass`/`kix.storage.mkClasses` with a required `parameters.repl`, VolumeSnapshotClasses through the `snapshotController` dependency, and DiskPools as `diskPools.<name> = { node; disks; }`. Its etcd takes its class from the `storageClasses` dependency or `etcd.storage.storageClassName`, and evaluation refuses one of Mayastor's own classes: etcd on a Mayastor volume cannot start after a full restart. `out.storageClassName` has the shape `storage-classes` gives, so `deps.storageClasses = ref.<ns>.<mayastor>` works for consumers. Neither driver claims the `storageClasses` role.

### 20.3 Volume replication (VolSync)

`volsync` runs the VolSync operator, one per cluster. It needs the `snapshotController` role whatever the copy method, because the operator watches VolumeSnapshots and does not start without their CRD. A consumer that takes `volsync` as a dependency backs up a claim with restic:

```nix
backup = volsync.out.mkReplicationSource scope {
  name = "data";                 # at most 51 characters
  claim = storage;               # a storage dependency or a PVC part
  schedule = "0 3 * * *";        # five cron fields or @daily and friends
  copyMethod = "Snapshot";       # Direct, Clone, or Snapshot
  restic = {
    repository = resticRepository;  # secret with RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
    endpointService = s3;           # in-cluster store; or null with storePort for one outside
  };
};
root.requires = [ self.backup.replicationSource ];
```

The result is a folder: `replicationSource` and `egress`. VolSync's restic mover reads every value from the one Secret named in `restic.repository`, so the store credentials go there too, and Kix cannot check that `RESTIC_REPOSITORY` names `endpointService`. The CRDs declare `factBehavior.endpoint = "terminate"` with the mover pods' selector (`app.kubernetes.io/created-by: volsync`, `batch.kubernetes.io/job-name: volsync-src-<name>`); the builder attaches the store's address to the repository name, so the movers get egress to the store and the store ingress from them. Without `endpointService`, `egress` opens DNS and TCP `storePort` (443 by default) to the world. Both kinds are ready when `status.latestMoverStatus.result` is `Successful`; VolSync runs the first sync on creation, so the deploy waits for the first backup.

### 20.4 PriorityClasses

`priority-class` creates one PriorityClass per instance, named after the instance. The class is cluster-scoped, and the instance may live in any namespace the cluster deploys, such as its main consumer's. The instance's namespace holds only its PackageInstance record. A workload takes the class as an optional dependency, which also applies the workload after the class:

```nix
# package
build = { self, priorityClass ? null, ... }: {
  deployment = scope.mkDeployment {
    name = "worker";
    spec.template.spec = { containers = [ … ]; }
      // lib.optionalAttrs (priorityClass != null) { priorityClassName = priorityClass.out.name; };
  };
};

# cluster
instances.platform.batch-low = { package = packages.priority-class; config.value = -10; };
instances.apps.worker.deps.priorityClass = ref.platform.batch-low;
```

The package has no default alias, so an unwired `priorityClass` dependency stays null. The built-in `system-cluster-critical` and `system-node-critical` classes need no instance and are named literally in the pod spec. In-tree consumers: loki-logs (wired by the monitoring module), arc-runner-set, cdi, prometheus-operator, prometheus, and alertmanager.

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

A declared key needs a value: in `stringData`, in `extra.data` or `extra.stringData`, or in the SOPS `source`. Without `source`, the build refuses a key with no value, since the Secret would be created without it. A `kubernetes.io/service-account-token` Secret is exempt (Kubernetes fills it). Use `scope.mkSecretRef` when something outside Kix creates the Secret.

The builder stamps where each key's value comes from as `kix.run/secret-sources` (`username=plain,password=sops`): `inline` for a value written in the expression, `sops` for a key the SOPS file fills, `controller` for a key a controller writes (`*=controller` when `keys = [ ]`), and `plain` for an inline value that is not a credential. `plainKeys = [ "username" ]` marks a plain key; a `kubernetes.io/basic-auth` username and the `tls.crt` and `ca.crt` of a `kubernetes.io/tls` Secret are plain by type. A plain key with no value in the manifest is refused. §21.11 says what reads the stamp.

### 21.2 `scope.mkSecretRef` — external

References a Secret managed outside kix (Vault, ESO, cert-manager, operator-provisioned). Emits a `PackageInstance` import marker with `kix.run/mode=import` that the deploy CLI polls before applying dependents — if the Secret is missing or declared keys aren't populated, the wave fails fast.

```nix
appSecret = scope.mkSecretRef {
  name = "my-app-secret";
  keys = [ "API_KEY" "DB_URL" ];   # build-time validation + deploy-time presence check
};
```

`keys` lists every key a pod reads by name. `keys = [ ]` is allowed only when no pod reads a key by name: pods use the Secret whole (`envFrom`, a volume without `items`), and the deploy checks only that it exists. A pod that reads one of its keys by name fails cross-resource check 22 (§17.4).

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

Set `reflect = true` on `scope.mkSecretRef` (or `scope.mkSecret`'s consumer) when an emberstack/kubernetes-reflector Secret is being mirrored across namespaces. Relaxes the same-namespace check in `checkNamespacedRefs`. No package in kixpkgs sets `reflect = true` (housekeeping/2026-10-02-reflector-has-no-consumer.md). For database credentials in another namespace, use a facade such as `stackgres-database`, which creates the credentials Secret in the consumer's namespace.

### 21.5 Restarting pods when a Secret or ConfigMap changes

Kix does not restart pods when a ConfigMap or Secret they read changes. A package that reads a Kix-built ConfigMap or Secret through env or `subPath` puts its identity hash on the pod template, so a content change is a pod template change that the deploy plan shows:

```nix
template.metadata.annotations."checksum/config" = self.config.out.identityHash;
```

A Secret Kix does not build (`scope.mkSecretRef`, a `secret-ref` dependency, a Secret an operator or cert-manager writes) has no content in the build, so a rotation changes nothing Kix sees. For those, the `reloader` package restarts the workload. The workload opts in through the builder args:

```nix
deployment = { name = "web"; spec = { ... }; }
  |> reloader.out.withReloadOn [ self.apiToken ]
  |> scope.mkDeployment;
```

`withReloadOn` refuses a Kix-built Secret or ConfigMap (use the checksum), a built resource, Job and CronJob args, and a Secret in a namespace the reloader does not watch (`extraArgs` `--namespaces`/`--namespaces-to-ignore`). Restarts happen outside the plan. A workload restarts once the first time a reloader leader sees it. A rotation made while no leader runs is applied when the next leader starts: it replays every watched Secret, about three LIST requests per Secret, so `--namespaces` bounds the cost on a large cluster and replaces the ClusterRole with a Role in each listed namespace. A leader that dies holds its Lease until it expires, so a restart can wait for the Lease duration (`--leader-election-lease-duration`, 15 seconds by default) after a leader change.

`withReloadOn` transforms builder args, so it applies to workloads a package builds itself. A packaged workload that reads a `secret-ref` Secret and takes no `reloader` dependency (external-dns, for example) does not restart on a rotation; restart it with `kubectl rollout restart`. harbor takes an optional `reloader` dependency for this.

### 21.6 Packages that hand consumers a Secret

A package whose `out` gives consumers a Secret they read through `secretKeyRef` declares `meta.scope = "namespace"`, because Kubernetes resolves a `secretKeyRef` only in the pod's own namespace. Dependency injection then skips the instance for requesters in other namespaces, and the not-found error names it; an explicit `ref` across namespaces fails `_crossNsCheck`. Example: `valkey` exports its `valkeyPassword` dependency as `out.authSecret`, read as `valkey.out.authSecret.out.keyRef valkey.out.authPasswordKey`. An import (`kix.mkImport`) stays cluster-scoped. immich-machine-learning declares it too, so an immich server binds only a worker in its own namespace; a worker elsewhere is reached through a `kix.mkImport` aliased `machineLearning`.

### 21.7 Credentials in a CR spec

A package that writes a custom resource whose spec names Secret keys takes the Secret as a dependency named for what it holds and fills each selector from `dep.out.keyRef key`, so the custom resource carries a tracked name and Kix checks the key. `cluster-issuer` does this for every `SecretKeySelector` in a ClusterIssuer spec: `(issuerCredentials.out.keyRef key).valueFrom.secretKeyRef`. A selector the user names with a literal string is refused; `kix.untrackedRef` opts out. `cnpg-cluster` fills a backup ObjectStore's `s3Credentials` from its `storageCredentials` dependency the same way, and `cnpg-barman-cloud`'s `out.mkObjectStore` refuses a literal selector anywhere else in the spec (`backup.extraSpec.configuration.endpointCA`).

S3 credentials follow one shape across packages: a `storageCredentials` secret dependency with the keys `accessKeyId` and `secretAccessKey` (renamed through the package's `credentialKeys`), and an optional `endpointService` dependency for a store in the cluster, whose `out.url` becomes the endpoint so the derived policy opens it. `stackgres-object-storage` and `cnpg-cluster` write the keys into a custom resource's selectors. `tempo` runs its own pod, so it passes them as the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` env vars, which Tempo's S3 client reads when its config holds no keys, and refuses the keys in `settings` and on the command line. Without `endpointService`, the endpoint's port is opened to addresses outside the cluster; `cnpg-cluster` and `tempo` refuse an endpoint that names a Service in the cluster, because a world rule does not reach pods.

### 21.8 Secrets synced by the Infisical operator

`infisical-operator` builds the custom resources that make the operator write a Secret, and returns a `scope.mkSecretRef` for it through `out.secretRef`, ordered after the custom resource:

```nix
# deps: infisicalOperator
identity = scope.mkSecretRef { name = "infisical-identity"; keys = [ "clientId" "clientSecret" ]; };
auth = infisicalOperator.out.mkInfisicalAuth scope {
  name = "billing";
  spec = {
    method = "universal";
    universal = {
      clientIdRef = { inherit ((self.identity.out.keyRef "clientId").valueFrom.secretKeyRef) name key; namespace = scope.namespaceName; };
      clientSecretRef = { inherit ((self.identity.out.keyRef "clientSecret").valueFrom.secretKeyRef) name key; namespace = scope.namespaceName; };
    };
  };
};
sync = infisicalOperator.out.mkInfisicalStaticSecret scope {
  name = "billing";
  spec = {
    infisicalAuthRef = { name = self.auth.out.name; namespace = scope.namespaceName; };
    syncOptions.refreshInterval = "1m";
    sources = [ { projectId = "<project id>"; environmentSlug = "prod"; secretPath = "/"; } ];
    targets = [ { name = "billing"; kind = "Secret"; creationPolicy = "Owner"; } ];
  };
};
credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };   # then self.credentials.out.mkEnv { ... }
```

The builders set each target's metadata explicitly, so the operator does not copy the custom resource's annotations (Kix's identity annotation included) onto the Secret it creates; without that, `kix gc` would delete the Secret as Kix-managed garbage. For the same reason the package has no `out.crds` handle for InfisicalSecret or InfisicalStaticSecret, and `out.mkInfisicalDynamicSecret` throws: the operator always copies an InfisicalDynamicSecret's annotations onto its lease Secret. `out.crds` covers ClusterGenerator, InfisicalConnection, and InfisicalPushSecret, which create no Kubernetes object; build an InfisicalAuth with `out.mkInfisicalAuth`, which points it at the default connection and orders it after that connection.

Known limit: `kix deploy` writes its bookkeeping annotations in a second request after each apply. The operator writes an InfisicalAuth's status with an update that fails if the object changed after the operator read it, only logs the failure, and ignores metadata-only changes. An InfisicalAuth applied while the operator runs can therefore stay without `IsReady`; the deploy waits on it until its readiness timeout, and the InfisicalStaticSecret that names it does not sync meanwhile. Restart the operator (`kubectl -n <namespace> rollout restart deployment/<instance>`) or update a Secret the auth references, and the operator reconciles the auth again. This is inferred from the operator's source and not yet observed, because it needs an Infisical identity.

Under egress enforcement the package's network intent opens only TCP 443 to destinations outside the cluster. An `address` inside the cluster or on another port fails the build until a `networkPolicy.platformIntents` entry selects the operator's pods and reaches the address; the error prints the entry to add.

### 21.9 Secrets synced by External Secrets Operator

`external-secrets` builds the SecretStore and ExternalSecret, and returns a `scope.mkSecretRef` for the Secret the controller writes through `out.secretRef`, ordered after the ExternalSecret:

```nix
# deps: externalSecrets, vaultToken (a secret dependency declaring `token`)
store = externalSecrets.out.mkSecretStore scope {
  name = "vault";
  spec.provider.vault = {
    server = "https://vault.example.com";
    path = "secret";
    version = "v2";
    auth.tokenSecretRef = (vaultToken.out.keyRef "token").valueFrom.secretKeyRef;
  };
};
sync = externalSecrets.out.mkExternalSecret scope {
  name = "billing";
  spec = {
    secretStoreRef = { name = self.store.out.name; kind = "SecretStore"; };
    refreshInterval = "1h";
    data = [ { secretKey = "API_KEY"; remoteRef = { key = "billing"; property = "api-key"; }; } ];
  };
};
credentials = self.sync.out.secretRef { keys = [ "API_KEY" ]; };   # then self.credentials.out.mkEnv { ... }
```

`out.mkSecretStore` refuses any `{ name; key; }` Secret selector in the spec whose name is a literal string, as `cluster-issuer` does (§21.7); `kix.untrackedRef` opts out for a Secret created outside Kix. `out.mkClusterSecretStore` refuses the same, and also a selector without `namespace`, which the controller would read from each ExternalSecret's namespace; set `namespace = scope.namespaceName` beside a secret dependency's `keyRef`. `out.mkExternalSecret` sets `spec.target.template.metadata` to `{ }` when the spec has none: without a template the controller copies the ExternalSecret's labels and annotations, Kix's identity annotation included, onto the Secret, and `kix gc --hard` would list it as a copy. It refuses `spec.target.manifest`, since the package grants no RBAC for generic targets. `out.secretRef` refuses creationPolicy None, and, when the spec has no `dataFrom` or `templateFrom` and the creationPolicy is not Merge, a key the ExternalSecret does not write. There is no `out.crds` handle for ExternalSecret, SecretStore, or ClusterSecretStore; `out.crds` covers ClusterExternalSecret, PushSecret, ClusterPushSecret, ClusterGenerator, and the generator kinds (a Password generator feeds an ExternalSecret through `dataFrom[].sourceRef.generatorRef`, and `out.secretRef` then takes the keys the generator writes).

The admission webhook validates ExternalSecrets, SecretStores, and ClusterSecretStores with failurePolicy Fail, and the cert-controller injects the webhook's CA after it starts. Every custom resource built from `out` therefore requires the package's webhook check Job, which succeeds once the API server admits a server-side dry-run create of an ExternalSecret and of a SecretStore.

The controller reads and writes Secrets in every namespace, so a cluster runs one instance. Its network intent opens TCP 443 to destinations outside the cluster. The SecretStore and ClusterSecretStore definitions declare `factBehavior.endpoint = "terminate"` with the controller's pods and namespace (`podNamespace`), so a store whose spec carries a Kix Service address opens the controller's egress to that Service and the Service's ingress from the controller (§21.10). A provider outside the cluster on another port, or one inside it written as a literal address, needs a `networkPolicy.platformIntents` entry for the controller's pods.

### 21.10 Secrets stored in OpenBao

`openbao` runs OpenBao 2.7 as a StatefulSet on integrated Raft storage, one pod at availability `none` and three from `pod` up, with TLS from a cert-manager CA it creates. It takes a required `certManager` dependency and, with the default `seal.type = "static"`, a required `unsealKey` secret with key `key` (32 bytes as raw, hex, or base64 text, with no trailing newline). OpenBao unseals itself with that key on every start. Anyone who can read the `unsealKey` Secret and a Raft volume can decrypt the data, so protection at rest is no stronger than the RBAC on Secrets in that namespace and the cluster's etcd encryption. `seal.type = "shamir"` keeps the unseal keys out of the cluster: a person runs `bao operator init` once and `bao operator unseal` on every pod after each start. Transit and cloud KMS seals are not supported.

With the static seal, pod 0 initializes OpenBao on its first start through OpenBao's declarative self-initialization: it enables Kubernetes auth and creates the policy and role `kix-reconcile`, bound only to the ServiceAccount of the package's reconcile Job. The root token is revoked and no recovery keys exist. The reconcile Job then writes `policies` (HCL by name), `kubernetesAuth.roles` (the body of `auth/kubernetes/role/<name>`), and `secretsEngines` (the body of `sys/mounts/<path>`) on every change. It never deletes: its log lists the policies and roles OpenBao holds that are not declared, and an existing secrets engine is left unchanged. The Job can rewrite any policy, its own included, so its ServiceAccount is as powerful as a root token. In shamir mode no Job runs, and declaring any of the three options is an evaluation error.

```nix
# OpenBao, in namespace `secrets`
openbao = {
  package = packages.openbao;
  config = {
    secretsEngines.secret = { type = "kv"; options.version = "2"; };
    policies.app-read = ''path "secret/data/app/*" { capabilities = ["read"] }'';
    kubernetesAuth.roles.app = {
      bound_service_account_names = [ "openbao-store" ];
      bound_service_account_namespaces = [ "app" ];
      token_policies = [ "app-read" ];
    };
  };
};

# In a package in namespace `app`, with deps externalSecrets and openbao
storeServiceAccount = scope.mkResource { apiVersion = "v1"; kind = "ServiceAccount"; name = "openbao-store"; };
store = externalSecrets.out.mkClusterSecretStore scope {
  name = "openbao-app";
  spec = {
    provider = openbao.out.externalSecretsProvider scope {
      serviceAccount = self.storeServiceAccount;
      role = "app";
      mount = "secret";
    };
    conditions = [ { namespaces = [ scope.namespaceName ]; } ];
  };
};
```

`out.externalSecretsProvider` returns the `vault` provider: the Service URL, the CA from the `<instance>-tls` Secret in OpenBao's namespace, the mount and its KV version, and Kubernetes auth with a token of the given ServiceAccount. It refuses a role that `kubernetesAuth.roles` does not declare or that does not bind that ServiceAccount and namespace (`*` binds any), and a mount that is not a declared `kv` engine. The role name it writes carries the reconcile Job, so the store is applied after the Job has written the role. A namespaced SecretStore cannot read the CA Secret from OpenBao's namespace, so the provider is for a ClusterSecretStore, limited to its namespaces with `conditions`. `clusters/test-openbao.nix` evaluates this shape.

The store carries the OpenBao Service's address, so the external-secrets store definitions' `factBehavior` (§21.9) gives the controller egress to port 8200 of the OpenBao pods and those pods ingress from the controller.

Metrics. With a `prometheus` dependency and `metrics.enabled` (the default), each pod opens a second listener on TCP 8202 that serves only `/v1/sys/metrics`, over plain HTTP and without a token, so standbys and sealed pods report too. The output names mount paths, auth methods, and policies. Under network policy only the Prometheus scrape and the other OpenBao pods reach the port; on a cluster without an enforcer any pod can read it. Set `metrics.enabled = false` to close the listener, which also drops the ServiceMonitor and the alert rules.

Known limits. If self-initialization fails on pod 0's first start, OpenBao has already initialized the volume and revoked the root token, and it refuses to unseal on every later start; delete the claim `data-<instance>-0` and the pod and let it start again (self-initialization runs only on an empty volume). The static key cannot be rotated: a changed `unsealKey` value restarts the pods, and they cannot unseal the existing data until the old value is restored.

### 21.11 Where a Secret's value comes from is the site's choice

A package declares the shape of a Secret (its keys and type) and takes every credential a site supplies as a secret dependency, so the cluster file decides the source: a `packages.secret` instance with `stringData` (the value is in the build) or a SOPS `source` (the deploy decrypts it), or a `packages.secret-ref` instance for a Secret a secrets operator, cert-manager, or a person creates. The three share the alias the package names and the same `out`, so the package's code does not change with the source. A package does not take a credential as a string or path option (`token`/`tokenSource` was the last such pair; cloudflared takes `tunnelToken` now).

A cluster says which sources it accepts:

```nix
cluster.secrets.accept = [ "sops" "external" "controller" ];
```

Null (the default) accepts everything. When set, the `security.secretSource` scorecard rule reports each key of a rendered Secret whose source is not listed, reading the `kix.run/secret-sources` stamp (§21.1), and each `scope.mkSecretRef` marker when `external` is not listed. A `plain` key is never reported. The finding names the instance, the Secret, the keys, and the accepted sources; at `scorecard.maxSeverity = "error"` it fails the build. A key with a value in `data` or `stringData` counts as inline (or plain, when the stamp says so) whatever else the stamp claims, so a stamp on a Secret `scope.mkSecret` did not build cannot hide a value; a Secret without the stamp (a chart's) is inline for every key in its data. `scope.mkSecret` refuses a valued key that `keys` leaves out, so a stamp it writes covers every value.

Software that reads plain configuration from a Secret (Alertmanager's `alertmanager.yaml`) is the case the sources above do not fit: the Secret is rendered from options, so its keys are `inline`, and whether it holds a credential depends on what the site wrote. Such a package offers three routes, the first two where the software allows them: the configuration in a non-Secret field of its custom resource (victoria-metrics-alert's `alertmanager.configRawYaml`), an optional secret dependency in place of the rendered Secret (`alertmanagerConfig`, key `alertmanager.yaml`, on alertmanager and victoria-metrics-alert), and the rendered Secret classified as configuration (`meta.classification = "configuration"`, which renders as `kix.run/classification`) with the credential keys the package knows refused (alertmanager's `inline-secrets.nix`). The rule reports an inline key of such a Secret as `configuration`, and a cluster that lists `configuration` in `cluster.secrets.accept` takes the package's word that the Secret holds no credential. The library does not check that word: the classification is an annotation any package or `partsOverlays` can set, and nothing ties it to a credential refusal.

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
    instance = scope.mkCR self.crd {   # mkCR adds the dependency on the CRD
      name = "my-instance";
      spec = { ... };
    };
  };
}
```

`scope.mkCRDRef { group; kind; plural; version; }` creates a CRD marker (no CustomResourceDefinition) for a CRD something else installs. `version` is required: Kix cannot read it from a spec it does not have, and custom resources built from the ref use it unless they set their own. Other versions the CRD serves go in `servedVersions` (default `[ version ]`); a custom resource may set only those. The marker is a PackageInstance named `crd-ref-<instance>-<plural>-<group-with-dashes>` in the declaring package's namespace, so two instances that reference one CRD get two markers. It carries `kix.run/crd-kind`, `kix.run/crd-version`, `kix.run/crd-served-versions` (the served list, comma separated), and `kix.run/crd-scope`. `kix deploy` waits for the CRD to be Established and then checks that it serves every declared version; one it does not serve stops the deploy with an ImportMismatch naming both lists. Every custom resource must depend on a declaration of its kind (cross-resource check 21, §17.4); `scope.mkCR` adds that dependency. A CRD the environment installs is declared with `kix.mkImport { crds }` (§23) or with a `scope.mkCRDRef` in a package of your own.

An operator whose admission webhook guards its own kinds gates its CRD handles on its API-check Job, so every custom resource built with `scope.mkCR dep.out.crds.<Kind>` waits for it; the handles also declare the kind's readiness. Because the handle carries the gate, the package needs no `out.mk<Kind>` builder. Example: cert-manager (`kix/packages/cert-manager/crds.nix`, `gate`).

The same gate applies when the operator writes its webhook entries after it reports ready, since a CRD reference is satisfied once the definition is Established. `stackgres-operator` installs its definitions, reports ready, and writes its webhook entries a few seconds later; an SGCluster created in that window gets no defaults or status, and StackGres then rejects every update of it. Its `webhookCheck` Job waits until both configurations hold their entries and a server-side dry-run create comes back mutated, and every handle on `out.crds` adds that Job to the custom resource's `requires`. `cnpg-operator` gates its handles the same way: Kix renders CloudNativePG's webhook configurations without `caBundle`, the operator writes it when it starts, and the check Job's server-side dry-run create of a Cluster succeeds only once the API server can call both Cluster webhooks. The ScheduledBackup and Pooler handles that `cnpg-cluster` and `cnpg-pooler` build from are gated too. `rabbitmq-operator` gates its RabbitmqCluster handle the same way: cert-manager's cainjector writes `caBundle` into the webhook configurations Kix renders, from the Certificate their `cert-manager.io/inject-ca-from` annotation names, and the check Job's dry-run create of a RabbitmqCluster succeeds once both webhooks answer. The `cnpg-barman-cloud` plugin serves no admission webhook, so its ObjectStore needs no check; the ObjectStore definition declares `factBehavior.endpoint = "conduct"`, so an in-cluster S3 Service named in its `endpointURL` reaches the instance pods of the Cluster that names the ObjectStore.

`fromKind` builds a single-version stub whose spec accepts anything. It is
for kinds Kix invents. A package that wraps an upstream operator vendors the
real CRDs instead: one JSON object per CRD under `<pkg>/crds/`, refreshed
from the public URLs in `crds/sources.txt` by `scripts/vendor-crds.py`
(`--check` runs in CI), and loaded with
`scope.mkCRD { spec = (builtins.fromJSON (builtins.readFile ./crds/<name>.json)).spec; }`.
When the operator installs and rewrites its own CRDs, ship `mkCRDRef`
markers and no copy. Rules and the bump procedure: the `crd-vendoring`
skill and `v2_discussions/146_crd_vendoring_and_upgrades.md`.

Every builder refuses a custom resource at a version its declaration does
not serve: for `mkCRD` and a chart's CRDs, a version missing from
`spec.versions` or marked `served = false`; for `mkCRDRef`, anything not in
its `servedVersions`. The build fails with the served list instead of every
apply failing.

A Helm chart's custom resources depend on the chart's own CRDs. A chart
resource of another package's kind cannot: turn its values toggle off and
build it with the owner's builder (`kix.monitor`, or `scope.mkCR` on the
owner's `out.crds.<Kind>`) in a package.

Both `mkCRD` and `mkCRDRef` accept three per-kind controller-semantics declarations that ride the typed chain into every CR built via `mkCR`:

- `factBehavior = { endpoint = "terminate"|"conduct"; podSelector = cr: {...}; podNamespace ? <namespace> | cr: "<namespace>"; selfScrapes ? cr: [...]; }` — netpol semantics (§facts). `podNamespace` places the operand pods outside the custom resource's namespace, as for a controller that serves every namespace (external-secrets' stores); the egress policy then lands in that namespace, named with the instance's namespace first. `selfScrapes` lists the scrape objects the controller creates for the custom resource's own pods, `{ kind; name; labels; podSelector; ports; }` each with pod port numbers, which the scrape join (§16.8) treats like rendered ones.
- `usesAtLeast = cr: { <ResourceQuota key> = <quantity>; }`: function returning the least the operator always uses for a custom resource, keyed like a ResourceQuota's `spec.hard` (`pods`, `requests.cpu`, `requests.storage`, `services`). `kix.usage.ofPod`, `kix.usage.times`, and `kix.usage.add` build it from containers. The build counts it against the namespace's ResourceQuotas (§16.4, Namespace quotas; for example, `cnpg-operator`'s Cluster declares `spec.instances` pods with `spec.resources`, and one claim of `spec.storage.size` each).
- `readiness = { path = "/status/updateStatus"; equals = "operational"; }`, `readiness = { path = "/status/updateStatus"; notEquals = "failed"; }`, or `readiness = { condition = { type = "Bootstrapped"; status = "True"; }; }`: the controller's health convention, stamped on each CR as the `kix.run/readiness` annotation; `kix deploy` evaluates it instead of the generic Ready/Available condition check. The path form compares one status field with a string; a boolean or number field compares by its JSON text, so `equals = "true"` matches `true` (CloudNativePG's Database reports `status.applied` as a boolean); `notEquals` is ready while the field is absent or holds another value, for a resource whose status only a consumer writes (a VictoriaMetrics VMServiceScrape gets `updateStatus` only from a VMAgent that selects it); the condition form looks for an entry in `status.conditions` with that type and status. Declare one whenever the operator never stamps Ready/Available (VictoriaMetrics uses `updateStatus`, StackGres reports `Bootstrapped`, the Gateway API reports `Accepted` and `Programmed`); without it, deploys time out waiting on healthy CRs.

A CRD the operator installs itself, with condition readiness (mayastor's DiskPool):

```nix
diskPoolCrd = scope.mkCRDRef {
  group = "openebs.io"; kind = "DiskPool"; plural = "diskpools";
  version = "v1beta3";
  installedBy = self.operatorDiskpool;   # the operator creates and migrates the CRD
  readiness.condition = { type = "PoolReady"; status = "True"; };
};
```

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

A package run in import mode renders nothing, so its scope is cut down: it
offers `mkResource`, `mkClusterResource`, `mkCR`, the two ref builders, and the
workload builders (`mkDeployment`, `mkStatefulSet`, `mkDaemonSet`, `mkJob`,
`mkCronJob`). The workload builders seal nothing and emit nothing; they exist
because the documented way to write a Service is `kix.service.fromWorkload`,
which reads the workload's selector and container ports on the way to the `out`
values the import does need. A package that reads a dependency argument fails
with the reason named. A builder not in that list (`mkCRD`, `mkCRDRef`,
`mkSecret`) is missing from the scope, and the error is Nix's missing
attribute (housekeeping/2026-10-01-import-scope-has-no-crd-builders.md). A
list `build` runs entry by entry as it does for a managed instance, so
`kix.monitor` and other helper entries work in import mode; `partsOverlays`
do not apply, `availability` is `"none"`, and `deps` is empty.

An environment that installs CRDs itself declares them with `crds`, a list of
`scope.mkCRDRef` arguments without `installedBy`. Each entry becomes
`out.crds.<Kind>`, which a consumer passes to `scope.mkCR`, and a CRD marker in
the import's namespace that `kix deploy` waits for. The markers are emitted
only while the import is active. An optional dependency does not activate an
optional import and does not resolve to an inactive one, so an import whose
handles packages read through optional dependencies is declared without
`optional = true`.

```nix
package = kix.mkImport {
  roles = [ "snapshotController" ];
  crds = [
    { group = "snapshot.storage.k8s.io"; kind = "VolumeSnapshotClass"; plural = "volumesnapshotclasses"; version = "v1"; crdScope = "Cluster"; }
  ];
};
```

Before applying dependent resources, `kix deploy` waits for each
`kix.run/mode=import` PackageInstance to exist. This check cannot be skipped.
Set `optional = true` when the resource may legitimately be absent. Kix checks
the kind, API version, and name, plus the declared keys for a Secret reference.
It does not verify imported `fqdn` or `port` values.

An optional import is active, and its marker emitted, when a required
dependency of an active instance demands it, or a `deps.<arg> =
ref.<ns>.<inst>` names it. An inactive optional import answers no
dependency: an optional dependency that only it would answer is null. An
import without `kind` is ready as soon as its marker exists,
so give an import `kind`, `apiVersion`, and `out.name` when the deploy should
wait for the resource. A flavor declares an import only for a resource the
provider creates on every new cluster. An import with `kind` and `out.name`
stands for that object in the cross-resource checks; for a built-in
cluster-scoped kind (StorageClass, IngressClass) it counts in every
namespace.

An import's `out` is the `out` it declares over the `from` package's root
resource `out`; extras a managed package adds to `root.out` are absent
(housekeeping/2026-10-01-import-drops-root-out-extras.md). An imported
valkey has no `out.authSecret`, for example, so n8n sends no password to it
and takes one from `env.QUEUE_BULL_REDIS_PASSWORD` as a `secretKeyRef` named
with `kix.untrackedRef`.

An import's marker can depend on something no value connects it to. List it in
the instance's `extraDeps`, as a resource or as `ref.<ns>.<inst>`, which
stands for that instance's PackageInstance marker:

```nix
{ ref, ... }: {
  instances.legacy.legacy-api = {
    package = kix.mkImport { kind = "Service"; apiVersion = "v1"; out.name = "legacy-api"; };
    extraDeps = [ ref.apps.legacy-api-contract ];
  };
}
```

A `ref` does not activate an optional instance. Evaluation fails, whether or
not the instance is active, for an entry that is neither a resource nor a
`ref`, for a `ref` to the import itself, and for `extraDeps` on a managed
instance, whose resources take `requires` or `extraDeps` in their builders
instead. When the import is active, a `ref` to an optional instance that
nothing activates also fails.

### 23.1 A platform and its consumers

Two Kix clusters can share one Kubernetes cluster as a platform and its
consumers. Each builds alone, from its own repository, under a name of its
own. The platform says what each consumer gets, and its build writes that
down as an interface file, which the consumer's build loads. Neither side
needs the other's code.

The platform declares each consumer:

```nix
{
  consumers.acme = {
    namespaces = {                                # an exact name, a prefix "x-*", or "*"
      "acme-*" = {
        podSecurity = "restricted";               # each namespace "acme-*" matches
        quota = { pods = "4"; "requests.cpu" = "500m"; "requests.memory" = "512Mi"; };
        max = 3;                                  # at most 3 such namespaces; patterns only
      };
      acme-app = {                                # an exact name inside the pattern
        quota."requests.memory" = "2Gi";          # adjusts that one namespace
        secrets = [ { name = "postgres"; keys = [ "user" "password" ]; } ];
      };
      reports = { };                              # granted, no settings
    };
    services = [ "data/postgres-shared" ];        # "namespace/instance", active and managed
    clusterScoped = [ { kind = "ClusterRole"; name = "acme-reader"; } ];
  };
  reservedNamespaces = [ "kube-system" ];         # the platform's, though it renders nothing there
  secretsRecipient = "age1...";                   # the key SOPS files are encrypted to
}
```

Each key of `namespaces` grants namespaces and holds their settings:
`podSecurity`, `quota` (the ResourceQuota `hard` limits, with Kubernetes'
key names), `max` (on a pattern only), and `secrets` (on an exact name only;
`type` defaults to `Opaque`). A namespace takes the settings of the pattern
that matches it, then those of its exact name on top: the exact name's
`podSecurity` replaces the pattern's, and its `quota` keys replace the
pattern's keys of the same name. Above, `acme-app` gets `pods = "4"`,
`requests.cpu = "500m"` and `requests.memory = "2Gi"`. Every namespace gets
its own quota; the limits are not shared between namespaces.

The platform's namespaces are those its build renders objects into, and
`reservedNamespaces`. A consumer may use any namespace one of its keys
matches and that is not the platform's. `*` matches every namespace that is
not the platform's and that no other consumer's key matches: with one
consumer on `*` and another on `acme-*`, `acme-app` is the second's. The
platform's build:

- fails when more than one consumer holds `*`, when two consumers' other
  keys can match the same namespace, when two patterns of one consumer can
  match the same namespace (an exact name inside a pattern is fine), when an
  exact name is a platform namespace, when a pattern has `*` anywhere but at
  its end, when `max` is on an exact name, and when `secrets` is on a
  pattern;
- with `networkPolicy.enable`, renders a NetworkPolicy
  `kix-consumer-<consumer>-<instance>` in each granted service's namespace
  that lets pods of every namespace labelled `kix.run/consumer=<consumer>`
  reach the Service's pods. Off, it renders none: an allow policy would
  isolate those pods from everyone else;
- writes `kix-interface-<consumer>.json`, referenced by the Activation record
  and linked beside it in `cluster-<name>-activation`. Its record lists each
  consumer in `spec.consumers.<consumer> = { interface; sha256; }`, the hash
  taken as the consumer's build takes it (below).

It renders nothing in a consumer's namespaces. The interface lists the
Secrets a grant names under their namespace; the platform's own instances create them, for example
with the reflector package (§21.4) or a package that mints a credential per
consumer. Kix does not copy them.

The interface is data only. It holds the format `version` (2), the
platform's name, the consumer's name, the platform's facts (provider,
Kubernetes version, cluster domain, capabilities, whether network policy is
enforced), `namespaces` (each key with its `podSecurity`, `quota`, `max`, and
`secrets`), `platformNamespaces`, `claimedNamespaces` (the other consumers'
keys, for the consumer holding `*`; empty for the others), each service's
`out` and roles, the cluster-scoped objects allowed, and `secretsRecipient`. Functions and
`identityHash` in an `out` are left out. A string whose context holds a store
path other than a resource's identity, a fact, or a marker, such as a SOPS
file or a rendered configuration file, fails the platform's build naming the
field, `consumers.acme.services."data/postgres-shared".out.config`. A
password typed into `out` as plain text is not caught; review the
interface's diff.

The consumer commits a copy and loads it, under any cluster name it likes:

```nix
kix.buildCluster {
  name = "acme-production";
  modules = [ (kix.interface ./kix-interface/prod.json) ./acme.nix ];
}
```

`kix.interface` sets the facts as defaults, adds one `kix.mkImport` per
service, named for the platform's instance, and puts the parsed file in
`config.interfaces.<platform>` for the cluster's modules to read
(`config.interfaces.prod.namespaces.acme-app.secrets`). The imports go in the
first exact name, in alphabetical order, among the consumer's keys. When
there is none, name the namespace: `kix.interface { file = ./kix-interface/prod.json; importNamespace = "acme-app"; }`.
The build then:

- fails unless the file's `version` is one this kix reads;
- renders the consumer's own namespaces, each with the label
  `kix.run/consumer=<consumer>`, and with the Pod Security level and quota
  its settings give, where they set them. An instance that needs a more
  permissive level than the interface's fails as it would against a
  namespace's own `podSecurity`;
- fails when it renders more namespaces matching a pattern than the
  pattern's `max`, naming them. Exact names inside the pattern count;
- fails on a workload whose pods the interface's Pod Security level refuses,
  as Kubernetes admission would at deploy (§16.4, Pod Security Standards). The
  message names the instance, the workload, each container and field, and
  the value to set;
- fails on any object, or Namespace, in a namespace no key matches, that
  is the platform's, or that a `claimedNamespaces` key matches, and on any cluster-scoped object `clusterScoped`
  does not list. The Activation record and the `kix.run` CRDs are exempt:
  every Kix cluster renders them;
- records the file in its Activation record as
  `spec.interfaces.<platform> = { consumer; path; sha256; }`, `path` being the
  file's path in the flake, or null when it is outside it. `sha256` is of the
  file as the platform's build writes it (compact JSON, keys sorted), so a
  copy an editor reformatted names the same interface as the platform's file.

The platform owns Kix's own CRDs, `activations.kix.run` and
`packageinstances.kix.run`, on the Kubernetes cluster. A consumer's build
still contains them, because its PackageInstances and its record depend on
them. Its deploy never writes them. Every Kix cluster applies with the same
field manager, so a consumer's apply would replace the platform's schema
without a conflict, and a consumer on another Kix version would change it.
`kix deploy` and `kix plan` read a build whose record has
`spec.interfaces` as a consumer's, and for these two CRDs:

- the plan leaves them out of `objects.writes` and the package diff;
- the deploy runs a `wait` node for each: it waits for the live CRD to be
  established and to serve every version the build's copy serves, then lets
  the objects that depend on it go ahead. It neither applies the CRD nor adds
  the consumer to its `kix.run/activations` annotation;
- when the CRD does not appear before the readiness timeout, the node fails
  and says to deploy Kix on the platform first. When the live CRD lacks a
  version, it fails at once and says to upgrade Kix on the platform first.
  Nothing that depends on the CRD is applied.

A consumer on a newer Kix whose CRDs serve a new version therefore waits for
its platform to upgrade. A consumer never deletes these CRDs: prune never
deletes a CRD (`never_pruned`).

Moving to a newer interface is a commit of the new file. `kix status` on the
consumer compares the `sha256` its live deploy pinned with the one the
platform's live deploy records, and says when they differ:
`acme-production was built against a different interface from the one prod
runs now. Commit prod's current kix-interface/prod.json and deploy
acme-production to take it up.` When
they match it says nothing. It also says when the platform has no live
deploy, no longer publishes an interface for the consumer, or its records
cannot be read (HTTP 403). The `*` holder's interface changes when another
consumer's keys do. Each environment is
a cluster of its own with its own copy: `acme-production` against `prod`,
`acme-staging` against `staging`. These build-time checks catch mistakes;
they do not stop a consumer that deploys with the cluster's full rights from
doing anything else.

## 24. Manifest stamping

Every kix-managed resource gets:

| Annotation/Label | Value |
|---|---|
| `kix.run/identity-hash` | Blake3 32-char store hash (change detection) |
| `kix.run/depends-on` | Comma-separated dep entries: bare hash (implicit), `requires:<hash>`, `extra:<hash>` |
| `kix.run/package` | Package instance name |
| `kix.run/package-namespace` | Package namespace |
| `kix.run/mode` | `"import"` for external resources |
| `kix.run/rerun` | `on-change`, on a `kix.healthCheck` Job, or a package Job that sets it from `kix.keyValues.rerunOnChange`: never patched, deleted and created again when its hash changed or its last run failed (§9.4, check 16) |
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
on the pod template. The exception is a package that hashes a ConfigMap or
Secret into a pod-template annotation to force a rollout on a change (for
example `valkey` and `coredns`). Their pods roll once. A second deploy is a no-op.

**While the compatibility layer stands**, a Kix key is read under the new
domain first and the old one second, so an object an older Kix stamped is
still recognised. A build loaded from a pre-move activation, including a
`kix rollback` target, has its keys and its record's API group moved on load.
The layer lives in `cli/kix/src/legacy_domain/` and goes as one piece; the
checklist is in `v2_discussions/archive/137_kix_run_domain_migration.md`.

## 25. Activation CR and operator

The cluster's root resource is an `Activation` CR. `mkActivation` references every PackageInstance via Nix string context, so `nix-store -q --tree` on the Activation derivation yields the full deploy DAG. This contract is what the CLI (and operator) rely on for ordering. The record's store file also references `kix-packages.json`, which references every resource it lists, so the record's closure holds every file a deploy applies (an import marker that no object uses among them) and the record's name changes when any of them does. That reference adds no `kix.run/depends-on` entry.

**Activation lifecycle:** `Queued → Deploying → Active | Degraded | Failed → Superseded`.

The record is created before the first wave, not after the last, so a deploy
that stops part way leaves one. `Degraded` means the deploy finished but some
resources failed to apply or become ready; it is still the cluster's current
state. `Failed` means the deploy stopped before finalizing, so it is not a
current state and `kix deploy` never diffs against it. The next deploy reads a
`Failed` record only as an extra baseline, to re-apply what that run may have
changed and prune what it left behind, then supersedes it.

When a deploy begins, it also writes its build's package index to the record's
`status.packageIndex`: for each package, the identity hashes of its
PackageInstance and resources, plus the identity hashes of the cluster-level
resources, under a `format` number. When `kix diff` or `kix plan` rebuilds the
old side from live objects because the deployed build is not on the machine, it
places each object in the package that index names, so an object that moved
between packages shows under both. A record without the index, or with a
`format` this release does not know, places live objects where the new build
puts them. An index over 150 KiB (some 3,600 objects) is not written, and a failed write only logs a
warning.

A deploy or rollback that keeps orphans (no `--prune`, `--prune-mode=no`, or a
failed delete) lists the builds they came from under the new record's
`status.orphansKeptFrom`, so a later `kix deploy --prune` or soft `kix gc` can
still delete them. Two deploys planned against the same Active record can lose
part of that list: the one that finalizes second writes it without the first
one's builds. To keep the list empty, pass `--prune` to every deploy and
rollback; no configuration setting makes it the default for the CLI, and the
operator always deletes orphans.

| Path | Behavior |
|---|---|
| Default (no `--operator`) | CLI runs the scheduler directly. Reads/writes `Activation` CR for state. Wave-based apply with SSA, readiness, prune. |
| `--operator` | CLI patches the Activation CR's source path; the kix-operator reconciles. When an Active, Deploying or Degraded Activation CR is deleted, the operator's finalizer deletes that activation's resources except Namespaces and CustomResourceDefinitions, which it always keeps. Deleting a Superseded CR (what `kix gc --operator` does) only removes the finalizer. |

Operator requires `nix-store` binary on the host and read access to `/nix/store/`.

## 26. Diff and snapshot tooling

| Need | Tool |
|---|---|
| Diff vs live cluster | `kix diff <cluster>` (default mode) |
| Diff vs snapshot or export dir | `kix diff <cluster> --from <dir>` |
| Diff between two builds | `kix diff <cluster> --from <result>` |
| Save live state | `kix snapshot save <cluster> <dir>` (in-CLI; the named Kix cluster's objects, found by the `app.kubernetes.io/managed-by=kix` label and attributed through their `kix.run/activations`) or `./scripts/kix-dump.py --all <dir>` (Python; broader scope) |
| Preview a deploy | `kix plan <cluster>` |
| Apply with planning | `kix deploy <cluster>` (prints the same plan before it asks) |
| Markdown for PR comments | `kix diff <cluster> -o markdown` |

### 26.1 `kix plan` and `kix diff`

`kix plan` runs the deploy pipeline with every write sent as `dryRun=All`,
so the apiserver answers for each object. `kix diff` reads only. Both write
the same plan file with `--save F.kixplan`, and `kix diff -o json|yaml`
prints the document the file holds (`cli/kix-cli/schema/plan.schema.json`),
so a consumer can read either. `kix plan` prints no JSON or YAML.

A plan file (`cli/kix/src/plan/file.rs`, header schema
`cli/kix-cli/schema/kixplan.schema.json`) is a seekable zstd file, the
bundle's container (`cli/kix-container`). Frame 0 is the header: the plan
document at `--detail fields`, the new build's graph as `kix graph --format
json` prints it, and `shown`, for each changed, added, or removed object its
package key, the SHA-256 of its old and new manifest files, and its Pod `rollout` (`restart`,
`on_delete`, or `null`). The later frames hold the manifests, secrets hidden,
each named by its SHA-256 and checked against it on every read. `zstd -dc
F.kixplan | jq -s '.[0]'` prints the header.

| | `kix plan` | `kix diff` |
|---|---|---|
| Permissions | the deployer's (a dry run is authorised like the write) | `get` and `list`; none with `--from <build>` |
| Field changes | live object against the dry-run result | build against the kix-owned view of the live object |
| Ownership conflicts, webhooks, admission policies, validation, RBAC | checked | `not_checked` (`read_only`) |
| Prune fates | checked | `not_checked` |
| Drift | fields the deploy reverts | every drifted field, with whether the deploy reverts it |
| `made_by` | `dry_run` (`builds` with `--current-activation`) | `live_read`, or `builds` with `--from <build>` |

Each section of the document is `{"status": "checked", "items": [...]}` or
`{"status": "not_checked", "reason": ...}`, where the reason is
`builds_only`, `read_only`, `deployed_build_unavailable`, or
`not_previewable`. `readiness` is always `not_checked`: no preview can say
whether Pods start.

When the deployed build's store path is on this machine, each field change
carries `labels`:

- `intended`: the deployed build and the new build differ here.
- `reverts_drift`: the live object differs from the deployed build here, and
  the deploy applies the object, so it puts the deployed value back.
- `drift_kept`: the live object differs from the deployed build here, and the
  deploy leaves the object alone because its identity hash did not change.
  `kix deploy --reconcile` applies it.

A field another manager changed is usually also owned by that manager, so a
plan reports it as an ownership conflict naming the manager; with
`--force-conflicts` the plan shows it as `reverts_drift` instead.

`kix diff` against the cluster compares an object the build does not change
(its `kix.run/identity-hash` names a manifest in the build) as that manifest,
the same rule `kix deploy` uses to skip it. So values the API server rewrote
never show as changes. Its `drift` section needs no deployed build. For each
object whose fields Kix applied have changed since, it lists the fields the
build sets that another field manager changed or took over, with the
manager's name.

The dry run cannot check an object whose kind comes from a CRD the deploy
installs, or whose namespace the deploy creates, because a dry run persists
neither. Those objects are listed under `not_checked` with their changes
from the build comparison; most of a first deploy is in that list.

`kix plan` exits 0 when the deploy would change and delete nothing, 2 when
it would change or delete something, and 3 when it would stop. `kix deploy` makes the same plan
before it asks for confirmation, and under `--on-error stop` it stops before
applying anything when the plan shows a refused write.

`kix plan` and `kix deploy` refuse a build when the deploy would write or
delete an object the package list does not show, and name the objects.
`--reconcile`, a repair after a deploy that stopped part way, and a rerun
probe Job write some objects again unchanged: the cluster already ran the
same file for each, so the package list leaves them out. The document lists
every object the deploy writes and deletes under `objects`, re-applied ones
included, and its digest as `objects_digest`.

`kix deploy --plan plan.kixplan` deploys a reviewed plan file and reads no
other kind of file. It plans again with
the saved plan's flags and exits 4, applying nothing, when the cluster, the
new or deployed build's identity hash, the objects digest, or the flags
differ, or when the new plan has a refusal, reverted drift, or prune delete
the reviewed one did not. So the deploy writes and deletes the objects the
reviewed plan lists, made from the same build files, or nothing. A plan
without `objects`, such as a saved `kix diff`, is refused, as is a plan made
from two builds alone. A plan made by another Kix binary is reported, not
refused.

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
| `<Kind> name '<n>' is not a legal Kubernetes object name` | Packages usually derive resource names from `scope.instanceName`, so rename the instance with a lowercase name. If consumers use a camel-case build argument, preserve it with `meta.defaultAliases = [ "camelCaseArgName" ]` |
| `annotationDomainOwnership` warns about an operator's annotations | Declare the DI dep on the operator (e.g. `reflector`), or on something that depends on it, and use its builder; for domains consumed outside kix add `scorecard.knownAnnotationDomains` |
| Cross-namespace mount or secret-ref errors at build | Either move the resource to the right ns, use `scope.forNamespace`, or set `reflected = true` if reflector mirrors it |
| Dep injection overrides a value you want to pin | Wrap with `mkLocked` |
| Reflected secret looks unhealthy | Reflector controller copies on schedule; `reflected = true` relaxes ns-check but does not guarantee the copy exists. Order via DI on the reflector |
| `_kix.<typo>` silently dropped | `stripKixMeta` enforces a whitelist (`namespace`, `source`, `reflected`, `serviceAccountNamespace`) and throws on unknown keys |
| `_type` markers eaten in unexpected places | `collectTypedAttrs` stops descending at `_type` — that's intentional (resources are leaves). Only attrsets without `_type` get traversed |
| A `let`-bound `mkSecretRef` doesn't appear in the output | Return it from `build` (inherit it into the return attrset) |
| `extra.spec = ...` errors with shadowing | Use the dedicated `spec` arg. `extra` is for sibling fields kix doesn't model (e.g. `provisioner` on StorageClass) |
| `kix.expose` does nothing | Neither `gateway` nor `ingressNginx` is wired. Wire one in the cluster: `instances.<ns>.gateway = { package = packages.envoy-gateway; ... };` (or `packages.traefik`) or `instances.<ns>.ingress-nginx = { package = packages.ingress-nginx; };` |
| `kix.expose`: Gateway ... has no HTTP or HTTPS listener that accepts host ... | Add a listener whose `hostname` covers the host with `allowedRoutes.namespaces.from = "All"`, or move the app's `ingress.host` to a name a listener accepts |
| Build fails: "dependency 'x' of ns/inst has no instance, and 2 packages in availablePackages provide it" | Kix does not choose between shelf packages that answer one name. Declare the one you want as `instances.<ns>.x = { package = ...; optional = true; }`, or remove the others from `availablePackages` (§13.1). If auto-instantiation already created and deployed it, keep the name it used (the package name, such as `stackgres-cluster`); another name renders a new instance and orphans the old one with its data |
| `kix.monitor` does nothing | No `prometheus` instance; or the prometheus package doesn't expose `out.mkServiceMonitor` |
| Build fails: "extra.* shadows managed field" | Move customizations into `spec`/`data`/`stringData` directly |
| Workload starts before its CNPs | Per-workload CNPs are emitted *inside* `mkDeployment`/`mkStatefulSet`/`mkDaemonSet` and spliced into the workload's `extraDeps` so the workload depends on its own policies. If you see ordering issues, you're likely on the post-fixpoint path (RBAC/CRD/LB CNPs); check `processInstance` in `kix/lib/plugins/netpol/` |
| Build fails with `[validate] Service ... matches no workload pod template` | The Service selects pods that are not in the build. Typo in a label, or operator-created pods: see §17.4 (`scope.mkServiceRef` to the operator's Service, or `kix.run/operand-of` on the Service) |
| Build fails with `kix: <package> runs once per cluster (...), but auto-instantiation would place it in N namespaces` | Consumers in two namespaces demand a one-per-cluster package and no instance is declared. Declare the package once in its own namespace (`instances.<ns>.<name>.package = ...`), which every consumer then resolves to, or bind each listed consumer to the copy auto-instantiated as `<ns>/<name>` (`deps.<name> = ref.<ns>.<inst>`). A requester marked `(auto-instantiated for ...)` has no `deps` to set, so only the declared instance fixes it |
| Build fails with `kix: <package> runs once per cluster (...), and <ns>/<inst> is declared, but auto-instantiation would add another copy` | The declared instance claims the same `cluster:` key or role but does not answer the name the consumer depends on (instance `aliases` replace `meta.defaultAliases`). Add the name to its `aliases`, as the message prints, or bind the consumer to it with `deps.<name> = ref.<ns>.<inst>` |
| Build fails with `[validate] Duplicate resource: <kind>/<ns>/<name>` | Two different resources share an identity; the writer would keep one and drop the other. Declare one shared instance, or give the resources different names |
| Build fails with `kix: cluster-scoped <Kind> <name> is rendered by 2 instances` | Two instances render the same cluster-scoped object, such as an operator's CRDs or ClusterRoles, or an IngressClass. Common cause: an operator auto-instantiated once per environment because its package is not marked one per cluster. Declare one shared instance |
| Helm-chart resources lack DI edges to other charts | Helm opacity warning. The `helm-dag.nix` reconstructs intra-chart edges from K8s patterns (SA mounts, RBAC bindings, Service selectors, etc.); cross-chart edges require explicit `requires` |

## 28. References

| Topic | File |
|---|---|
| Internals + non-obvious patterns | `kix/lib/architecture.md` |
| CLI architecture & module map | `cli/README.md` |
| Durable principles | `PRINCIPLES.md` |
| LLM best-practices guide | `docs-legacy/BEST-PRACTICES.md` |
| Breadth-first feature inventory | `docs-legacy/FEATURE-CATALOG.md` |
| Migration playbook | `.claude/skills/kix-migration/SKILL.md` |
| Secrets deep-dive | `.claude/skills/kix-migration/SECRETS.md` |
| Storage deep-dive | `.claude/skills/kix-migration/STORAGE.md` |
| Multi-component packages deep-dive | `.claude/skills/kix-migration/MULTI_COMPONENT.md` |
| Live status / open questions | `ROADMAP.md` |
| Project rules | `CLAUDE.md` |

**Canonical examples:**

| Pattern | Reference |
|---|---|
| Native single-Deployment package (RBAC, leader election, guarded `extraArgs`/`env`, `out` transformer, `kix.monitor`) | `kix/packages/reloader/` |
| `kix.storage.mkClasses` over a typed map of classes | `kix/packages/storage-classes/` |
| First-class PVC instance | `kix/packages/persistent-volume-claim/` |
| Image reference read from a committed pin file, and an instance pin no code reads | `clusters/test-pins.nix` + `clusters/pins.json` |
| Mid-complexity with DI storage, expose, monitor, mounts, `kix.mergeEnv` owned groups, an optional dependency with a version check | `kix/packages/immich/` |
| Complex multi-component | `kix/packages/harbor/` |
| Helm-wrapped capability owner | `kix/packages/cilium/` (chart, HelmChartConfig, or environment delivery) |
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
`--set` and no `--values`; §9.5 of BEST-PRACTICES explains why one would not
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

`note` is for whoever reads the file. Kix never reads it, and it survives
a rewrite, which is what a comment could not promise. It does not reach the
image option either, so it cannot affect a manifest. It describes the image
it was written for, so `kix pin set` drops it when it moves the entry to
another image, and says so; pass `--note` to write a new one.

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

### 29.2a Instance pins: no code reads them

An `images` pin needs a line of code to reach an option. An instance pin
needs none. It lives under `instances`, keyed by instance and then by option
path, and `kix.buildCluster` applies it to that option when the file is passed
as `pins`:

```json
{
  "version": 2,
  "managedBy": "kix pin",
  "images": {},
  "instances": {
    "monitoring/grafana": {
      "image": { "repository": "docker.io/grafana/grafana", "tag": "13.1.3", "digest": "sha256:…" }
    }
  }
}
```

```nix
{ kix, pins, ... }:
kix.buildCluster { name = "prod"; inherit pins; modules = [ ... ]; }
```

The entry is one more definition of `instances.monitoring.grafana.config.image`,
from a module whose file is the pin file, so pinning a package default is
adding an entry and returning to the default is deleting it. A pin and a
definition in code at the pin's priority or above is an evaluation error
naming both; a pin wins over a `lib.mkDefault` in code and over the package's
own defaults, so a follower image can be pinned (pin every image of a
release: pinning only the main one drops the followers' digests). A pin
states its digest, so one without a digest never keeps the package's. Pin
repositories and tags follow the OCI reference grammar in both readers. A
file with instance pins belongs to one cluster, since a pin for an instance
the cluster lacks is an error. So is a pin for an instance the cluster lacks, an import, an
option the package lacks, or an option that is not a `kix.options.image`
option.

A file with `instances` declares `version: 2`. One without stays version 1, so
a Kix that reads only version 1 keeps reading it, and refuses a version 2
file by name rather than ignoring its instance pins.

`kix pin set monitoring/grafana --tag 13.1.4` moves one; `--option
sidecar.image` names another option. A new instance pin needs `--repository`
and no `--init`. Implementation: `kix/lib/eval/instance-pins.nix`.

**Image sources.** Every cluster build result holds `kix-image-sources.json`
beside the Activation: for each image option of each active instance, the
value, the package's default, and its origin (`pin`, `package_default`,
`injected`, `nix_built`, or `code`), with the pin key, the dependency, or the
file and line. It is outside the Activation, so it never changes its name.
Its shape is in the docs site's image and pin helpers reference.

Every file it names is a path in the flake whose clusters these are: `mkFlake`
knows that flake, and `lib.forPkgs` is told with `self`
(`kixpkgs.lib.forPkgs { inherit pkgs lib self; }`). A pin file from another
flake input is in no path of this repository, so `pinsFile` is null and
`pinsFileUnknown` says why: `outside_flake`, or `flake_unknown` when
`forPkgs` was not given `self`. A tool that edits pins then has nothing to
edit.

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
  succeeds, every rule passes, `kix plan` accepts it, the receipt is
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
