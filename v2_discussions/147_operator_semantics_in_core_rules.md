# 147: Operator semantics in core rules

**Status:** Draft. Decision required from Adam: option A or option D in §7.
**Related:** `131_fact_kinds_and_operand_attribution.md` (the `factBehavior` declaration this proposal copies), `101_monitoring_provider_landscape.md`, `135_validation_layers_audit.md`
**Precedent:** `archive/83_package_owned_scorecard_rules.md` (rule code inside packages: not settled, rule left in the library), `archive/128_capability_ownership_decomposition.md` (fingerprints became package declarations)
**Origin:** `housekeeping/2026-09-20-lib-rules-carry-monitor-operator-semantics.md`

## 1. What this document is for

Three places in the Kix core library name the resource kinds of specific
operators. The document explains why that is a problem, why the fix we used
for two similar problems does not apply here, and what the choices are. It
ends with one decision to make.

You do not need to know Kix well to follow it. §2 defines every term the
rest of the document uses.

## 2. Terms

**Kubernetes resource and kind.** Everything in a Kubernetes cluster is a
resource: a Deployment, a Service, a Secret. The resource's type is its
kind. A Service resource has kind `Service`.

**Custom resource and CRD.** Kubernetes lets software add new kinds. A
CustomResourceDefinition (CRD) declares the new kind and its fields. A
resource of that kind is a custom resource. For example, the StackGres
database operator adds the kind `SGCluster`.

**Operator.** A program that runs inside the cluster and acts on custom
resources. The StackGres operator watches `SGCluster` resources and creates
the database pods they describe. Each operator decides what fields its
custom resources have and what they mean.

**Kix package.** A Nix file that describes how to run one piece of software
in Kubernetes. A package produces resources. `stackgres-operator` is a
package; so is `grafana`.

**Cluster definition.** The file that lists which packages run in a
cluster, in which namespaces, with which settings. Kix reads it and builds
every resource for the cluster.

**Core library.** `kix/lib`. The code that turns packages and a cluster
definition into resources. It is meant to know Kubernetes, not any
particular operator. When it names an operator's kind, adding a similar
operator means editing the core library, and packages stop being
self-contained.

**Typed CRD builder.** The way a package that owns a CRD lets other packages
create custom resources of that kind. The owning package calls `mkCRD` or
`mkCRDRef` once. That returns a builder. Other packages call the builder to
make custom resources. Every resource made this way carries a record of
which CRD it came from and must wait for that CRD to exist. The chain from
CRD declaration to built resource is called the typed chain.

**Declarations on the CRD builder.** Because every custom resource of a kind
passes through its builder, the builder is where the owning package can
state facts about the kind. Two exist today:

- `factBehavior` says what the operator does with network addresses found
  in the custom resource, so Kix can derive network policies (doc 131).
- `readiness` says which status field or condition means "this resource is
  ready", so `kix deploy` knows when to continue.

Both ride the typed chain onto every resource. The core library reads the
declaration; it does not know the operator.

**Scorecard rule.** A check the core library runs over the built resources
before anything is deployed. A rule produces findings with a severity.
Rules live in `kix/lib/rules/`. Some look at one resource at a time; some
look at the whole cluster.

**Network policy and "netpol".** A Kubernetes resource that says which pods
may talk to which. Kix derives these from the dependencies between
packages, so a workload can reach only what it depends on. Inside Kix this
feature is called netpol. The Kubernetes kind is `NetworkPolicy`; the
Cilium network plugin adds its own kind, `CiliumNetworkPolicy`, with more
features. The package that enforces policies fills the
`network-policy-enforcer` role, and the netpol code asks that package how
to write a policy instead of knowing Cilium itself.

**Role and role provider.** A named job in a cluster, such as
`network-policy-enforcer` or `dns`. A package claims a role in its
metadata. Core code that needs the job done looks up the provider through
the role and reads its outputs. That is how core stays free of package
names.

**ServiceMonitor.** A custom resource from the prometheus-operator project.
It tells a metrics collector which Services to scrape, by label selector,
in which namespaces, on which port. Many collectors accept it, not only
Prometheus: VictoriaMetrics converts it and also ships its own copy,
`VMServiceScrape`, with the same fields. `kix.monitor` is the Kix helper
that builds one for a package.

**Helm chart and `helm-dag.nix`.** Helm is the common Kubernetes packaging
tool. Some Kix packages wrap a Helm chart instead of writing resources by
hand. Kix renders the chart and then reads the result to work out which
resource depends on which; that inference lives in `helm-dag.nix`. Chart
resources do not pass through a typed CRD builder, so declarations on a
builder cannot reach them.

## 3. The problem

| Where | Kinds named | What the core library reimplements |
|---|---|---|
| `rules/architecture.nix`, rule `monitorSelectorMatchesService` | ServiceMonitor, VMServiceScrape | prometheus-operator's namespace selection (`any`, `matchNames`, or the monitor's own namespace), its port matching, and its skip on `matchExpressions` |
| `rules/architecture.nix`, rule `monitorsExternalService` | ServiceMonitor, VMServiceScrape | nothing; only the kind list |
| `helm-dag.nix`, edges 8 and 9 | HTTPRoute, ServiceMonitor | reads `backendRefs` and `selector.matchLabels` to draw dependencies from chart resources |

The monitor rule exists for a good reason. A ServiceMonitor selects a
Service by the Service's labels. A monitor whose selector matches no
Service collects nothing, and nothing reports that. The rule catches it
before deploy. The problem is only that the rule finds monitors by kind
name, and holds one operator's matching semantics.

## 4. What we already did for two similar problems

On 2026-09-20 two problems of the same shape were closed without touching
the rule logic:

- **Readiness.** The CLI had a hardcoded list saying which condition means
  "ready" for StackGres, Gateway API and Cilium kinds. Now each owning
  package declares `readiness = { condition = { type; status; }; }` on its
  CRD builder, and the CLI reads the declaration.
- **The network policy rule.** A rule accepted `NetworkPolicy` or
  `CiliumNetworkPolicy` by name. Now the enforcer package lists its policy
  kinds in its role output, and the rule reads that list.

The natural question is why the monitor rule did not get the same fix.

## 5. Why the monitor rule is different

- **It is a cluster rule, not a fact about one resource.** Readiness is a
  fact about one custom resource that the CLI reads back. The monitor rule
  joins two sets of resources, monitors and Services, across namespaces.
  To do the join it needs the operator's matching semantics.
- **The semantics are shared, not owned by one package.** VictoriaMetrics did
  not invent a scrape vocabulary. `VMServiceScrape` copies the
  ServiceMonitor fields one for one, and the VictoriaMetrics operator also
  reads ServiceMonitor itself (doc 133). Grafana Alloy and the
  OpenTelemetry target allocator read it too. The contract belongs to the
  ecosystem, in the same way the Gateway API's `HTTPRoute` does. Nobody
  objects to `HTTPRoute` in `vocab/compose.nix` for that reason.
- **Every monitor Kix renders already goes through a typed CRD builder.**
  The `prometheus-operator`, `kube-prometheus-stack` and
  `victoria-metrics-operator` packages all expose `out.mkServiceMonitor`,
  which is a CRD builder, and `kix.monitor` calls it. So the place where
  `factBehavior` and `readiness` are declared exists for these kinds today.
- **Chart-rendered monitors do not.** `helm-dag.nix` sees plain kind strings
  from the rendered chart. A builder declaration cannot reach them. Doc 131
  added a cluster-level override, `cluster.factBehavior."group/Kind"`, for
  exactly this case, and the same channel would work here.

## 6. What a rule needs to know about a kind

For the rule to keep its logic and drop the kind list, a kind has to tell
the rule four things:

1. its resources select Services by label, so the join applies;
2. where the selector is (`spec.selector.matchLabels`);
3. where the namespace selector is and how to read it (`spec.namespaceSelector`
   with `any` and `matchNames`);
4. where the port references are (`spec.endpoints[].port` and `targetPort`).

Items 2 to 4 are the same for every kind that follows the ServiceMonitor
contract. Only item 1 varies by kind. Option A follows from that.

## 7. Options

### A. A contract flag on the CRD builder (recommended)

The owning package declares on `mkCRD` or `mkCRDRef` that a kind follows a
named contract the core library already implements:

```nix
scope.mkCRDRef {
  group = "operator.victoriametrics.com";
  kind = "VMServiceScrape";
  # ...
  contracts = [ "service-monitor" ];
}
```

The builder stamps the contract on every resource made through it, in the
same way it stamps `readiness`. The rule then selects monitors by
"carries the `service-monitor` contract" and never names a kind. The core
library keeps one implementation of the ServiceMonitor contract, documented
as an ecosystem contract next to its HTTPRoute support. A cluster-level
override in the style of `cluster.factBehavior` covers chart-rendered kinds
and lets `helm-dag.nix` use the same lookup for its edges.

For: it follows the pattern that shipped three times (docs 131 and 128,
then readiness). One line per package. The rule logic does not change. A
new operator that copies the ServiceMonitor fields needs no core change.

Against: the core library still holds the semantics of one ecosystem API.
The goal becomes "no operator kind names in core; ecosystem contracts
stay". That is the honest version of the goal anyway.

### B. Field paths instead of a contract name

The declaration spells out the paths (`selectorPath`,
`namespaceSelectorPath`, `portsPath`) so the core library knows no contract
by name. Rejected: the namespace selector rules (`any` wins over
`matchNames`; empty means the monitor's own namespace) cannot be written as
paths. Core would still implement the dialect, and the paths would be
ceremony. Worth revisiting only if a second dialect appears. `PodMonitor`
and `VMPodScrape` select pods rather than Services, but that is a second
contract under option A, not a reason for B.

### C. Packages ship the rule

Doc 83 framed this and left it unsettled. Rule code inside packages needs a
collector, a severity model per package and a test story, for a benefit
that so far has been one or two rules. Nothing since has changed that
count. Not pursued here.

### D. Keep the kind list, and say why

Treat ServiceMonitor and VMServiceScrape as core vocabulary, as HTTPRoute
already is, and say so in a comment. Cheapest. Against: the list is still a
list. The next scrape kind (`PodMonitor` is the obvious one) means editing
two rules and the Helm dependency code.

## 8. The decision to make

Option A or option D.

Option A costs roughly a day: the `contracts` argument and its validation
in `core/resource.nix`, the stamp in `mkCRDBuilders`, the override channel
in `eval/cluster.nix`, the two rules and two `helm-dag.nix` edges reading
the lookup, declarations in the three monitoring provider packages, and the
docs (`HANDBOOK`, `FEATURE-CATALOG`, the kix-migration skill).

Option D costs a comment.

## 9. Open questions

- **Annotation or evaluation-only attribute?** Readiness is stamped as an
  annotation because the CLI reads it at deploy time. Nothing reads a
  contract at deploy time, so an evaluation-only attribute would keep the
  shipped manifests clean. But rules run over the sealed manifest form.
  Check whether the rule runner can see pre-seal attributes before
  choosing.
- **Should HTTPRoute get the same treatment?** It is built without a typed
  builder in `vocab/compose.nix` and in `envoy-gateway`, and the
  `helm-dag.nix` edge uses the kind name. Same shape, less pressure:
  nothing else copies the HTTPRoute fields.
- **PodMonitor and VMPodScrape.** A second contract, `pod-monitor`, with a
  different join (pods, not Services). Out of scope until a package ships
  one.
