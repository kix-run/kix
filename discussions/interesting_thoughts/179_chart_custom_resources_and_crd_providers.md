# 179: Custom resources a Helm chart renders, and the package that declares their kind

**Status:** Deferred (the maintainer decided on 2026-11-24: record the use case, do not build it now)
**Related:** `../archive/87_helm_integration_v2.md`, `../archive/86_helm_dag_reconstruction.md`, `../archive/117_kube_prometheus_stack_wrapping_validation.md` (row G), `../146_crd_vendoring_and_upgrades.md`, `../147_operator_semantics_in_core_rules.md`, `housekeeping/2026-10-02-chart-cannot-render-another-packages-kinds.md`

**Why it waits.** The maintainer expects that most people will find it
easier to have an agent convert a Helm chart into a native Kix package
than to wrap the chart and link its custom resources to other packages. A
native package already builds each custom resource from the package that
declares its kind, so it passes check 21 with no new option.

**What would bring it back.** Users who must consume a third-party chart
unchanged, where that chart renders custom resources of another
operator's kinds (a ServiceMonitor, a Certificate, a ScaledObject), and
converting the chart is not an option for them. The design and its seven
questions below are kept as written for that day.

## Context

A team evaluating Kix consumes an in-house Helm chart unchanged through
`kix.helmChart`. The chart renders custom resources of kinds that other
packages declare: a KEDA `ScaledObject`, and a database operator's
`Database` and `DbUser`. The build fails at check 21.

Check 21 (`kix/lib/eval/validate-crds.nix`) requires every custom resource
to reach, through `kix.run/depends-on`, a declaration of its kind: a
`CustomResourceDefinition`, a CRD marker (`scope.mkCRDRef`, or
`kix.mkImport { crds }`), or an `APIService`. The declaration must serve
the resource's API version. The deploy uses that path to apply the
resource after the CRD is served.

A native package gets the path by building the resource from the
declaration: `scope.mkCR dep.out.crds.<Kind> { ... }`. `kix.monitor` does
the same for a ServiceMonitor through `prometheus.out.mkServiceMonitor`.
A chart resource cannot. `importChart` (`kix/lib/helm.nix`) gives chart
resources dependencies on the chart's own objects only
(`kix/lib/helm-dag.nix`, `instanceOfEdges` covers the chart's own CRDs).
The check's message and the docs say to switch the chart's toggle off and
build the resource in a package. For a chart consumed unchanged, that
means a fork or a patch.

The adoption path the team wants is: wrap the existing chart first to get
checks, the plan, and receipts, and convert it to a native package later.
That path fails on the first day for any chart that renders a
ServiceMonitor, Certificate, ScaledObject, or ExternalSecret. The team
proposed a `crdProviders` argument on `kix.helmChart` that maps each CRD
to the package that provides it.

## What the code does today

Evaluated on this branch with synthetic packages (a provider that declares
`keda.sh/ScaledObject` with `scope.mkCRDRef`, and a chart-shaped package
that wraps one rendered `ScaledObject`):

1. With the provider in the cluster, check 21 fails and names it:
   "ScaledObject apps/web ... does not depend on the CRD ref ... (instance
   keda/keda), which declares its kind ... Take keda/keda as a dependency
   of apps/web".
2. A `kix.helmChart` instance cannot follow that advice.
   `instances.apps.web.deps.keda = ref.keda.keda` fails with `[K3646]`:
   "this instance's package takes no dependencies". The package that
   `kix.helmChart` returns has `build = { config, scope, ... }`, and Kix
   reads a package's dependencies from the argument names of `build`
   (`discoverBuildDeps` in `kix/lib/eval/resolve.nix`).
3. Passing the rendered resource through the declaration's own builder
   (`scope.mkResource (keda.out.crds.ScaledObject.out.cr { ... })`) gives
   it `requires:` on the marker, and check 21 passes. The mechanism the
   fix needs exists. Only the chart import does not use it.

`scope.helm.importChart` (the form used inside a package) has a `deps`
argument, which does something else: Kix derives network policy egress
from the chart's pods to each dependency listed (`_helmNetworkDeps`,
`eval/edges.nix`). It adds no dependency to other chart resources.

## Is this a symptom of a design problem?

Yes, of two.

**Chart resources skip the builders that carry a kind's facts.** A
declaration of a kind is a rich object. Its builder (`mkCRDBuilders` in
`kix/lib/core/resource.nix`) gives every custom resource the dependency on
the CRD, the kind's `crRequires` (such as a webhook check), a served
version check, the readiness rule the deploy waits on, `factBehavior` for
network policy, `usesAtLeast` for quota, and `holdsData`. `importChart`
sends a chart's custom resource through plain `scope.mkResource`, so it
gets none of them. Check 21 is the first place this shows. The others
would show later: the deploy would not wait for a chart-rendered
`Database` by the operator's readiness rule, and the resource would
carry no `holdsData` answer.

**An inline chart cannot take a dependency.** Everything else in Kix that
crosses a package boundary goes through a dependency. `kix.helmChart` has
no way to name one, so nothing can cross: no CRD link, no network policy
toward another package, and no `out` value of another package in the
chart's values. The same wall is behind the second gap the evaluator
raised (see "The related gap" below).

The fix for the first is to route a chart's custom resource through the
declaration's builder. The fix for the second is to let `kix.helmChart`
name dependencies. A `crdProviders` map that only adds an ordering edge
would fix neither cause.

## Could Kix infer the provider with no new option?

The idea: when a chart renders a resource of group and kind G/K and
exactly one instance in the cluster publishes a declaration of G/K, link
them. The graph does hold that knowledge. Check 21 prints the instance
today. What goes wrong:

- **The dependency arrives too late.** Kix decides the set of instances
  and each instance's dependencies in a first pass, before it builds
  anything (`eval/cluster.nix` steps 2 to 5). Auto-instantiation from
  `availablePackages`, activation of optional instances, the visibility
  rule for `meta.scope = "namespace"`, and the instance's recorded
  dependencies all read that set. A chart's kinds are known only after
  Helm renders it, which is later. An inferred link would be a deploy
  dependency that none of those decisions saw. An optional provider would
  stay inactive, and a namespace-scoped provider would be reached from a
  namespace that may not use it.
- **Finding candidates forces other instances.** Resolution today never
  evaluates the target instance (`architecture.md`, "DNS-like DI"). To
  find who publishes G/K, a chart instance would read `out.crds` of every
  instance. If one of those instances depends on the chart, that is an
  infinite recursion, which Nix reports without naming either instance. A
  static index would avoid it, but then every operator package restates
  its kinds in `meta`.
- **Two providers.** CRDs are cluster-wide, and two instances can declare
  one kind. `victoria-metrics-operator` carries the Prometheus-compatible
  kinds (`promCompatCrds`) that `prometheus-operator` also declares. Kix
  cannot choose, so the user has to, and that needs the explicit form
  anyway.
- **No provider, and hidden edges.** A CRD installed outside Kix has no
  instance until the user adds a `kix.mkImport { crds }`, so inference
  adds nothing there. Where it does link, removing the provider breaks a
  chart whose definition never mentions it.

Evaluation cost is small and is not the reason. The first two are.

Inference within the dependencies an instance has declared has none of
these problems, because the dependency exists before the build. That is
the recommended design: the user names the dependency, and Kix matches
the kinds.

## Designs

### A. `crdProviders`, a map from kind to dependency (as proposed)

```nix
instances.apps.web = {
  package = kix.helmChart {
    repo = "oci://registry.example.com/charts";
    name = "web"; version = "1.4.2"; hash = "sha256-...";
    crdProviders = {
      "keda.sh/ScaledObject" = "keda";
      "db.example.com/Database" = "dbOperator";
      "db.example.com/DbUser" = "dbOperator";
    };
  };
  deps.keda = ref.keda.keda;
  deps.dbOperator = ref.databases.operator;
};
```

The user writes group and kind strings that Kix can read from both sides:
the render names each resource's kind, and each declaration knows its
group and kind. A typo gives a dead entry, so Kix would need a second
check for entries that match nothing, and that check fires falsely when a
values toggle is off. A chart upgrade that adds a kind from the same
operator fails until the map grows. Against the principles: it invents a
vocabulary (the `"group/Kind"` key) for facts the objects carry, and it
is the string interpolation style that "Resources are rich objects"
steers away from. Its one real advantage is that it resolves two
providers of one kind. It is additive and breaks nothing.

### B. Link automatically from every dependency, with no argument

Inside a package, `scope` would carry the instance's resolved
dependencies, and `importChart` would link every rendered custom resource
to a matching declaration in any of them. A package that takes
`prometheus` and renders the chart's ServiceMonitor would need no change.

This is the most automatic form. It has no answer for `kix.helmChart`,
which takes no dependencies, so an argument is needed there anyway. It
also makes `importChart` read dependencies it was never handed, where
every other input is an argument (`deps`, `networkDeps`, `extraEdges`).
It is additive and breaks nothing.

### C. Recommended: `crdsFrom` names dependencies, and Kix matches the kinds

Inline chart. Each name becomes a dependency of the package, resolved by
the normal rules, exactly as a `build` argument name is in a native
package:

```nix
instances.apps.web = {
  package = kix.helmChart {
    repo = "oci://registry.example.com/charts";
    name = "web"; version = "1.4.2"; hash = "sha256-...";
    crdsFrom = [ "keda" "dbOperator" ];
  };
  deps.dbOperator = ref.databases.operator;   # only where the name does not resolve by itself
  config.values.autoscaling.enabled = true;
};
```

Chart wrapped in a package. Each entry is a dependency, or one
declaration when the package wants a single kind:

```nix
build = { config, scope, keda, prometheus, ... }:
  let
    rendered = scope.helm.importChart {
      inherit chart scope;
      values = config.values;
      crdsFrom = [ keda prometheus.out.crds.ServiceMonitor ];
    };
  in
  rendered.mkParts { root = rendered.autoRoot; };
```

A CRD installed outside Kix is one more instance, with the existing
import: `instances.keda.keda.package = kix.mkImport { crds = [ { group =
"keda.sh"; kind = "ScaledObject"; plural = "scaledobjects"; version =
"v1alpha1"; } ]; }`. A provider that is itself a `kix.helmChart` already
publishes `out.crds` for the CRDs its chart ships.

**Mechanism.** `importChart` collects the declarations from the entries
(`dep.out.crds.*`) and indexes them by the group and kind each
declaration carries. When it wraps a rendered resource whose group and
kind are in the index, it passes the resource through that declaration's
builder with the rendered API version, then seals it. The resource is
then the same as one built with `scope.mkCR`, so it also carries the
kind's `readiness`, `factBehavior`, `usesAtLeast`, and `holdsData`. An
entry whose kinds the chart does not render does nothing, so a values
toggle can switch a resource off.

**Principles.** No new manifest field. The user names a dependency, which
is the same statement a native package makes with a `build` argument. The
declaration object supplies group, kind, versions, and readiness, so no
string names a kind. The automation removes a mistake (a resource applied
before its CRD, or built without the kind's readiness rule) and saves no
lines by itself.

**What check 21 verifies afterwards.** The check is unchanged and stays
the backstop. A linked chart resource has a direct dependency on the
declaration, so the path exists. The served version is checked twice: by
the builder at seal time, with a message that names the declaration, and
by check 21. At deploy, the resource waits for the CRD (or for the marker
to see the CRD established and serving the version), for the kind's
`crRequires`, and then by the kind's readiness rule.

**Failure messages.** Drafts, in the form the screen shows. The copy pass
rewrites them.

```text
- ScaledObject apps/web (instance apps/web) comes from a Helm chart and
  does not depend on the CRD ref crd-ref-keda-scaledobjects-keda-sh
  (instance keda/keda), which declares its kind, so the deploy can apply
  it before the CRD is served.
  Fix: add "keda" to crdsFrom in the kix.helmChart of apps/web, and set
  instances.apps.web.deps.keda = ref.keda.keda.

- ScaledObject apps/web (keda.sh/v1alpha1, instance apps/web) comes from
  a Helm chart, and no instance in this cluster declares its kind.
  Fix: add the package that installs the CRD, or declare a CRD installed
  outside Kix with kix.mkImport { crds = [ ... ]; }, then name that
  instance in crdsFrom.
```

These replace the sentence check 21 appends today ("turn the toggle off
... a chart resource cannot take the dependency"), which stops being
true. Two more errors are new: a `crdsFrom` entry that publishes no
`out.crds`, and two entries that declare one kind the chart renders. The
second names both instances.

**Breaking?** No. Both arguments are new, and a build that fails today
passes. One case changes output without failing first: a package whose
chart resource already reaches the declaration by an indirect path and
that later adds `crdsFrom` gets a direct dependency and the readiness
annotation. That is opt-in. Kind `added`.

### D. Reuse `importChart`'s existing `deps` for the link

No new argument inside a package: `deps = [ prometheus ]` would also link
kinds. Rejected because `deps` means "this chart's pods dial these
dependencies", and it widens network policy. Naming KEDA there to link a
`ScaledObject` would allow egress from the chart's pods to the KEDA
operator, which they never contact. The two statements need two
arguments.

## Recommendation

Design C. It fixes both causes with the mechanism packages already use,
the user states one fact (the dependency) and no kind names, and it
covers the two-provider case inside a package by accepting a single
declaration. A loses because it restates what the objects know. B loses
because it cannot serve the inline chart and reads dependencies
invisibly. D loses because it grants network access as a side effect.
Cluster-wide inference loses on evaluation order.

## The related gap: policy and `out` wiring stop at the chart boundary

In scope here, because the same change delivers it:

- An inline chart gains dependencies. The mechanism (`kix.helmChart`
  declares dependency names on the package it returns) is the one any
  later cross-boundary feature needs.
- A chart's custom resource carries the kind's `factBehavior`, so the
  operand policies Kix derives for custom resources apply to
  chart-rendered ones.

Not in scope, and not designed here:

- Network policy from an inline chart's pods to another package. Inside a
  package, `deps` and `networkDeps` on `importChart` do this. An inline
  chart has no equivalent.
- Putting another package's `out` values into an inline chart's values.
- What a chart publishes to its consumers beyond the promoted Service
  fields, `out.byKind`, and `out.crds`.

The design leaves room for all three. A later `kix.helmChart` argument
for connections, or values written as a function of dependencies, would
declare names the way `crdsFrom` does.

## Implementation plan

One pull request, in this order. Rough size: 150 lines of library code,
250 lines of tests, and the docs. One to two days of agent work.

1. **Make a declaration describe itself** (`kix/lib/core/resource.nix`).
   `mkCRDBuilders` also returns the group, kind, served versions, and
   scope it was given, so every declaration exposes them under `out`.
   Matching reads these and never the attribute name under `out.crds`,
   because two groups can share a kind name (`Database`, `Cluster`).
2. **Give chart declarations the common shape** (`kix/lib/helm.nix`,
   `mkCrdBuilder`). A chart's `out.crds.<Kind>` is `{ cr; mkCR; }` with no
   `out`, unlike the declarations from `scope.mkCRD`, `scope.mkCRDRef`,
   and `kix.mkImport`. Make it the CRD resource with the builders under
   `out`, and keep `cr` and `mkCR` at the top so existing callers work.
3. **Link in `importChart`** (`kix/lib/helm.nix`). Add `crdsFrom`, build
   the index (refuse an entry with no declarations, and two declarations
   of one rendered kind), and in `wrapResource` pass a matching resource
   through the declaration's builder. Take cluster or namespaced scope
   from the declaration. Leave `inferEdges` alone.
4. **Let `kix.helmChart` declare dependencies** (`kix/lib/helm.nix`,
   `kix/lib/eval/resolve.nix` `discoverBuildDeps`,
   `kix/lib/eval/instance.nix` `callBuildFn`). `helmChart` takes
   `crdsFrom` as names, declares them as arguments of its `build` with
   `lib.setFunctionArgs`, and forwards the resolved dependencies. The two
   readers switch from `builtins.functionArgs` to `lib.functionArgs`,
   which reads declared arguments.
5. **Reword check 21 for chart resources**
   (`kix/lib/eval/validate-crds.nix`). The check needs to know that a
   resource came from a chart, for example from a flag `wrapResource`
   sets outside the manifest, as `_builtBy` is set.
6. **Tests.** A new `kix/lib/tests/units/helm-crds-from.nix`, on the stub
   `readRender` that `units/helm-render.nix` uses. Cases: a linked
   resource depends on the marker and carries the readiness annotation; a
   cluster-scoped kind; an unserved version; an entry with no `out.crds`;
   two declarations of a rendered kind; an unrendered kind; two groups
   with one kind name; an inline chart that takes `deps.<name>`; a chart
   as the provider, read with `scope.mkCR`. Update the check 21 message
   tests in `units/lib-reference-checks.nix`. Extend
   `clusters/test-helm.nix` and `tests/helm-test-chart` with a toggled
   template of a foreign kind and a provider instance. Run `nix run
   .#kix -- check homelab-kind` to confirm no manifest moves.
7. **Docs.** `reference/helm-and-imports.mdx` (both argument tables and
   the `crds` row), `reference/validation-checks.mdx` (check 21),
   `explanation/helm-integration.mdx` (trade-offs and the DAG section),
   `reference/secrets-crds-and-rbac.mdx` (the fields a declaration
   exposes), the how-to "Use Helm charts through the Kix Helm bridge",
   and `kix/lib/architecture.md` (`helm.nix`, `core/resource.nix`).
8. **Skills.** `kix-migration` (the Tier 1 and Tier 2 rows and the
   `out.crds` bullet), `package-review` (C18), and `package-authoring`
   (the tier guidance). Correct the comment at the top of
   `kix/packages/experimental/smartctl-exporter/default.nix`, which says
   a chart resource cannot take the dependency, and keep that package on
   `kix.monitor`.
9. **Records.** A change record of kind `added` with `library =
   ["kix.helmChart", "scope.helm.importChart"]`. `ROADMAP.md`: add the
   item and mark it done, and add the three out-of-scope points above
   under Open design questions. Delete
   `housekeeping/2026-10-02-chart-cannot-render-another-packages-kinds.md`.
   Run `scripts/copy-pass`, then archive this doc.

## Decisions for the maintainer

1. **Should the user name the dependency, or should Kix find it?** When a
   chart renders a `ScaledObject`, Kix can see which instance in the
   cluster declares that kind. It could link the two with nothing
   written. But Kix settles which instances exist and who depends on whom
   before it renders any chart, so a link found after rendering would be
   a deploy dependency that the rest of Kix never saw: an optional
   operator would not switch on, and removing the operator would break a
   chart that never mentions it. Recommended: the user names the
   dependency in one word, Kix matches the kinds, and when the name is
   missing the error prints the line to add.

2. **What should the argument be called?** The evaluator suggested
   `crdProviders`. In the recommended design the value is a list of
   dependencies and no longer a map, and Kix already uses `crds` for the
   CRDs a package offers to others. Recommended: `crdsFrom`, which reads
   as "take CRD declarations from these".

3. **Should naming a dependency for its kinds also open the network to
   it?** Inside a package, a chart import already has a `deps` list. It
   means "the chart's pods connect to these", and Kix writes network
   policy that allows it. Reusing that list would save an argument, but
   naming KEDA to link a `ScaledObject` would also let the chart's pods
   reach the KEDA operator. Recommended: no. Keep two arguments, one for
   kinds and one for connections.

4. **How much should a chart's custom resource inherit from the
   operator's declaration?** A declaration says more than "apply me after
   the CRD". It can say when a resource counts as ready, whether deleting
   it loses data, how much quota it uses, and how network policy treats
   it. A resource built in a package gets all of that. Recommended: a
   chart's resource gets all of it too, so the deploy waits for a
   chart-rendered database the way it waits for a native one. The
   alternative is ordering only, which is smaller and leaves chart
   resources second-class.

5. **What happens when two named dependencies declare the same kind?**
   This is rare. It happens when two monitoring operators both carry the
   ServiceMonitor kind. Kix could take the first one listed, or stop.
   Recommended: stop and name both. Inside a package the author can pass
   the single declaration they mean. An inline chart has to name one
   dependency or move into a package.

6. **Inside a package, should a chart import link to every dependency the
   package takes, with nothing passed?** A package that takes
   `prometheus` and imports a chart could have the chart's ServiceMonitor
   linked with no argument at all. That is less to write, and the import
   would read dependencies the code never hands it. Recommended: no for
   now. Require `crdsFrom`, as `deps` is required for connections. A
   forgotten one fails the build and prints the fix.

7. **Does the advice for Kix's own packages change?** Today the docs and
   the review checklist say: switch the chart's toggle off and build the
   resource with the owner's builder. That stays the better choice for a
   package Kix maintains, because the package then controls the resource.
   Recommended: present `crdsFrom` as the way to consume a chart
   unchanged, and keep the current advice for packages in this
   repository.

## Open questions

- A named dependency whose kinds the chart never renders is silent.
  Archive doc 117 (Q2) asked for a warning in that case. A values toggle
  would make it fire on correct definitions, so it is left out here.
- A chart's own custom resources depend on the chart's CRD by an inferred
  edge and do not pass through the chart's own declaration, so they carry
  no readiness rule. The same routing would fix that. It changes
  manifests of existing clusters, so it belongs in its own change.
