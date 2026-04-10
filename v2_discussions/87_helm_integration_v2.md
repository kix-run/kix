# 87: Helm Integration v2 — Helm as a Build Tool, Not a Package Factory

**Status:** Design Doc
**Related:** `86_helm_dag_reconstruction.md`, `40_composite_packages.md`, `82_cilium_package_and_netpol_di_wiring.md`, `83_netpol_via_crdref_and_scope_interception.md`, `29_compiler-design.md`

---

## Problem

`fromHelmChart` grew organically from "import a chart as a quick package" into
the only integration point between Helm and the kix compiler. It now carries
eight structural problems that compound in practice:

### 1. Packages can't be packages

`fromHelmChart` is a **package factory** — it takes chart metadata and returns
a package function. Because it's the factory, it must be called at the cluster
definition level, not inside a package's `build`. Packages like cilium,
reflector, and descheduler are reduced to value bags:

```nix
# kix/packages/cilium/default.nix — not a real package
{
  meta = { ... };
  chart = { repo = "..."; name = "cilium"; version = "1.16.5"; };
  defaultValues = { ... };
  rootOut = { scope, workloads, ... }: { cnpCrdRef = ...; };
}
```

The cluster definition must reassemble the pieces:

```nix
# ludo/cluster-kind.nix — 15+ lines of boilerplate per helm chart
instances.kube-system.cilium = {
  package = kix.fromHelmChart {
    chart = kix.fetchHelmChart {
      inherit (packages."cilium".chart) repo name version;
      hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
    };
    values = packages."cilium".defaultValues;
    releaseName = "cilium";
    includeCrds = true;
    rootSelector = { kind = "DaemonSet"; name = "cilium"; };
    extraMeta = packages."cilium".meta;
    rootOut = packages."cilium".rootOut;
  };
  config.values = { ... };
};
```

Every helm-backed package pays this tax. The package author knows all of this
information but can't act on it.

### 2. rootOut is a kitchen sink

`rootOut` is the only escape hatch for helm packages to expose anything
beyond flat resources. It mixes two fundamentally different things:

- **K8s resources** (CRD markers like `cnpCrdRef`) — must be discovered by
  `collectResources` to enter the plan
- **Builder functions** (like `reflectSecret`) — must be reachable via
  `instance.out` for DI consumers

`fromHelmChart` tries to separate them (line 471: filter by `_type ==
"k8s-resource"`), but the filter is silent. A builder function returned from
`rootOut` is silently dropped from `collectResources` with no warning. The
reflector package works around this by placing the builder on `root.out` and
the marker separately — but this split is undocumented convention, not
enforced API.

### 3. Root selection is fragile

The auto-select heuristic (first Service → first Deployment → first
StatefulSet → first anything) is a guess that fails on:

- Charts with multiple Services (which is "the" root?)
- Charts whose primary resource is a DaemonSet (cilium)
- Charts whose primary resource is a CRD instance (Prometheus CR)

`rootSelector` is the workaround, but it pushes implementation knowledge
(the exact kind+name of the chart's primary resource) into the cluster
definition — knowledge the package author has but the cluster operator
shouldn't need.

### 4. Flat requires model

All non-root resources are peers in `root.requires`. No internal DAG.
Doc 86 describes this in detail: ServiceAccounts that Deployments mount
aren't ordered before the Deployments. ConfigMaps referenced by volume
aren't ordered before the workloads that mount them. Every non-root resource
lands in the same deploy wave.

### 5. Annotation stripping is all-or-nothing

`stripHelmAnnotations` removes everything matching `meta.helm.sh/`,
`helm.sh/`, and `checksum/` prefixes. `stripHelmLabels` removes
`app.kubernetes.io/managed-by` and `helm.sh/chart`. There's no opt-out —
if a chart's controller uses annotations with these prefixes for its own
logic (rare but real), they're silently dropped.

### 6. collectResources silently drops non-resource parts

`rootOutResourceParts` (helm.nix:471) filters to `_type == "k8s-resource"`.
Everything else from `rootOut` is silently excluded from the plan. A package
author who returns a plain attrset or function from `rootOut` gets no error —
their output just vanishes.

### 7. Wave coupling for CRD markers requires insider knowledge

The `workloads` passthrough (helm.nix:425-430) exists solely so cilium can
wire all workloads into `installedBy`. This is an abstraction leak: the
package author must know that the wave engine needs *all* workloads (not just
the root) to guarantee "whole chart ready" before CRs are applied. If cilium
adds a new workload (Hubble UI Deployment, for instance), and the chart
version is bumped without updating `rootOut`, the new workload isn't in
`installedBy` and the wave guarantee silently degrades.

### 8. Workload discovery is hardcoded

`workloadKinds` (helm.nix:425) is `["Deployment" "StatefulSet" "DaemonSet"]`.
Charts using Jobs, CronJobs, or custom workload CRDs aren't included in the
`workloads` list passed to `rootOut`.

---

## Core Insight

`fromHelmChart` conflates two roles:

1. **Package definition** — meta, options, build function structure
2. **Resource import** — running `helm template`, wrapping resources, composing the parts tree

These should be separate. The package definition is the package author's job.
The resource import is a build-time tool the author uses inside their `build`
function — just like `scope.mkDeployment` or `scope.mkResource`.

**The IFD barrier is not real.** The current `fromHelmChart` already runs IFD
inside `build` (helm.nix:314: `builtins.fromJSON (builtins.readFile
templateDrv)`). The helm template derivation depends on chart + values +
namespace — all available inside `build`. The reason packages don't call
`fromHelmChart` themselves is convention, not a technical limitation.

---

## Design

### New primitive: `helm.importChart`

A build-time helper that runs `helm template` via IFD and returns a
**structured resource collection**. Not a package. Not a package factory.
A tool that packages use.

```nix
# kix/lib/helm.nix — new API
{
  # Unchanged — fixed-output derivation for chart tarballs
  fetchHelmChart = { repo, name, version, hash }: <derivation>;

  # NEW — build-time resource import
  importChart = {
    chart,              # from fetchHelmChart (or a local path)
    scope,              # the package's scope (for mkResource/mkClusterResource)
    values ? {},        # helm values (already merged by caller)
    releaseName ? "release",
    namespace ? scope.namespaceName,
    includeCrds ? true,
    includeHooks ? true,
    extraFlags ? [],

    # Annotation/label control
    strip ? {
      helmAnnotations ? true;   # meta.helm.sh/*, helm.sh/*, checksum/*
      helmLabels ? true;        # managed-by, helm.sh/chart
      defaultStrategy ? true;   # default strategy/updateStrategy on workloads
    },
    preserveAnnotationPrefixes ? [],  # prefixes to keep even when stripping

    # Pre-wrap resource patching (same as current patchResources)
    patchResources ? lib.id,
  }:
  <resource-collection>;
}
```

### The resource collection

`importChart` returns an attrset with structured access to the wrapped
resources. DAG linking (doc 86) is on by default — the collection knows
which resources depend on which:

```nix
{
  # ── Access ──────────────────────────────────────────────────

  # All wrapped resources as a flat list
  all = [ <resource> ... ];

  # Lookup by kind + name (throws if not found)
  get = kind: name: <resource>;

  # Lookup by kind + name (returns null if not found)
  find = kind: name: <resource or null>;

  # Filter by kind
  byKind = kind: [ <resource> ... ];

  # All workloads (Deployment, StatefulSet, DaemonSet, Job, CronJob)
  workloads = [ <resource> ... ];

  # Everything except the given resources
  excluding = resources: [ <resource> ... ];

  # As an attrset keyed by "${toLower kind}-${name}"
  # (same keys as current fromHelmChart output, for migration)
  attrs = { ... };

  # ── DAG (doc 86) ───────────────────────────────────────────

  # Inferred internal dependencies for a resource
  # (Service→Workload via selector, RoleBinding→SA, volume→ConfigMap, etc.)
  depsOf = resource: [ <resource> ... ];

  # All link edges as { from, to, type } triples
  # type ∈ { "selects", "binds", "mounts", "scales", "monitors" }
  edges = [ { from = <resource>; to = <resource>; type = "selects"; } ... ];

  # Diagnostics from the linking pass (orphan selectors, unmatched PDBs)
  # Integrates with doc 80 structured diagnostics
  diagnostics = [ <diagnostic> ... ];

  # ── Convenience ─────────────────────────────────────────────

  # Build a complete parts tree for simple charts.
  # Picks a root (explicit or auto-selected), wires everything else
  # into root.requires respecting the internal DAG, returns a ready-made
  # attrset suitable for returning from `build`.
  #
  # For simple charts this is the entire build function body:
  #   resources.mkParts { root = resources.get "Deployment" "descheduler"; }
  #
  # For complex charts, use resources.get/byKind/attrs to compose manually.
  mkParts = {
    root,                   # the root resource (explicit — no heuristic)
    extraParts ? {},        # additional parts to merge (CRD refs, etc.)
    extraRequires ? [],     # additional root.requires beyond chart resources
    out ? {},               # root.out (DI builders, CRD refs, etc.)
  }: <parts-attrset>;
}
```

The collection is a plain Nix value — no magic, no state, no side effects.
The package author either uses `mkParts` for the common case or queries
the collection directly for full control.

The `get` DSL is the key design choice: instead of auto-selecting a root
and hoping, the package author *pulls out* the resources they care about
by kind+name. This is explicit, greppable, and fails loudly if the chart
changes.

### What a helm package looks like

**Cilium — complex package with CRD refs and DI:**

```nix
# kix/packages/cilium/default.nix — a REAL package
{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://helm.cilium.io/";
    name = "cilium";
    version = "1.16.5";
    hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
  };
in
{
  meta = {
    version = "1.16.5";
    provides = [ "cni" "network-policy" "network-policy-enforcer" "cilium" ];
    k8s.minVersion = "1.27";
  };

  options = {
    values = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Helm values merged with defaults.";
    };
  };

  build = { self, config, clusterConfig }:
    let
      mergedValues = lib.recursiveUpdate defaultValues (config.values or {});

      # Import chart resources — IFD happens here, inside build
      resources = scope.helm.importChart {
        inherit chart scope;
        values = mergedValues;
        releaseName = "cilium";
        includeCrds = true;
      };

      # Pull out specific resources by kind+name — explicit, no heuristic
      agent = resources.get "DaemonSet" "cilium";
      operator = resources.get "Deployment" "cilium-operator";

      # CRD ref — just normal build code, no rootOut callback needed
      cnpCrdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
        # Wire against ALL workloads — resources.workloads is right there
        installedBy = resources.workloads;
      };
    in
    # mkParts handles the root/requires wiring + merges chart resources
    resources.mkParts {
      root = agent;
      extraParts = { inherit cnpCrdRef; };
      out = { inherit cnpCrdRef; };
    };
}
```

Note how `resources.get "DaemonSet" "cilium"` replaces the old
`rootSelector = { kind = "DaemonSet"; name = "cilium"; }`. Same information,
but now it's in the package (where the knowledge lives) instead of the
cluster definition. And it fails loudly if cilium ever renames its DaemonSet.

**Descheduler — simple chart, the whole build is three lines:**

```nix
# kix/packages/descheduler/default.nix — a REAL package
{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "https://kubernetes-sigs.github.io/descheduler";
    name = "descheduler";
    version = "0.32.2";
    hash = "sha256-ARIFySRZdUP+k79s5m11ozvGp9GgKe7dTAOQoW5X4mQ=";
  };
in
{
  meta.version = "0.32.2";

  options = {
    values = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
  };

  build = { self, config, clusterConfig }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or {});
        releaseName = "descheduler";
      };
    in
    # That's it. mkParts picks the root, wires requires from the DAG.
    resources.mkParts {
      root = resources.get "Deployment" "descheduler";
    };
}
```

**Reflector — package with DI builder:**

```nix
# kix/packages/reflector/default.nix — a REAL package
{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart { ... };
in
{
  meta = {
    version = "10.0.28";
    provides = [ "reflection" ];
    defaultAliases = [ "reflector" ];
  };

  options.values = lib.mkOption { ... };

  build = { self, config, clusterConfig }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate {} (config.values or {});
        releaseName = "reflector";
      };

      # Builder function — lives in root.out, not in a rootOut callback
      reflectSecret = consumerScope: { secretName, ... }:
        let
          # ... same builder code as today, but inline in build ...
        in { serviceAccount = ...; role = ...; binding = ...; job = ...; };
    in
    resources.mkParts {
      root = resources.get "Deployment" "reflector";
      out = { inherit reflectSecret; };
    };
}
```

### What cluster definitions become

```nix
# Before (15+ lines of boilerplate)
instances.kube-system.cilium = {
  package = kix.fromHelmChart {
    chart = kix.fetchHelmChart {
      inherit (packages."cilium".chart) repo name version;
      hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
    };
    values = packages."cilium".defaultValues;
    releaseName = "cilium";
    includeCrds = true;
    rootSelector = { kind = "DaemonSet"; name = "cilium"; };
    extraMeta = packages."cilium".meta;
    rootOut = packages."cilium".rootOut;
  };
  config.values = { kubeProxyReplacement = false; };
};

# After (3 lines — same as any native package)
instances.kube-system.cilium = {
  package = packages.cilium;
  config.values = { kubeProxyReplacement = false; };
};
```

The chart hash moves into the package. The cluster operator doesn't need to
know or care that cilium is helm-backed.

### Hash management

The one objection: "but different clusters might need different chart
versions." This is already the case for native packages — if you need a
different version, you define a different package. The hash-in-package model
is the same as every other Nix fetchurl pattern (nixpkgs' `fetchFromGitHub`,
Go modules, Rust crates). It's the right default.

For the rare case where a cluster genuinely needs a override the chart
version or hash, the package can expose it as a config option:

```nix
options.chartOverride = lib.mkOption {
  type = lib.types.nullOr lib.types.package;
  default = null;
  description = "Override the chart derivation (for version pinning).";
};
```

### DAG reconstruction is built in (doc 86)

Doc 86 proposes reconstructing intra-chart resource DAGs from well-known K8s
linking patterns. In v2, **this is not an opt-in feature — it's how
`importChart` works by default.** The resource collection always knows which
resources depend on which.

The linking pass runs automatically after wrapping:

1. Service → Workload (label subset match on `spec.selector` vs pod labels)
2. RoleBinding → ServiceAccount (subject name+namespace)
3. Workload → ConfigMap/Secret (volume mounts, envFrom refs)
4. Workload → ServiceAccount (`serviceAccountName`)
5. PDB → Workload (selector match)
6. HPA → Workload (scaleTargetRef kind+name)
7. ServiceMonitor → Service (selector match)
8. Ingress/HTTPRoute → Service (backend name)

This is ~200 LOC of pure Nix (label subset matching, name lookups) running
over the already-imported JSON at eval time.

`mkParts` uses the DAG to wire `root.requires`: instead of a flat list of
all non-root resources, each resource carries its inferred deps. The deploy
wave respects these edges — ServiceAccounts before Deployments, ConfigMaps
before the workloads that mount them.

`resources.depsOf` and `resources.edges` expose the DAG for packages that
need to inspect it. `resources.diagnostics` reports orphan selectors,
unmatched PDBs, etc. via doc 80's structured diagnostics.

### Annotation control

The `strip` parameter replaces the all-or-nothing model:

```nix
resources = scope.helm.importChart {
  # ...
  strip = {
    helmAnnotations = true;      # default: strip meta.helm.sh/*, etc.
    helmLabels = true;            # default: strip managed-by, chart label
    defaultStrategy = true;       # default: strip default RollingUpdate
  };
  # Keep specific prefixes even when stripping is on
  preserveAnnotationPrefixes = [
    "example.com/"  # chart controller uses these
  ];
};
```

### What gets deleted

- `fromHelmChart` (the package factory) — replaced by `importChart`
- `rootOut` parameter — replaced by inline code in `build`
- `rootSelector` parameter — replaced by `resources.get kind name`
- `extraMeta` parameter — replaced by package-level `meta`
- `wrapHelmResource` as a public API — becomes internal to `importChart`
- `helmWiring` convention in packages — not needed, packages ARE packages
- `rootOutResourceParts` extraction logic — not needed, package author
  composes parts explicitly
- The `workloads` passthrough to `rootOut` — not needed, package author
  calls `resources.workloads` directly

---

## What this fixes

| Problem | How it's fixed |
|---------|---------------|
| Packages can't be packages | They're real packages with `build` |
| rootOut kitchen sink | Inline code in `build` — resources go in parts, builders go in `root.out` |
| Root selection fragility | Author calls `resources.get "DaemonSet" "cilium"` — explicit, no heuristic |
| Flat requires model | Doc 86 DAG linking is on by default — `mkParts` uses inferred edges |
| Annotation stripping all-or-nothing | `strip` + `preserveAnnotationPrefixes` |
| collectResources silent drops | Author composes parts tree — no implicit filtering |
| Wave coupling insider knowledge | Author has `resources.workloads` in scope, wires `installedBy` directly |
| Hardcoded workload kinds | `workloads` computed from actual chart output, configurable |

---

## Alternatives Considered

### A. Keep fromHelmChart, add more parameters

Add `strip`, `linkResources`, better `rootOut` typing, warnings for dropped
parts. This is incremental improvement on a fundamentally wrong abstraction.

**Rejected because:** The core problem is that `fromHelmChart` is a package
factory that prevents packages from being packages. Adding parameters doesn't
fix the structural issue — it makes the parameter list longer (already 10+
parameters) and the implicit contract more complex.

### B. Full native migration for all charts (doc 40)

Convert every helm chart to a native kix package. No helm bridge at all.

**Rejected as a universal strategy because:** Doc 86 §Motivation is right:
most charts shouldn't be decomposed. PostgreSQL, Redis, Grafana — these are
single upstream projects with one release cycle. The value of helm integration
is importing them without rewriting every resource by hand. The right answer
is making the import good enough that the author has full compiler guarantees
*and* full control, without line-by-line migration.

Doc 40's composite decomposition remains the right approach for mega-charts
(kube-prometheus-stack). The two strategies compose: decompose the mega-chart
into sub-charts, each imported via `importChart` in its own package.

### C. Rust oracle for helm parsing (doc 86 §B)

Move helm template parsing into the Rust oracle (doc 36).

**Deferred, not rejected.** For well-known K8s link types, pure Nix is
sufficient. If CRD-specific linking needs schema awareness, the oracle is the
right place. But that's a doc 86 concern — `importChart`'s design doesn't
preclude it.

### D. Thin wrapper: keep fromHelmChart as sugar over importChart

Provide both `importChart` (the primitive) and a `fromHelmChart` convenience
wrapper for simple charts that don't need custom build logic.

**Rejected in favor of `mkParts`.** The convenience lives inside the
resource collection (`resources.mkParts { root = ...; }`) rather than as a
separate package factory. This way there's one API (`importChart`) that
returns one type (resource collection), and the convenience is a method on
that type — not a second entry point with different semantics. Simple charts
use `mkParts`; complex charts compose manually. No cliff when graduating
from one to the other.

---

## Migration Path

### Phase 1: `importChart` + DAG linking + `mkParts`

Implement the full resource collection API in `kix/lib/helm.nix`:
- `importChart` (resource import + wrapping)
- DAG linking pass (doc 86's well-known K8s link types)
- `mkParts` convenience for composing the parts tree
- `get`/`find`/`byKind`/`workloads`/`excluding` accessors

Expose via `scope.helm.*`. No breaking changes — `fromHelmChart` coexists.

**Deliverable:** Descheduler migrated to the new pattern. Verify identical
YAML output, cluster definition shrinks to 3 lines. DAG edges visible in
the plan.

### Phase 2: Migrate packages in order of complexity

1. **Simple charts** (descheduler, promtail, smartctl-exporter) — `mkParts`
   with explicit root. ~10 lines of build code per package.
2. **DI providers** (reflector) — builder moves inline. Verify DI consumers.
3. **CRD providers** (cilium) — CRD ref + `installedBy = resources.workloads`
   inline. Verify netpol wiring.
4. **Mega-charts** (kube-prometheus-stack) — keep on `fromHelmChart`
   temporarily; doc 40 decomposition is the real plan here.

Each migration is independently shippable.

### Phase 3: Delete `fromHelmChart`

Remove the old package factory, `rootOut`, `rootSelector`, `extraMeta`,
`helmWiring` convention. Clean break.

---

## Resolved Decisions

### Chart hash: locked in package, overridable from outside

The package maintainer owns the chart + hash (same as every Nix package).
This is the default:

```nix
# In the package — maintainer controls this
chart = scope.helm.fetchHelmChart {
  repo = "https://helm.cilium.io/";
  name = "cilium";
  version = "1.16.5";
  hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
};
```

For cluster-level overrides (testing a chart bump, hotfix, etc.), the
package exposes an option:

```nix
options.chartOverride = lib.mkOption {
  type = lib.types.nullOr lib.types.package;
  default = null;
};

# In build:
effectiveChart = config.chartOverride or chart;
resources = scope.helm.importChart { chart = effectiveChart; ... };
```

This doesn't need to feel nice — it's the escape hatch. The happy path is
`package = packages.cilium; config.values = { ... };` and the package
maintainer bumps the version.

### `mkParts` for the common case

Yes. Simple charts (descheduler, promtail) shouldn't need to manually compose
`root = { resource = ...; requires = ...; }`. `mkParts` handles it:

```nix
resources.mkParts {
  root = resources.get "Deployment" "descheduler";
}
# → { deployment-descheduler = ...; configmap-... = ...;
#     root = { resource = <Deployment>; requires = <DAG-ordered>; }; }
```

Complex packages use `get`/`byKind`/`attrs` directly and compose their
own parts tree. The convenience doesn't limit the primitive.

### DAG linking is core, not opt-in

Doc 86's DAG reconstruction is built into `importChart` from day one. The
resource collection always has `depsOf`, `edges`, `diagnostics`. `mkParts`
uses inferred edges for `root.requires` ordering. This is a v2 design goal,
not a Phase 4 add-on.

---

## Open Questions

### 1. How does `scope.helm` get wired?

`importChart` needs `pkgs` (for `helm`, `yq`, `runCommand`). Today `helm.nix`
takes `{ pkgs, lib }` at import time. The scope already has access to `pkgs`.

Leaning toward lazy import: `scope.helm` is an attrset that only imports
`helm.nix` when accessed. Avoids paying the import cost for non-helm
packages. Simple eager import is fine for a first iteration.

### 2. Onboarding: new users pulling in their charts

A new kix user who has existing Helm charts should be able to get them into
kix with minimal friction. Two personas:

**(a) "I just want to deploy this chart"** — user has a chart, hasn't written
a kix package before. They need a path from `helm install` to kix that
doesn't require understanding the full package API.

**(b) "I maintain a kix package that tracks upstream"** — user bumps the
version/hash when upstream releases. Same workflow as nixpkgs maintainers.

For (a), the question is whether `mkParts` is enough or whether we need a
one-shot CLI helper (`kix helm import <chart>`) that scaffolds a package
file. The package file would be ~20 lines — not zero, but not scary either.
An LLM with the `kix-migration` skill can generate it from a chart URL.

For (b), the workflow is: bump `version` + `hash` in the package, run
`nix build`, verify. Same as any Nix package update. `resources.get` will
throw if the chart renamed a resource, which is the right behavior (forces
the maintainer to update the package).

**Unresolved:** Should `kix-migration` skill guidance include helm v2
package scaffolding? (Yes, once implemented.)

### 3. External cilium variant

The `external` variant is already a real package with `build`. Unaffected
by this migration. Naming stays as `packages.cilium.external` (it's a
variant of the same package, not a separate package).

### 4. Performance

IFD inside build runs once per package per cluster eval, cached by Nix.
Same as today — `fromHelmChart` already does IFD inside build. The DAG
linking pass is O(n*m) for label matching (n services * m workloads).
For typical charts (10-50 resources): negligible. For mega-charts
(kube-prometheus-stack ~200 resources): profile, but likely still <100ms.

### 5. Interaction with doc 40 (composite packages)

`importChart` makes doc 40 easier: each sub-chart of a mega-chart becomes
a real package with `importChart`. The composite module wires them via DI.

Migration path for kube-prometheus-stack:
1. Import monolithically via `importChart` (immediate improvement over v1)
2. Decompose into sub-packages (doc 40 Phase 0-5)
3. Each sub-package uses its own `importChart`

Step 1 is independently valuable.
