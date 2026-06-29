# Helm-backed packages

This chapter covers how kix wraps upstream Helm charts and turns their rendered manifests into first-class kix resources. The bridge lives in `kix/lib/helm.nix` (chart fetching, templating, wrapping, the `importChart` collection API, and the `mkParts` builder) with intra-chart dependency inference in `kix/lib/helm-dag.nix`. There are three tiers of usage, from a one-line inline declaration in a cluster definition up to a fully native package that only borrows the chart's CRDs. The key idea: a Helm chart is rendered once via IFD (`helm template`), then every resource is re-wrapped through `scope.mkResource` so it joins the same store-path DAG, identity hashing, and netpol generation as a hand-written package (see 04-resources-and-out.md).

## The three tiers

| Tier | Entry point | Where it lives | Control |
|------|-------------|----------------|---------|
| 1 | `kix.helmChart { repo; name; version; hash; }` | inline in a cluster def | minimal: `config.values`, auto root |
| 2 | `scope.helm.importChart { chart; scope; ... }` then `resources.mkParts { root = ...; }` | inside a package `build` | full: explicit root, extra deps, network deps, strip control, resource replacement |
| 3 | `scope.helm.importChartCrds { chart; scope; }` (or hand-rolled CRDs) | a native package that wraps a charted upstream | the package authors workloads itself, borrowing only the chart's CRDs |

All three sit on the same two primitives: `fetchHelmChart` (content-pinned fetch) and `importChart` / `importChartCrds` (IFD render + wrap).

## fetchHelmChart: content-pinning

`fetchHelmChart` is a fixed-output derivation that pulls a chart tarball from an OCI or HTTP registry. It pins the exact bytes via `hash`, so the chart is part of the reproducible build, not fetched at deploy time.

```nix
chart = scope.helm.fetchHelmChart {
  repo = "https://helm.cilium.io/";
  name = "cilium";
  version = "1.16.5";
  hash = "sha256-GCA1rnws+NGUkOzs9hj2oRrcRg7R59vTiyMGXwLxi00=";
};
```

`repo` starting with `oci://` triggers `helm pull oci://...`; otherwise it does `helm repo add` + `helm pull`. The hash algorithm is inferred from the prefix (`sha256-` -> sha256, else sha512). To find a fresh hash, build once with a wrong/empty hash and copy the value Nix reports.

## Tier 1: kix.helmChart inline

`kix.helmChart` returns a complete package function. Drop it straight into an instance's `package` field in a cluster definition - no separate package file needed. It exposes a single `values` option and uses `autoRoot` (first Service, else Deployment, else StatefulSet, else DaemonSet, else first resource) as the entry point.

```nix
homeassistant.homeassistant = {
  package = kix.helmChart {
    repo = "https://pajikos.github.io/home-assistant-helm-chart";
    name = "home-assistant";
    version = "0.3.51";
    hash = "sha256-gcZzrAYS23YiOyVJg8cIntyBQmF/Q+/d0q5sKWtl8WY=";
    releaseName = "homeassistant";
    patchResources = map (
      r:
      if r.kind == "Service" && r.metadata.name == "homeassistant-home-assistant" then
        r // { spec = r.spec // { clusterIP = "None"; }; }
      else
        r
    );
  };
  config.values = { ingress.enabled = false; };
};
```

`kix.helmChart` accepts `repo`, `name`, `version`, `hash`, plus optional `releaseName` (defaults to `name`), `includeCrds` (default `true`), `strip`, and `patchResources`. The instance then sets `config.values = { ... }` to feed the chart. The above example also shows `patchResources`, a raw-JSON transform applied before wrapping (here used to set `clusterIP: None` on a specific Service). Use Tier 1 for quick one-offs; reach for Tier 2 the moment you need an explicit root, cross-package wiring, or resource replacement.

## Tier 2: scope.helm.importChart inside a package

`importChart` is not a package and not a package factory; it is a tool you call inside a `build` function. It runs `helm template` via IFD, parses the JSON, reconstructs the intra-chart DAG, wraps every resource through the scope, and returns a structured collection. You then pick a root and call `resources.mkParts`.

The minimal shape (from `kix/packages/redis/default.nix`):

```nix
build =
  { config, scope, ... }:
  let
    resources = scope.helm.importChart {
      inherit chart scope;
      values = lib.recursiveUpdate defaultValues (config.values or { });
      releaseName = scope.instanceName;
    };
  in
  resources.mkParts {
    root = builtins.head (resources.byKind "StatefulSet");
  };
```

### The collection API

`importChart` returns a record with these lookup and DAG members:

- `all` - flat list of every wrapped resource.
- `get kind name` - lookup, throws if not found. Use when you know the resource exists (e.g. `resources.get "DaemonSet" "cilium"`).
- `find kind name` - lookup, returns `null` if absent.
- `byKind kind` - all resources of a kind, as a list.
- `workloads` - all Deployment/StatefulSet/DaemonSet/Job/CronJob resources (`helmDag.workloadKinds`).
- `excluding [resources]` - everything except the given resources.
- `attrs` - the collection keyed by `"<lowerkind>-<name>"`.
- `edges` - inferred `{ from, to, type }` triples between wrapped resources.
- `depsOf resource` - the resource's inferred intra-chart dependencies.
- `orphans` - diagnostics for selectors/refs that match nothing in the chart.
- `crds` - auto-derived `{ cr, mkCR }` builder pair per shipped CRD (see below).
- `autoRoot` - heuristic root (Tier 1 uses this).
- `replaceResource kind name newResource` - substitution, returns a new collection (see below).
- `mkParts { root; ... }` - assemble the final parts tree.

### importChart knobs

`importChart` takes, beyond `chart` and `scope`:

- `values` (default `{}`), `releaseName` (default `"release"`), `namespace` (default `scope.namespaceName`), `includeCrds` (default `true`), `includeHooks` (default `true`), `extraFlags`.
- `strip` and `preserveAnnotationPrefixes` - annotation/label cleanup, see below.
- `patchResources` - raw-JSON transform applied to the filtered resource list before wrapping (default `lib.id`).
- `extraEdges` - manually injected intra-chart edges the DAG can't infer (see below).
- `deps` and `networkDeps` - cross-package wiring for network policy (see below).

Helm test hooks (`helm.sh/hook` containing `"test"`) are dropped automatically, `List` resources are unpacked into their items, and null/empty documents are filtered out.

### mkParts and the auto-derived out

`mkParts { root, extraParts ? {}, extraRequires ? [], out ? {} }` assembles the `self` attrset. It is DAG-aware: `root` only directly requires resources that are NOT targets of intra-chart edges (the DAG entry points); everything else is reachable transitively because each wrapped resource carries its own `requires` (see 04-resources-and-out.md on `requires`/`identityHash`). This gives the same forward-closure deploy ordering as a native package.

`mkParts` auto-derives a public `out` for `root` (see 02-package-anatomy.md, 04-resources-and-out.md):

- `out.byKind.<Kind>.<name>` is always emitted - a stable flat lookup into the chart so a downstream package can reach a non-root resource. Example: `redis.out.byKind.Service.redis-master.out.fqdn`.
- Service promotion: when `root` is a workload (Deployment/StatefulSet/DaemonSet/Job) and exactly one Service in the chart selects it (via a `selects` DAG edge), that Service's `out.{name, fqdn, selector, ports, url}` are promoted onto the root's `out`. So `pkg.out.fqdn` is the public Service FQDN, not the workload's synthetic one. Skipped silently when 0 or >1 Services match - then supply the right values via the explicit `out` arg.
- When `root.kind == "Service"`, no promotion happens (the scope already derived the right outs on the root); only `byKind` is added.
- `out.crds.<Kind> = { cr, mkCR }` per shipped CRD (Phase 3, see below).

User-supplied `out = { ... }` shallow-merges over the auto-derived values - the user wins on collisions. `extraParts` merges additional named parts (CRD refs, extra resources) into the `self` attrset.

## Intra-chart dependency inference (helm-dag.nix)

`helm-dag.nix` reconstructs edges from raw JSON before wrapping, so inferred deps become real `requires` (part of the content hash and `kix.dev/depends-on`). Edge direction is "from depends on to" - `to` deploys first. The inferred patterns:

- Workload -> ServiceAccount (`serviceAccountName`).
- Workload -> ConfigMap/Secret via volumes (incl. projected sources), `envFrom`, and `env[].valueFrom.*KeyRef`.
- RoleBinding/ClusterRoleBinding -> ServiceAccount (subjects).
- Service -> Workload (selector label subset match).
- HPA -> Workload (`scaleTargetRef`).
- PodDisruptionBudget -> Workload (selector match).
- Ingress -> Service and HTTPRoute -> Service (backend refs).
- ServiceMonitor -> Service (selector match).

Anything the DAG can't see from a manifest reference needs `extraEdges`. Example from `kix/packages/loki/default.nix`: the loki-gateway (nginx) proxies to the loki backend, but there is no K8s reference between them, so the edge is declared by hand.

```nix
extraEdges = [
  {
    from = { kind = "Deployment"; name = "loki-gateway"; };
    to   = { kind = "StatefulSet"; name = "loki"; };
  }
];
```

`importChart` resolves each `extraEdges` entry against the chart and throws if either endpoint is missing, so a typo fails the build rather than silently dropping the edge.

## Cross-package wiring: deps and networkDeps

These two knobs exist for network-policy generation, not deploy ordering. Workload kinds are wrapped through `scope.mkHelmWorkload` (which skips the DI-reference validation that `mkDeployment` does, since helm manifests have no DI references) and emit per-workload CiliumNetworkPolicies for DNS egress, self-ingress, and cross-package service egress.

- `deps = [ dep, ... ]` - DI dep instances the chart's manifests reference. In phase 2, every context-carrying string at `dep.out.*` (top level only) is auto-collected and merged into `networkDeps`, so the egress edge to that dep is discovered. The dep must also be a `build` function arg so its Services land in the netpol service registry (see 07-dependency-injection.md, 09-networking-and-meta.md).
- `networkDeps = [ value, ... ]` - explicit context-carrying values for context that `deps` auto-discovery misses: values nested under `dep.out.byKind.*` or hand-built strings that don't appear at a top-level `dep.out.*` attr.

`kix/packages/promtail/default.nix` shows the modern `deps` form. Promtail interpolates `loki.out.fqdn` into its config, then passes `deps = [ loki ]` so the promtail -> loki-gateway egress edge is generated automatically (replacing an older explicit `networkDeps = [ loki.out.fqdn ]`):

```nix
resources = scope.helm.importChart {
  inherit chart scope;
  values = lib.recursiveUpdate (lib.recursiveUpdate defaultValues lokiValues) (config.values or { });
  releaseName = "promtail";
  deps = [ loki ];
};
```

## Annotation and label stripping (lossy on purpose)

By default `importChart` strips Helm bookkeeping so the rendered output matches what the cluster actually stores (and so diffs against a live cluster are clean - see 11-scorecard.md and the diff tooling). This is intentionally lossy.

Dropped by default:
- Annotations with prefixes `meta.helm.sh/`, `helm.sh/`, `checksum/`.
- Labels `app.kubernetes.io/managed-by` (Helm sets `Helm`) and `helm.sh/chart`.
- Default `strategy` / `updateStrategy` blocks that match the K8s built-in defaults, and Helm-injected pod-template annotations.

Control it via `strip` and `preserveAnnotationPrefixes`:

```nix
resources = scope.helm.importChart {
  inherit chart scope;
  strip = {
    helmAnnotations = true;   # default
    helmLabels = true;        # default
    defaultStrategy = true;   # default
  };
  preserveAnnotationPrefixes = [ "meta.helm.sh/" ];  # keep these helm annotations
};
```

`preserveAnnotationPrefixes` is an escape hatch. The predicate keeps an annotation if it is NOT a helm annotation OR its key matches one of the listed prefixes (`!(isHelmAnnotation k) || anyPrefixMatch`). The prefix list therefore only has effect for keys that are already helm annotations (`meta.helm.sh/`, `helm.sh/`, `checksum/`). Listing a non-helm prefix (e.g. `prometheus.io/`) is a no-op, since those keys are never stripped in the first place. Use it to rescue a specific helm-prefixed annotation the chart genuinely needs.

## Replacing a chart resource

Charts often ship resources that kix wants to own per-cluster - most commonly an Ingress, where the cluster should decide between Ingress, HTTPRoute, or nothing. `resources.replaceResource kind name newResource` returns a new collection with the swap applied to every lookup, `mkParts`, and DAG operation.

```nix
ingress = scope.expose.mk { ... };
patched = resources.replaceResource "Ingress" "myapp" ingress;
# then: patched.mkParts { root = ...; }
```

Caller responsibility: edges INTO the original (chart resources that depended on it) are dropped, so the replacement must declare its own `requires` if it needs to wait for chart resources. For leaf resources (Ingress, ServiceMonitor) this is usually nothing. Edges OUT of the original survive through `mkParts`'s root requires. `replaceResource` throws if no resource matches `kind`/`name`.

If you only need to mutate a raw resource (not swap it for a kix-native one), use `patchResources` instead - it runs on raw JSON before wrapping. The HomeAssistant Tier 1 example above patches a Service's `clusterIP` this way.

## Auto-derived CRD builders

For every CustomResourceDefinition a chart ships, the collection exposes `crds.<Kind> = { cr, mkCR }` (also surfaced as `out.crds.<Kind>` by `mkParts`). `cr args` enriches a CR spec with the right `apiVersion`/`kind` and adds the CRD plus every chart workload to `requires`; `mkCR consumerScope args` builds it as a cluster- or namespaced resource depending on the CRD scope. A consumer's CR therefore waits for both the CRD's Establishment and every controller workload's readiness (any of them could be the admission/conversion webhook). This only works for CRDs that appear in `helm template --include-crds` output.

Charts that install CRDs at runtime (not via `--include-crds`) need explicit CRD refs. Cilium does exactly this: its CRDs are installed by the agent at startup (`INSTALL_CRDS`), so the package hand-builds `scope.mkCRDRef` markers wired to `installedBy = resources.workloads`, gating CNP/CCNP application on the whole stack being Ready. See `kix/packages/cilium/default.nix`.

## Tier 3: native package borrowing chart CRDs

When you want kix to author the workloads itself (full control over Deployments, RBAC, config) but still ship the upstream chart's CRDs verbatim, use `scope.helm.importChartCrds { chart; scope; releaseName ? "release"; values ? {}; }`. It renders only `kind: CustomResourceDefinition` documents and returns a list of wrapped, cluster-scoped resources. Add them to your package root's `extraParts` or `requires` so the package ships the chart's CRDs without re-authoring each one via `scope.crd.fromKind`. (Packages that prefer to fully hand-author CRDs use the `scope.crd.fromKind` pipe builders instead - see `kix/packages/cert-manager/crds.nix` and 08-secrets-crds-rbac.md.)

## Real example: cilium (Tier 2 end to end)

`kix/packages/cilium/default.nix` wraps the upstream Cilium chart, picks an explicit DaemonSet root, ships hand-built CRD refs (the chart installs CRDs at runtime), and exposes a netpol builder API on `out`:

```nix
build =
  { config, scope, ... }:
  let
    resources = scope.helm.importChart {
      inherit chart scope;
      values = lib.recursiveUpdate defaultValues (config.values or { });
      releaseName = "cilium";
      includeCrds = true;
    };

    cnpCrdRef = scope.mkCRDRef {
      group = "cilium.io";
      kind = "CiliumNetworkPolicy";
      plural = "ciliumnetworkpolicies";
      version = "v2";
      crdScope = "Namespaced";
      installedBy = resources.workloads;
    };
  in
  resources.mkParts {
    root = resources.get "DaemonSet" "cilium";
    extraParts = { inherit cnpCrdRef ccnpCrdRef; };
    out = { inherit cnpCrdRef ccnpCrdRef; netpol = ...; };
  };
```

Note the pattern: explicit `root` via `get`, CRD refs threaded through both `extraParts` (so they deploy) and `out` (so consumers reach them), and `out` overrides shallow-merging over the auto-derived `byKind`.

## Gotchas

- **IFD cost.** `importChart` runs `helm template` at evaluation time (import-from-derivation). The first eval after a chart or values change pays the render. `values` changes the derivation, so flipping a single value re-renders.
- **`values` only, no CLI flags.** `importChart` feeds a values file plus a fixed flag set. Anything a chart normally accepts as a `helm` CLI flag must be expressed as a value (or via `extraFlags`). Bitnami's `global.security.allowInsecureImages` in `kix/packages/redis/default.nix` is set as a value for exactly this reason.
- **autoRoot is a heuristic.** It picks the first Service/Deployment/StatefulSet/DaemonSet. For multi-workload charts this is rarely the resource you want as the package's public face - use Tier 2 and pass an explicit `root` via `get`.
- **Service promotion silently skips on 0 or >1 matches.** If `pkg.out.fqdn` looks wrong, check how many Services select the root workload; supply `out = { fqdn = ...; }` to `mkParts` when promotion is ambiguous.
- **Stripping is lossy by design.** If a downstream tool depends on a `helm.sh/`-prefixed annotation, it is gone unless rescued via `preserveAnnotationPrefixes`. Don't disable stripping wholesale just to keep one annotation; you'll reintroduce diff noise.
- **replaceResource drops inbound edges.** The replacement must re-declare any `requires` on chart resources it needs to wait for. For non-leaf replacements this is on you.
- **Runtime-installed CRDs aren't in the collection.** `crds.<Kind>` only covers CRDs emitted by `--include-crds`. Charts that install CRDs from an init job or the agent need explicit `scope.mkCRDRef` markers (the cilium pattern).
- **extraEdges endpoints are validated.** A misnamed `from`/`to` throws at eval rather than silently no-op-ing - good, but it means edges must be updated when a chart upgrade renames a resource.
