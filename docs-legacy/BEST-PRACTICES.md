# kix Best Practices

Durable guidance for AI agents working on kix packages, clusters, and library
code. Principle → consequence → concrete example. Companion to
[`HANDBOOK.md`](HANDBOOK.md) (mechanics) and [`FEATURE-CATALOG.md`](FEATURE-CATALOG.md)
(API inventory).

> **Read this first when something feels ambiguous.** The mechanical answer
> usually lives in HANDBOOK; the *judgment* answer is here.

## Contents

1. [What kix is](#1-what-kix-is)
2. [The three personas](#2-the-three-personas)
3. [The graph is the model](#3-the-graph-is-the-model)
4. [Compile-time correctness](#4-compile-time-correctness)
5. [K8s superset, never substitute](#5-k8s-superset-never-substitute)
6. [DSL design rules](#6-dsl-design-rules)
7. [`out` is the public surface](#7-out-is-the-public-surface)
8. [Workloads are explicit; everything else is DI'd](#8-workloads-are-explicit-everything-else-is-did)
9. [Operational principles](#9-operational-principles)
10. [AI as multiplier on typed surfaces](#10-ai-as-multiplier-on-typed-surfaces)
11. [Migration mindset](#11-migration-mindset)
12. [Anti-patterns](#12-anti-patterns)
13. [When to update what](#13-when-to-update-what)

---

## 1. What kix is

A Nix-based Kubernetes manifest generator that treats **the dependency graph as
the source of truth**. Every cluster is a closure-complete derivation rooted at
an `Activation` CR; the Nix store is its IR. Same inputs → same closure → same
cluster.

Mental model:

- **Packages** (`kix/packages/`) are Nix functions that produce K8s resources.
- **Clusters** (`clusters/`, `ludo/`, `nw1/`) are NixOS-style modules that wire packages together.
- **Resources** are content-addressed store paths. Their string context carries DAG edges.
- **DI**, **netpol**, **RBAC**, **monitoring**, **scorecard**, and **deploy ordering** are all derived from that DAG.

## 2. The three personas

Every API decision should pick exactly one persona to speak to. The wrong
persona's concerns leaking into a package is the most common smell.

| Persona | Owns | Cares about |
|---|---|---|
| **App maintainer** | Workload shape — what the app needs (Postgres, this exact storage shape, this many replicas) | Correctness of *their* app; agnostic to which cluster it runs on |
| **Platform team** | Wires services and capabilities into a cluster (which Postgres, which ingress controller, which storage class) | Consistency across apps; capability ownership |
| **Cluster operator (SRE)** | Hardware, distribution choice, infra realities (which flavor, which CNI, capability flags) | Operational truth; network policy enforcement; day-2 |

**Rule:** A package author is explicit about *what* they need; *which*
implementation provides it is a DI concern resolved by the cluster.

| Smell | Why it's wrong |
|---|---|
| App package hardcoding `storageClassName = "gp3"` | Belongs to platform/operator. Use `storage` DI dep. |
| Cluster definition writing K8s resources inline | Belongs to a package. Make a package. |
| Package's `meta` field used to plumb a service to another package | DI is the channel for plumbing. `meta` is for kix-concerns hints. |
| Flavor sets per-app config | Flavors set capabilities and platform imports. Per-app config is platform/cluster. |

## 3. The graph is the model

Wiring, ordering, RBAC, network policy, monitoring, backup — *everything* is
derived from the DAG or hooks into it.

### 3.1 Store-path = DAG edge

Resources never declare deps explicitly via opaque strings. `mkResource` parses
Nix string context on the manifest JSON and stamps `kix.run/depends-on`
annotations. The CLI walks the store DAG (rooted at the Activation CR) to order
deploys. Read `kix/lib/architecture.md` for details.

**Consequence:** any time you reach for a resource's name, fqdn, or selector,
prefer the form that carries context (`self.x.out.name`, not the manifest-
visible string).

### 3.2 New features model on the graph first

Before designing a new feature, ask: "What does this look like as a *graph*
question?" If it doesn't, you're probably reinventing a side-channel.

| Cross-cutting concern | Graph mechanism |
|---|---|
| Deploy order | Store-path edges → `kix-streamed scheduler` |
| Network policy | Same edges → `netpol.nix` derives CNPs |
| RBAC | SA → Binding walk over the same graph |
| Monitoring | DI dep → `kix.monitor` build entry |
| Capability ownership | Raw-PVC eval error + `meta.unsafe` grants; `meta.annotationDomains` + DI-edge lint |
| GC | Diff old vs new activation closures |
| Drift detection | Identity-hash compare against live state |

If your feature looks like none of the above, write a v2 discussion doc before
you write code.

## 4. Compile-time correctness

The system's core promise: **forbid at eval-time what runtime would otherwise
have to detect**. If the type system can rule it out, no admission webhook, no
reconciler, and no runbook should need to.

### 4.1 What kix already makes unrepresentable

| Class of mistake | Mechanism |
|---|---|
| Mismatched selector vs template labels | `mkDeployment` etc. copy `spec.selector.matchLabels` to `template.metadata.labels` |
| Dangling resource refs | All refs are Nix-typed; `null` resources are stripped, not silently dropped |
| Meaningful empty value deleted (`emptyDir: {}`, empty selectors) | Collapse-rule normalization: literal empties render; only containers that lost every member to null-stripping collapse. `kix.keep` protects constructor-built containers |
| Sourceless volume shipped to the apiserver | `volumeHasSource` scorecard rule (severity error) checks volumes as they will render |
| Missing deps | DI resolution errors with an actionable message |
| Cross-namespace mounts/secret-refs | `_kix.namespace` markers + `checkNamespacedRefs` |
| `extra.*` shadowing managed fields | `mkResource` `_extraShadowCheck` |
| TLS secret in wrong namespace | `kix.expose` cross-ns check |
| Unknown `_kix.*` typo | `stripKixMeta` whitelist |
| Untracked secret-name string | `mkDeployment` requires DI tracking; `kix.untrackedRef` is the only escape hatch |
| Volume name collision | `kix.withMounts` `_dupeCheck` |
| Selector references unnamed container port | `kix.service.fromWorkload` validates against workload's container ports |
| Both `gateway` and `ingressNginx` wired | `kix.expose` errors at build time |
| Unknown extension/option | NixOS module system errors |

### 4.2 Bar for adding new compile-time checks

Add an eval-time check when:

- The mistake would otherwise become a runtime failure (silently or with a confusing error).
- The check has a clear, actionable error message that names the resource and tells the user how to fix it.

Don't add a check when:

- The condition is statistical or heuristic (false positives erode trust).
- Detecting the mistake at deploy time gives the user a better experience (e.g. import-presence checks belong in the deploy CLI, not eval).

Errors point at the *source*, name the *constraint*, and tell the user what to *change*. Silent failure and runtime-only discovery are bugs.

## 5. K8s superset, never substitute

Our abstractions sit on top of K8s; they never prevent users from dropping down
to raw resources.

### 5.1 Don't invent new fields

If a kix-only spec key would do the same job as a standard K8s field, use the
standard field. Compatibility with the rest of the K8s ecosystem (kubectl,
operators, dashboards, security tools) is a feature.

| Avoid | Use |
|---|---|
| `kix.someStorageClass = "gold"` | `spec.storageClassName = "gold"` |
| Custom RBAC abstraction | The RBAC DSL outputs real `Role`/`ClusterRole` |
| New `kix.exposure` schema | `Ingress` or `HTTPRoute` |
| kix-only annotation for SemVer | Standard `app.kubernetes.io/version` |

The annotations kix *does* add (`kix.run/identity-hash`, `kix.run/depends-on`,
`kix.run/mode`) are about kix-internal bookkeeping, never
about expressing K8s intent.

### 5.2 Standard K8s vocabulary over invented vocabulary

Reuse K8s concepts (`IngressClass`, `loadBalancerClass`, `StorageClass`, `RuntimeClass`)
before introducing kix-only ones.

### 5.3 Always-available escape hatches

If someone needs a field, annotation, or kind kix hasn't modeled, they reach
for it directly without leaving kix:

- `extra = { ... }` for top-level passthrough fields kix doesn't model.
- `kix.untrackedRef "name"` for resource names not managed by kix.
- `scope.mkResource` to author any K8s manifest that the convenience builders
  don't cover.
- `partsOverlays` for instance-level post-build transforms.

If the escape hatch is the only way to express something common, that's a
signal to upstream the pattern.

## 6. DSL design rules

### 6.1 Automation over brevity

DSL features exist to **prevent mistakes**, not to save lines.

> If a shorter form removes a safety net, the longer form wins.

`mkDeployment` is verbose because it copies selector to template labels — that
verbosity is the safety net. Don't introduce a "compact" form that skips it.

The same principle runs the other way for availability and placement. A
package does not decide how many replicas a cluster wants, and does not
write `topologySpreadConstraints` or pod anti-affinity. It receives the
cluster's availability level as its `availability` argument and maps it in
every replica-shaped default (`kix.availability.pick availability { none =
1; pod = 2; node = 2; zone = 3; }`), and the compiler derives spread across
the cluster's failure-domain keys plus a PodDisruptionBudget from the
replica count (`cluster.availability`, v2_discussions/145). The package
cannot know what a failure zone is on the cluster it lands on, and a literal
`topologyKey` or a literal `3` is a guess. The level and the per-instance
override belong to the cluster operator (`instances.<ns>.<inst>.availability`).
A package that cannot reach a level says so with `meta.availability.max` and
a reason. Write placement by hand only for a rule the derivation cannot
express (a quorum that must never co-locate).

### 6.2 Resources are rich objects

Consumers query the resource directly through `out`:

```nix
# Right
env = { DB_HOST = postgres.out.fqdn; DB_NAME = postgres.out.database; };
sm  = prometheus.out.mkServiceMonitor scope { ... };
ing = svc |> clusterIssuer.out.withCert |> scope.mkResource;

# Wrong
env = { DB_HOST = "postgres.${ns}.svc.cluster.local"; ... };       # no DAG edge, no FQDN context
sm  = scope.mkResource { kind = "ServiceMonitor"; ... };            # bypasses capability owner
ing = svc |> manualWithCertHelper |> scope.mkResource;              # inverts the DI direction
```

`out` shapes:

| Shape | When |
|---|---|
| **Plain value** (`storageClasses.out.storageClassName`) | Single field consumer needs |
| **Transformer** (`clusterIssuer.out.withCert`, takes a resource → returns a transformed resource) | Fields the consumer would forget (e.g. cert-manager annotations) |
| **Builder** (`prometheus.out.mkServiceMonitor scope { ... }`) | Creating CRD instances on behalf of the consumer |

Builders take `scope` so the result lands in the consumer's namespace with the
consumer's labels. Transformers don't.

When hand-building a ServiceMonitor (rather than using `kix.monitor`), source
the selector from the **Service's** labels — `self.service.out.selector` —
never from the workload's pod selector. Monitor selectors match Service
metadata labels; a pod-shaped selector drops every target at relabeling and
the job silently vanishes from `up`. The
`architecture.monitorSelectorMatchesService` scorecard rule enforces this at
build time (it caught four shipped instances the day it was written).

Caveat: this is the **single-Service** idiom. A Service's `out.selector` is
its metadata labels, which are instance-common — in a package with two
Services (main + headless is the classic shape) it matches both, and each pod
gets scraped once per Service. Multi-Service packages need a per-Service
discriminator (explicit `labels` on the Service, selected explicitly); a
first-class `kix.run/part` identity label is an open design question in
ROADMAP.

### 6.3 Wiring (DI) > module system > meta

Reach for these in order:

1. **DI** — the right channel for "package A consumes package B's service / data / capability". DI is the *plumbing*.
2. **Module system** — the right channel for shared structure across instances (config types, defaults, options, instance-level config-injection from deps).
3. **`meta`** — the right channel for kix-concerns *hints* (statefulness, importance, consistency class, version, conflicts, capability ownership) that drive in-kix auto-wiring of cross-cutting concerns.

**`meta` is never the channel for plumbing services together.** If you find
yourself adding a `meta.connectsTo = "..."` field, you wanted DI.

### 6.4 No design for hypothetical futures

Concrete drivers gate new primitives. Three similar lines beats a premature
abstraction; "this might be useful one day" doesn't ship.

> Wait for the third caller before you abstract.

### 6.5 Override existing instances; don't re-expose their config

When a shared module (e.g. `kix.modules.monitoring`) already declares an
instance, and your cluster needs to tweak its package config, **merge into
the instance directly** rather than adding a new module option that just
forwards to the package. The `instances.<ns>.<name>.config` field is a
`deferredModule` (`kix/lib/modules.nix`), so multiple modules contribute
config to the same instance and the module system merges them — with full
`mkDefault` / `mkForce` priority semantics.

```nix
modules = [
  kix.modules.monitoring
  { monitoring.enabled = true; monitoring.loki.enabled = true; }

  # Pure override module — merges into the loki instance the monitoring
  # module already declared in the monitoring-loki namespace.
  ({ config, ... }: {
    instances.${config.monitoring.loki.namespace}.loki.config = {
      values = {
        # whatever loki package config you want to merge in
        loki.limits_config.retention_period = "168h";
      };
    };
  })
];
```

Two safety properties to lean on:

- **Don't re-set `package`.** It's `types.raw`; a duplicate definition
  errors. Override-only modules touch `config` (and `aliases` / `deps` /
  `partsOverlays` if needed), nothing else.
- **Reference the upstream namespace through its option** (e.g.
  `config.monitoring.loki.namespace`) instead of hardcoding the string —
  if the upstream module renames the namespace, your override follows.
  A typo'd namespace creates a fresh instance with no `package`, which
  fails eval with a clear "option ... is used but not defined" error
  rather than silently spawning a duplicate.

This pattern applies anywhere a shared module owns instances: don't widen
its option surface to plumb every package knob through. Override the
instance directly.

### 6.6 Override mechanisms — pick the narrowest

`config` (§6.5) is the right knob 90% of the time. When it isn't enough,
the instance submodule (`kix/lib/modules.nix`) and `mkResource`
(`kix/lib/k8s.nix`) expose a layered set of override channels — each
operating at a different stage of the build pipeline. **Prefer the
narrowest one that does the job**, so the override stays as close as
possible to the field it actually changes.

Rule of thumb:

> Reach for `partsOverlays` only when the package didn't expose a `config`
> knob. Reach for `selectorLabels` / `labelStyle` only for parity with
> pre-existing cluster state.

**Per-instance channels** (`instances.<ns>.<name>.<channel>`):

| Channel | Type | When |
|---|---|---|
| `config` | `deferredModule` | Tweak typed package options. Module-merged across contributors. |
| `deps` | `attrsOf anything` | Force a specific DI provider for one build arg. Two modules setting the same dep = error. |
| `aliases` | `listOf str` | Set DI resolution keys for this instance. When non-empty, **replaces** the package's `meta.defaultAliases`; when empty, defaults apply. Not the right tool for multi-instance disambiguation — see §8.4. |
| `labelStyle` | `enum { kix, helm }` | Switch label scheme — for byte-level Helm parity (e.g. when `releaseName` is set). |
| `selectorLabels` | `attrsOf str` | Override auto-generated selector labels. Escape hatch for *immutable* selectors on pre-existing StatefulSets. |
| `partsOverlays` | `listOf (scope → self → base → attrset)` | Post-build resource transforms. Run after the package's `build` inside the same fixpoint — full access to `scope`. Can rewrite `root`, extend `out` with builders, add parts. Multiple modules concatenate. |
| `extraDeps` | `listOf raw` | Inject DAG edges not visible via Nix string context (e.g. "import depends on a managed root"). |
| `optional` | `bool` | Pre-configure but only deploy if a non-optional instance transitively depends on this. |

**Cluster-level channels:**

| Channel | When |
|---|---|
| `globalPartsOverlays` | Apply a `partsOverlay`-shaped transform to **every** instance (overlay inspects `base` to decide whether to act). |
| `availablePackages` + `autoNamespace` | Register packages for auto-instantiation when DI resolution would otherwise fail. |

**Inside a single resource** (`scope.mkResource` and friends):

| Channel | When |
|---|---|
| `extra = { ... }` | Passthrough for unmodeled K8s fields. `_extraShadowCheck` errors at build time if `extra.*` would shadow a kix-managed field — safe to use freely. |
| `requires` | Explicit forward DAG edges for label-only references (where no other field carries the store-path context). |
| `postHooks` | Resources that must apply *after* this one (stamps `kix.run/post-hooks`). |

#### Concrete example: `partsOverlays` to expose CRD builders

`partsOverlays` is the most powerful escape hatch — runs after the
package's `build` returns, inside the same fixpoint, with full access to
`scope`. Use it when a Helm-wrapped or upstream package doesn't expose
`out.*` builders the consumer needs:

```nix
# clusters/test-monitoring-helm.nix
instances.monitoring-system.kube-prometheus-stack = {
  package = packages.kube-prometheus-stack;
  partsOverlays = [
    (scope: self: base: {
      root = base.root // {
        out = (base.root.out or { }) // {
          mkServiceMonitor = (scope.mkCRDRef {
            group = "monitoring.coreos.com";
            kind = "ServiceMonitor";
            plural = "servicemonitors";
          }).out.mkCR;
        };
      };
    })
  ];
};
```

If a `partsOverlay` becomes a copy-pasted pattern across clusters, that's
a signal to upstream it into the package's own `out` (§7.2).

### 6.7 Don't add half-finished features

Bug fixes don't need surrounding cleanup; one-shot operations don't need helpers.
Eliminate dead code and stale comments — don't leave `// removed for X` or rename
unused vars to `_x`.

## 7. `out` is the public surface

A resource's `out.*` is what consumers read. `name`, `fqdn`, `selector`,
`identityHash` are auto-derived and context-carrying; user `outputs = {...}`
extend them.

### 7.1 Always prefer `out` over string interpolation

```nix
# Right
env = kix.mkEnvVars { DB_HOST = postgres.out.fqdn; };
selector.matchLabels = workload.out.selector;

# Wrong
env = kix.mkEnvVars { DB_HOST = "${postgres}"; };       # store path string — invalid as DNS name
selector.matchLabels = workload.spec.selector.matchLabels;   # bypasses context
```

The `out.*` form is a **real K8s name** (or selector, or fqdn) carrying the
resource's store-path context. Nix's string-context system preserves the edge
even though the visible string is the human-readable name.

### 7.2 When to define custom `outputs`

Add named outputs in `mkResource` when:

- The consumer needs a value that isn't `name`/`fqdn`/`selector`/`identityHash` (e.g. a port, a database name, an issuer ARN).
- A capability owner exposes builders/transformers (`out.withCert`, `out.mkServiceMonitor`).

Setting an output to `null` *suppresses* the auto-derived field — useful when
"this resource has no FQDN" is the truthful statement.

### 7.3 `rawSelector` is a cycle escape hatch

Workloads expose `workload.rawSelector` — `spec.selector.matchLabels` without
the workload's store-path context. Use only when reading `out.selector` would
create a cycle (e.g. ingress-nginx's `--publish-service` constraint, where the
Deployment requires its own Service to exist first).

The consumer loses the workload DAG edge, so
`scorecard:architecture.selectorCoherence` fires to keep the workaround
visible. Don't suppress the warning — the visibility is the point.

## 8. Workloads are explicit; everything else is DI'd

A package author is explicit about *what* they need (Postgres, not "a
database"; this exact storage shape). *Which* implementation provides it is a
DI concern resolved by the cluster.

### 8.1 What goes on the build args

Build args declare DI deps. Required deps have no default; optional deps get `? null`:

```nix
build = { self, config, postgres, storage, machineLearning ? null, prometheus ? null, ... }: { ... };
```

`postgres` and `storage` are required: the package can't function without them.
`machineLearning` and `prometheus` are optional capabilities — the package
gracefully omits resources when they're absent.

### 8.2 What goes on `meta.roles`

Infrastructure-role owners claim their role from the closed registry in
`kix/lib/eval/roles.nix` (currently: `network-policy-enforcer`, `dns`,
`storageClasses`, `cni`, `loadBalancer`):

```nix
# kix/packages/storage-classes/default.nix
meta = {
  roles = [ "storageClasses" ];
};
```

The role name doubles as a DI alias automatically, and binding-mode
conflicts against environment-provided roles (`cluster.roles.<name>.binding`,
`absent` | `shadowable` | `exclusive`) are refused at eval. Everything that
isn't a registry role resolves through ordinary aliases — e.g.
`persistent-volume-claim` declares `meta.defaultAliases = [ "storage" ]`.

Consumers' DI resolution matches by arg name → instance name → instance
aliases (when set) **or** package's `meta.defaultAliases` (when not set —
instance aliases *replace* package defaults, they don't merge). Capability
ownership is enforced by declared invariants, not provenance stamps
(v2_discussions/128): raw PVCs are an eval error unless the package holds
`meta.unsafe = [ "raw-pvc" ]`, and annotations under an operator-declared
domain (`meta.annotationDomains`) without a DI dep on the declarer trip
`architecture.annotationDomainOwnership`.

### 8.3 What does NOT go on `meta.roles`

The registry is closed on purpose: the old free-form `meta.provides` let a
typo'd capability silently never match, so it was removed
(v2_discussions/127). An unknown role is an eval error, and adding a role
to the registry requires a demonstrated consumer.

Services that other packages consume (a database, a cache, a metrics
backend) are not roles — they resolve via plain alias-based DI
(`meta.defaultAliases`, instance names, instance aliases).

### 8.4 Disambiguating multi-instance providers

When a cluster runs **multiple instances of the same package** (three
ingress-nginx controllers, two stackgres-cluster fleets, etc.) and a
consumer needs a *specific* one, wire the dep explicitly at the consumer
site:

```nix
# clusters/<name>.nix or services.nix
{ ref, ... }: {
  instances.harbor-system.harbor = {
    package = packages.harbor;
    deps.ingressNginx = ref.nginx-system."private-v2";
    config = { ... };
  };
}
```

`ref` is the cluster fixpoint, exposed via `specialArgs` to every
cluster module. `ref.<namespace>.<instanceName>` is a lazy reference
that resolves to the same value DI auto-resolution would produce —
short-circuiting alias-based discovery entirely.

**Aliases are not the right tool here.** It's tempting to disambiguate
by giving each instance a unique alias (`ingressNginxPublic`,
`ingressNginxPrivate`, etc.) and letting auto-resolution pick the right
one. That ties the consumer's wiring to whichever instance happens to
keep the package's bare default alias — coupling-by-side-effect. Use
`deps.<argName> = ref.<ns>.<inst>` instead; it makes the dependency
graph legible from the consumer site.

**Phase-1 caveat (current limitation).** kix runs a phase-1 dep
pre-pass (config injection / DAG seeding) with `explicitOverrides = {}`
deliberately, to avoid `ref`-fixpoint recursion. If DNS-based
auto-resolution is *ambiguous* in phase-1 (multiple candidates with the
same alias), eval throws before any consumer's explicit override
applies. Until that's lifted, multi-instance clusters need at least
one of the instances to claim a unique alias so phase-1 has a single
match — the consumer's explicit `deps` then takes over for the actual
build:

```nix
instances.nginx-system = {
  public        = { package = packages.ingress-nginx; aliases = [ "ingressNginxLegacyPublic" ]; ... };
  public-v2     = { package = packages.ingress-nginx; aliases = [ "ingressNginxPublic" ];       ... };
  private-v2    = { package = packages.ingress-nginx;                                            ... };  # keeps default `ingressNginx`
};
```

The aliases here are phase-1 plumbing, not load-bearing intent — the
consumer's `deps.ingressNginx = ref.nginx-system."private-v2"` is what
documents the wiring. Once the phase-1 limitation is addressed, the
aliases can be dropped.

## 9. Operational principles

### 9.1 Day-2 is where the value lives

Day-1 deploys are table stakes. Upgrades, drift, restore, capacity, migration —
these are first-class, not afterthoughts.

When designing a new feature, ask: how does this look in week 2? Year 2?

| Day-2 concern | Where it lives |
|---|---|
| Drift detection | `kix health` — identity-hash compare |
| Stale-resource cleanup | `kix gc` (soft + hard) |
| Rollback | `kix rollback` — superseded Activation CRs |
| Migration safety (PVC deletion, etc.) | `meta.lifecycle = "stateful"` + diff protection |
| Capacity hints | `cluster.nodes`, scorecard reliability rules |
| Compliance evidence | `kix sbom`, `kix attest`, `kix audit` |

### 9.2 Compliance evidence is a build output, not a post-hoc scan

SBOM, SLSA provenance, SARIF, OSCAL audit bundles emerge from compilation
because the graph already knows. Don't push compliance into a separate tool
chain.

### 9.3 Diff belongs in the planner, not the executor

Plan / Transition / Verdict primitives with structured readiness — not
wall-clock timeouts and retries. The deploy CLI ships a graph-streaming
scheduler; each node becomes eligible the moment its predecessors emit
`Verdict::Ready`.

When something looks like "wait N seconds and hope" — design the structured
verdict instead.

### 9.4 A value that varies per deploy is committed, not injected

Something outside the compilation unit sometimes decides an input to it. A CI
build finishes and produces an image tag. A person decides that this build is
the one that goes to production. Kix has one channel for such a value, and it
is the same channel as every other value: the definition, in the repository.

There is no `--set`, no `--values` and no `--var`, and adding one would not
work even if we wanted it. Change detection indexes the previous build's
manifests by Kubernetes identity and seals those hashes before the CLI could
patch anything, so a value injected after evaluation never reaches the
comparison and the second deploy is a silent no-op. It would also make
`kix compliance attest` emit a well-formed false statement, and a false
attestation is worse than no attestation.

So the value is written down first and deployed second:

```nix
# flake.nix names the pin file once
inputs.kix.lib.mkFlake { inherit inputs; pins = ./pins.json; clusters = { ... }; }

# and no cluster definition repeats the path
{ kix, pins, ... }:
{
  instances.app.web.config.image = pins.get "web";
}
```

`kix pin set web --tag v1.2.3` asks the registry what that tag resolves to,
refuses a tag that is not there, and rewrites `pins.json` with the repository,
the tag and the digest. Promotion is then an ordinary commit, which means the
repository can always answer what is deployed, a clean checkout deploys
something real, and both a person and a CI job promote the same way.

Three properties are worth stating because they are easy to lose:

- **Record the digest, not only the tag.** A tag can be moved after it is
  read. Every serious tool in this space landed on the same answer: Flux
  rewrites the file with a commit, Kargo promotes an immutable object naming
  resolved digests, and Argo CD's own Image Updater documentation warns that
  its cluster-only write-back is lost when the Application is recreated.
- **JSON, not Nix.** Reading a Nix file means evaluating it, so a pin file in
  Nix executes whatever it contains when Kix reads it, and writing one means
  hand-escaping registry-supplied strings into a programming language. Neither
  belongs in a file a bot rewrites every build. The evaluation cache
  fingerprints `.json` alongside `.nix`, so nothing is lost by it.
- **Give the tag a stream, not a build.** `main`, not `sha-<commit>`. A tag
  that moves per build leaves the file no stable key and pushes CI into
  editing the cluster definition, which is what a pin file exists to prevent.
- **Build, promote and deploy in one job.** The digest is an output of the
  build, so the deploy depends on it. Two workflows joined by a commit turn
  that dependency into a trigger, and triggers form cycles. One job, with the
  image build conditional on the source having changed, converges instead.
- **Kix never resolves a tag at apply time.** A `digest: null` that tells the
  truth is worth more than a value fetched over the network during a deploy,
  which nobody could review before it was applied.

## 10. AI as multiplier on typed surfaces

Agents compound on validated APIs and structured diagnostics; they hallucinate
on YAML.

**Implication for API design:**

- Functions take named args, not positional ones.
- Errors include the resource id, the constraint, and the fix.
- Outputs are structured (`outputs = { ... }`) rather than name-based magic.
- Diagnostics are typed (assertions/warnings) and surfaced as kix-native diagnostics, not opaque trace lines.
- The same APIs available to humans are available to agents — no separate "agent mode".

When you're tempted to fix something "with a comment that explains the
gotcha," fix it at the type level instead. A trace warning can vanish in a
crowded log; a build-time error can't.

## 11. Migration mindset

When migrating from Helm or Ansible: **don't blindly transliterate**. Patterns
that look right in the source are often wrong in kix.

| Source pattern | What it is | Kix equivalent |
|---|---|---|
| Helm release-name prefixing (`{{ .Release.Name }}-foo`) | Helm prepends release names everywhere | `scope.instanceName` is already the prefix; don't double-prefix |
| Ansible imperative ordering | Tasks run in order | Reference what you depend on; the DAG handles ordering |
| Helm `values.yaml` layering | Complex multi-file merge | Typed `lib.mkOption` defaults; cluster-level `config` deep-merged via NixOS modules |
| Ansible `when:` conditionals | Per-task gates | `lib.optionalAttrs` / `lib.optional` / `if/then/else` returning `null` (collectTypedAttrs strips nulls) |
| Helm `_helpers.tpl` | Shared template snippets | `let`-bindings in Nix |
| Multiple instances of the same service | Duplicate manifests | One package; instantiate multiple times in the cluster definition with different configs |
| Ansible `with_items` / `loop` | Generate N tasks | `lib.mapAttrs` or `map` over a config attrset |
| Helm chart's hardcoded selector | Template guarantees match | `scope.selectorLabels`; don't hand-roll selectors |

### 11.1 Workflow

1. **Read the source first.** Understand what resources the role/chart creates and why.
2. **Read the cluster dump.** It's the ground truth — what's actually running may diverge from the source.
3. **Match the cluster dump.** When source and dump disagree, the dump wins (with a note about the discrepancy).
4. **Start rough, diff, iterate.** Write a first pass, build, diff, fix the **Modified** section.
5. **Don't over-specify.** K8s defaults (e.g. `strategy: RollingUpdate`) are stripped automatically by the diff tool.
6. **Cluster-only resources are usually fine.** Operator CRDs, auto-generated secrets, system pods — focus on **Modified**, not `cluster-only`.

Detailed playbook: `.claude/skills/kix-migration/SKILL.md`.

## 12. Anti-patterns

Concrete things that look right but aren't.

### 12.1 Reading back through `"${self.x}"` for names

```nix
# Wrong
env = { DB_HOST = "${postgres}"; };  # store path → not a valid K8s host

# Right
env = { DB_HOST = postgres.out.fqdn; };
```

`"${resource}"` evaluates to the store path. Use it only when you genuinely
want the store path (you almost never do). For names, fqdns, and selectors,
use `out.*`.

### 12.2 Hand-rolling resources that belong to a capability owner

```nix
# Wrong — package emits its own PVC
pvc = scope.mkResource { kind = "PersistentVolumeClaim"; ... };

# Right — declare DI dep, consume the capability
build = { storage, ... }: {
  dataMount = kix.mount.pvc storage { mountPath = "/data"; };
};
```

Consumers should ask for *what* they need (`storage`), not produce *which*
implementation. The architecture scorecard rule catches this.

### 12.3 Bypassing `scope.mkSecret` / `mkSecretRef`

```nix
# Wrong
secret = scope.mkResource { kind = "Secret"; stringData = { ... }; };

# Right
secret = scope.mkSecret { name = "..."; stringData = { ... }; };
```

`scope.mkSecret` adds the enriched `out.{keyRef, mkEnv, envFrom, volume}` API
with build-time key validation and dependency tracking. Raw `mkResource` for a
Secret loses that.

### 12.4 Adding `requires` for things already reached via string interpolation

```nix
# Wrong — redundant; trace warning fires
service = scope.mkResource {
  spec.selector = self.deployment.out.selector;   # already gives us the edge
  requires = [ self.deployment ];
};

# Right
service = scope.mkResource {
  spec.selector = self.deployment.out.selector;
};
```

`requires` is only for edges *not* visible via string interpolation — typically
label-only references where the consumer reads selector labels but doesn't
interpolate any other field.

### 12.5 Splitting a multi-component app across packages

Harbor has core, portal, registry, jobservice, exporter, redis, postgres. They
share config, secrets, and internal URLs. **One package**, not seven. See
`MULTI_COMPONENT.md`.

The exception: when a sub-component is independently reusable (Harbor's
postgres → kix's `stackgres-cluster`; Harbor's redis → kix's `valkey`). Then
it's a DI dep, not a sub-component.

### 12.6 Forgetting `rawSelector` exists

When `out.selector` cycles, the answer isn't to push the cycle into runtime —
it's `rawSelector`. Live with the `architecture.selectorCoherence` warning;
that's the price of the workaround being visible.

### 12.7 Claiming a role when an alias is what you mean

`meta.roles = [ "my-database" ]` is an eval error — the role registry
(`kix/lib/eval/roles.nix`) is closed. Services other packages consume
resolve via arg name → instance name → instance aliases (which *replace*
package `defaultAliases` when non-empty). Roles are only for the registry's
infrastructure slots (network-policy-enforcer, dns, storageClasses, cni,
loadBalancer).

### 12.8 Backwards-compatibility shims

The kix API is in active development. Breaking changes are fine — none of the
clusters are actively deployed. Don't add migration helpers, deprecated
aliases, or compatibility flags unless the user asks.

When you delete a feature, delete it cleanly: no `# removed for X` comments, no
renamed `_unused` variables, no re-exports of obsolete symbols.

### 12.9 Hooking compliance/security into post-hoc scanners

Compliance evidence comes out of the build. SBOM, attestation, audit bundle —
all are kix subcommands that read the closure. Don't introduce a separate scan
step that re-discovers what kix already knows.

### 12.10 "Just write the comment" instead of fixing the type

If a comment explains a non-obvious gotcha, the gotcha probably wants to be a
build-time error. Investigate before settling for a comment.

### 12.11 A committed placeholder

```nix
# Wrong: CI edits this in a working tree at deploy time and never commits it
serverImage.tag = "sha-REPLACE_ME";
```

This is the worst shape a wrong value can take, because everything passes.
`sha-REPLACE_ME` is a valid tag string, so the build succeeds, `noLatestTag`
is satisfied, `kix check` is clean and `kix deploy --dry-run` reports
"configured". The first signal is ImagePullBackOff, in production, minutes
later. Every route that does not go through the CI job that edits the tree,
which is to say every person, every agent and every runbook, deploys a
reference that does not exist.

`security.noUnresolvedPlaceholder` catches the known spellings, and it is a
ratchet rather than a fix: a predicate over spelling cannot tell you that
`sha-typo12` is wrong. What closes the class is §9.4, a resolved digest in a
committed pin file, checked against a registry by `kix pin check`.

## 13. When to update what

| Change | Update |
|---|---|
| New `kix.lib` API or behavior | The relevant `kix/lib/*.nix` file. If the new behavior changes a non-obvious pattern, update `kix/lib/architecture.md`. If it changes user-facing API, update `docs/HANDBOOK.md` (mechanics) and possibly `docs/BEST-PRACTICES.md` (philosophy). Update `docs/FEATURE-CATALOG.md` to keep the inventory current. |
| New CLI command or flag | `cli/README.md` (authoritative). `docs/HANDBOOK.md` §3 (cheat sheet). |
| New cluster-level option | `kix/lib/modules.nix`. `docs/HANDBOOK.md` §14. |
| New flavor | `kix/lib/flavors/`, register in `kix/lib/default.nix`. `docs/HANDBOOK.md` §15 (capability matrix). |
| New scorecard rule | `kix/lib/rules/`, register in `kix/lib/rules/default.nix`. `docs/HANDBOOK.md` §17. |
| New non-obvious pattern (edge case, escape hatch, weird interaction) | `kix/lib/architecture.md` "Non-obvious patterns" section. |
| Migration learning (new pattern that came up while migrating) | `.claude/skills/kix-migration/SKILL.md` — but **ask the user first** before editing. |
| Durable design tenet shifted | `PRINCIPLES.md`, then propagate consequences here. |
| Roadmap item completed | `ROADMAP.md` — mark `[x]`, expand with implementation details. |
| Open design question surfaced during work | `ROADMAP.md` §Open design questions, OR `v2_discussions/interesting_thoughts/` (use `structured-thinking` skill). |
| Project rules for AI agents shifted | `CLAUDE.md`. Don't overload it — it's loaded into every context. |

### 13.1 Two rules to honor outside the `structured-thinking` skill

- **Discussion docs are short.** When a topic needs a new take, start a fresh
  doc — don't extend the old one. Carry forward only the still-active points;
  archive the rest. Target ~400 lines per doc.
- **Archive on ship.** When a feature traces back to a `v2_discussions/` doc
  and lands in code, split shipped content from open questions. Move the doc
  to `archive/`. Lift open questions to `ROADMAP.md` or
  `v2_discussions/interesting_thoughts/`.

### 13.2 Don't proliferate "best practice" docs

This document is the canonical durable-guidance doc for kix. If you need to
write durable guidance, put it here (or a section in HANDBOOK if it's
mechanical). Don't spawn `BEST-PRACTICES-V2.md`, `STYLE-GUIDE.md`,
`COMPONENT-AUTHORING.md` etc. — they will rot independently.

The only exception is the migration sub-topic deep-dives (`SECRETS.md`,
`STORAGE.md`, `MULTI_COMPONENT.md`) which live under `.claude/skills/` because
they're skill-loaded only during migration work.

---

**Source-of-truth dates** (last reconciled with this doc):

```
PRINCIPLES.md                          2026-04-27
kix/lib/architecture.md                2026-04-27
.claude/skills/kix-migration/SKILL.md  2026-04-27
cli/README.md                          2026-04-14
docs/FEATURE-CATALOG.md                2026-04-09
ludo/                                  2026-05-06
ROADMAP.md                             2026-05-06
```

If a principle here disagrees with `PRINCIPLES.md`, **PRINCIPLES.md wins** —
fix this doc.
