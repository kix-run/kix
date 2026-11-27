# 101: Monitoring Provider Landscape & Auto-Wiring

**Status:** Brainstorm
**Related:** `100_package_dsl_ergonomics_survey.md` (finding D2 spawned this), `interesting_thoughts/49_topology_aware_monitoring.md` (long-horizon vision), `97_service_contract_primitives.md` (capability/contract pattern), `92_declarative_network_policy_intents.md` (enforcer-agnostic intent pattern that monitoring should rhyme with)

Spun out of `100 §D2`. Doc 100 proposes flipping the default so that any workload with a container port named `metrics` auto-emits a ServiceMonitor into the monitoring capability's namespace. That shortcut assumes prometheus-operator. The whole point of this doc is to ask: **what does "monitoring" actually look like if we intend to support more than one provider, and which slice of that is worth auto-wiring?**

Not a design doc. Surveys the provider space, separates common shape from provider-specific shape, and flags decisions that must be made before we can write an RFC.

---

## 1. Status quo in kix

- `kix.monitor` (`kix/lib/compose.nix:822`) — build-entry helper. Packages opt in by adding `(kix.monitor { service = "service"; port = "metrics"; alerts = {...}; })` to their `build` list. It takes a `prometheus` DI dep (`prometheus ? null`) and calls `prometheus.out.mkServiceMonitor` / `prometheus.out.mkPrometheusRule`. When `prometheus` is not resolved in the cluster, the helper emits `null`.
- `modules/monitoring.nix` — cluster-level capability module. Wires prometheus-operator, prometheus, alertmanager, node-exporter, kube-state-metrics, grafana, loki, promtail as sibling instances in a `monitoring-system` namespace. This is where the `prometheus` DI provider lives.
- Per-package boilerplate — the immich/coredns/node-exporter/harbor/valkey pattern is still:
  ```nix
  prometheus ? null,
  ...
  serviceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor ... else null;
  ```
  `kix.monitor` is the intended escape hatch, but adoption is patchy and the CRD kind (ServiceMonitor) is baked into the helper's call surface.

Two implicit assumptions in the status quo:

1. **The monitoring provider is prometheus-operator.** The DI dep is named `prometheus`; the `out.mkServiceMonitor` / `out.mkPrometheusRule` shape mirrors its CRDs.
2. **There is at most one monitoring provider per cluster.** A single DI name (`prometheus`) can only bind to one instance in one module.

Both assumptions are fine for today's clusters. They will not survive contact with a second provider. This doc is about what happens when they don't.

---

## 2. Provider landscape

Six plausible provider archetypes, roughly in order of likelihood we actually see them:

### 2.1 prometheus-operator (standalone)

- **Scrape-target shape:** `ServiceMonitor` (picks by service-selector + endpoint list), `PodMonitor` (picks by pod-selector), `Probe` (blackbox).
- **Rules/alerts shape:** `PrometheusRule` — groups of `{ alert | record, expr, for, labels, annotations }`.
- **Namespacing:** CRDs are namespaced. The Prometheus CR has `serviceMonitorNamespaceSelector` / `ruleNamespaceSelector` that decide which namespaces to watch. Default-deploy patterns vary: kube-prometheus-stack uses "watch all namespaces"; tightly-scoped setups pin to a label.
- **Discovery:** selector-based. Operator reconciles CRDs into the Prometheus scrape config.
- **Label conventions:** the CRD itself doesn't care, but operator installations typically require a `release: <prom-release>` label on CRs so the Prometheus CR's `serviceMonitorSelector` matches. **Dropping or mismatching that one label is the single most common reason ServiceMonitors are silently ignored.**

### 2.2 kube-prometheus-stack (bundle)

Same CRDs as 2.1 — it *is* prometheus-operator — plus bundled Grafana, Alertmanager, node-exporter, kube-state-metrics, and a pile of default rules/dashboards. From an auto-wiring standpoint identical to 2.1; from a composition standpoint relevant to doc 40 (composite packages), not this one.

### 2.3 VictoriaMetrics operator

- **Scrape-target shape:** `VMServiceScrape` / `VMPodScrape` / `VMProbe`. Shape is deliberately near-identical to ServiceMonitor/PodMonitor/Probe — a ServiceMonitor and a VMServiceScrape can be diffed almost field-for-field.
- **Rules/alerts shape:** `VMRule`. Also near-identical to `PrometheusRule` (groups of rules, same `expr`/`for`/`labels`/`annotations`).
- **Namespacing:** same model as prometheus-operator — CRDs are namespaced, the `VMAgent` / `VMCluster` CR decides which namespaces to watch.
- **Discovery:** selector-based, same as prometheus-operator.
- **Label conventions:** no hard `release:` requirement by default, but the `VMAgent` CR's `serviceScrapeSelector` still has to match. Some shops run both operators and differentiate by the selector label.

Crucially: **VM operator also honors regular ServiceMonitor/PodMonitor CRDs** (converts them internally), so a ServiceMonitor-emitting kix package works out of the box with VM operator in most setups. VMServiceScrape is only needed when a user wants VM-specific fields (`vm_scrape_params`, etc.).

### 2.4 Grafana Alloy (config-based)

- **Scrape-target shape:** none as CRDs. Alloy is configured via a River/HCL-ish config file (`prometheus.scrape`, `prometheus.operator.servicemonitors`, etc.). In practice, most Alloy deployments **also** consume prometheus-operator CRDs via the `prometheus.operator.*` components — so effectively Alloy can either be given CRDs (and behaves like prom-operator for scrape discovery) or be given inline config.
- **Rules/alerts shape:** alerts live in an external rule file consumed by Mimir/Loki/Tempo rulers, not Alloy itself. PrometheusRule CRDs are supported via the mimir-distributor path in some setups.
- **Namespacing:** Alloy itself is typically a single DaemonSet + a few Deployments in one namespace. Its config is cluster-wide.
- **Discovery:** static (config-defined) OR CRD-based (same CRDs as prom-operator).
- **Label conventions:** none by itself; CRD path inherits prom-operator conventions.

Observation: "Alloy as a provider" ≈ "prom-operator CRD consumer + config-managed collector." For kix, Alloy is less a distinct provider and more a *collector* that still reads ServiceMonitors.

### 2.5 OpenTelemetry Collector

- **Scrape-target shape:** receivers in the collector config — `prometheusreceiver` is one of many. Targets are expressed as either static scrape configs, Kubernetes SD, or (via `targetallocator`) dynamic CRD-watched targets.
- **Rules/alerts shape:** OTel doesn't own alerting; alerts live downstream (in whatever ingests the metrics — Prometheus, Mimir, Datadog, Grafana Cloud).
- **Namespacing:** one or a few collectors per cluster. Config is collector-scoped.
- **Discovery:** service-discovery + relabel rules, or CRD-based via the OpenTelemetry Operator's `TargetAllocator` (which also watches ServiceMonitor/PodMonitor).
- **Label conventions:** OTel semantic conventions on resource attributes (`service.name`, `service.namespace`), which is a different conceptual layer than Prometheus labels — it's about how the *metric* is tagged, not how the *target* is discovered.

Observation: for scrape *targets*, OTel + target-allocator looks like "another consumer of ServiceMonitor/PodMonitor." For *semantic resource tagging*, it's a separate concern kix could help with (inject `service.name` annotations at workload build time).

### 2.6 Fallback: `prometheus.io/scrape` annotations

- **Scrape-target shape:** annotations on Pods or Services (`prometheus.io/scrape: "true"`, `prometheus.io/port: "9090"`, `prometheus.io/path: "/metrics"`).
- **Rules/alerts shape:** external — live in whatever Prometheus config is scraping.
- **Namespacing:** none. Cluster-wide Prometheus config consumes them.
- **Discovery:** Prometheus kubernetes_sd_config with relabel rules matching the annotations.
- **Label conventions:** the annotation keys themselves are the convention.

This is the dumbest, most portable shape. If all a cluster has is "some Prometheus somewhere scraping annotated pods," the only thing the package needs to do is stamp three annotations. Works against prom-operator (not used), VM (optional), Alloy (optional), OTel (optional), and plain Prometheus (default). If we want *one* universally-safe auto-wiring, this is it.

---

## 3. What's common, what's provider-specific

### Common subset (per-workload declaration)

What every provider ultimately needs to know about a *workload* is small:

- a **port** (number or name) exposing metrics;
- a **path** (usually `/metrics`);
- a **scheme** (http / https, possibly with TLS config);
- an **interval** / **timeout** (optional);
- a **selector** of the pod (derivable from the workload in kix — we already have `out.selector`);
- optional **relabelings** / **metricRelabelings**;
- optional **basic auth / bearer token** references.

That is a shape kix already has enough information to render. Every CRD-backed provider can be produced mechanically from this shape; the annotation fallback can be produced from a strict subset of it.

### Common subset (rules/alerts)

- a name,
- a PromQL-ish `expr`,
- an optional `for`,
- labels + annotations,
- optional `runbook_url` / `summary` / `description` (convention).

PrometheusRule and VMRule are bit-for-bit the same shape. Recording rules sit alongside alerting rules in both. This is the *lower-risk* slice to standardize — the alert shape barely differs across providers.

### Provider-specific

- **CRD kind + apiVersion** (ServiceMonitor vs VMServiceScrape vs PodMonitor vs nothing)
- **Provider-required labels** (`release: kube-prometheus-stack` etc.)
- **TLS / auth blocks** — prom-operator's `tlsConfig` vs VM's `tls_config`, small schema differences
- **Advanced fields** — `honorLabels`, `honorTimestamps`, VM's `vm_scrape_params`, prom-operator's `attachMetadata`
- **Where CRs can live** — prom-operator + VM both support cross-namespace watch, but the enabling CR (Prometheus / VMAgent) is where the decision is made, not on the ServiceMonitor itself. The package can't know; only the cluster can.
- **Collector-config providers (Alloy, OTel without target-allocator)** — don't have a per-workload CR at all. Anything we "auto-emit" would have to be annotations or a config fragment the collector assembles elsewhere.

---

## 4. Options for how kix represents monitoring

Rough option space. Not a ranked list; each has tradeoffs that depend on answers to §5.

### 4a. Structured `meta.monitoring` attrset, rendered by the resolved provider

```nix
meta.monitoring = {
  port = "metrics";        # or int
  path = "/metrics";
  interval = "30s";
  scheme = "http";
  rules = [ /* alert/recording rules */ ];
  # maybe: tls = { ... }; auth = { ... };
};
```

The active monitoring capability resolves in DI, and its provider module (prom-operator, VM, annotation) is responsible for *rendering* `meta.monitoring` into whatever shape it produces. Packages never mention ServiceMonitor.

Matches the pattern 92 set for netpol: **intent at the package, render at the enforcer.**

Tradeoffs:
- Clean. Matches existing kix idioms.
- Requires a defined schema — "what fields are supported" becomes a contract we maintain.
- Escape hatches (e.g. prom-operator's `honorLabels`) push us to either (a) accept lossy rendering, (b) add provider-conditional blocks inside `meta.monitoring`, or (c) keep `kix.monitor` around for the advanced case and make `meta.monitoring` the 80% path.

### 4b. Keep `kix.monitor`, make it provider-pluggable

Same helper call surface packages already use, but route `out.mkServiceMonitor` through a provider adapter: `prometheus.out.mkScrapeTarget` becomes a generic call that the resolved provider implements. If the provider is VM, it returns VMServiceScrape; if annotation-fallback, it returns annotations applied to the Service; if Alloy without CRDs, it may return `null` and instead push config into a collector configmap.

Tradeoffs:
- Smaller, more surgical change — doesn't touch package authoring shape much.
- Doesn't fix the `prometheus ? null` boilerplate, just renames it. Consumers still opt in per-package.
- Doesn't address "who owns the CR" (see §5.3).

### 4c. Auto-emit from a workload convention (§D2's proposal)

Workloads with a container port named `metrics` implicitly participate. Opt out with `meta.monitoring = false`. Opt in to richer shape with `meta.monitoring = { ... }`.

Tradeoffs:
- Highest leverage — covers the common case with zero per-package boilerplate.
- Relies on a convention (port name). Packages with multiple metrics ports or non-standard paths would still need explicit declaration.
- Risks "magic" — authors see `ServiceMonitor`s appear without having written anything that mentions monitoring. Scorecard-visible but still surprising.

### 4d. Annotation-only fallback as the universal floor

Always stamp `prometheus.io/scrape` + `port` + `path` on the Service (or Pod template) when monitoring info is known. Richer providers *additionally* emit CRDs; annotation-only providers get the annotations and nothing else.

Tradeoffs:
- Works against literally every provider (including "no operator, just a Prometheus StatefulSet").
- Cheap, no DI required — annotations are data attached to resources the package already owns.
- Leaves the CRD story unsolved; something still has to emit ServiceMonitor/VMServiceScrape for advanced setups.

### 4e. No provider-specific emission from packages — cluster sweeps

Packages only declare `meta.monitoring`. The *cluster* compilation phase walks the instance graph, finds all workloads with monitoring metadata, and the active provider's module emits all CRs centrally. Mirror of netpol's current design where the enforcer owns CR emission.

Tradeoffs:
- Matches 92 architecture closely. Ownership is unambiguous — monitoring capability owns its CRs.
- Namespacing gets easier: CRs can live in the monitoring namespace via `forNamespace`, or next to the workload, as a cluster-level policy.
- Requires a graph walk — more machinery, similar to what netpol already has.
- Nicely handles "multiple providers": each resolved provider does its own sweep.

Options 4a, 4c, 4d, 4e are composable. A realistic end state might be **4a + 4c + 4e**: structured intent on `meta`, auto-discovered from port conventions when absent, rendered by the provider during a cluster-level sweep. 4b is the incremental path if we're not ready to commit to 4e.

---

## 5. Open questions

### 5.1 Shape of `meta.monitoring` — structured vs free-form?

Structured (`{ port, path, interval, rules, ... }`) lets providers render consistently but forces us to own the schema. Free-form (`meta.monitoring = true` / `false`, with everything else opt-in via `kix.monitor`) is smaller but pushes configuration back into per-package code.

Strong lean: **structured, thin**. Keep the schema to the common subset in §3; allow a `providerOverrides = { prometheus-operator = {...}; victoriametrics = {...}; }` escape hatch for provider-specific knobs rather than letting them leak into the main attrset.

### 5.2 Can a cluster have multiple simultaneous providers?

Plausible real setups:
- prom-operator for app metrics + VM for long-term storage (VM agent scrapes the same targets differently).
- OTel collector for traces + prom-operator for metrics (separate concerns, both want ServiceMonitors-ish).
- Alloy on edge clusters + prom-operator on central cluster, same packages deployed to both.

If yes, the DI shape can't be `prometheus ? null` — it needs to be `monitoring ? [ ]` or multiple named slots. The "auto-wiring" logic becomes "for each resolved provider, emit its shape for every monitored workload."

Open. Worth deciding early because it changes the DI model, not just the rendering.

### 5.3 Who owns the CR?

Two patterns in kix today:

- **Producing package owns it.** `kix.monitor` today emits the ServiceMonitor into the package's own namespace. Cross-namespace watch on the Prometheus CR makes this work.
- **Capability owns it.** Netpol (doc 92) puts CiliumNetworkPolicies in the monitoring/enforcer's namespace via `scope.forNamespace`. The producing package declares *intent*, the enforcer emits the CR.

Trade:
- Package-owned keeps everything one package touches co-located. Downside: every monitored namespace accumulates foreign CRDs (ServiceMonitor, VMServiceScrape) that the package author may not even know about.
- Capability-owned keeps the namespace clean and lets the monitoring module see the whole picture (useful for deduplication, cluster-wide labels, ownership refs). Downside: one more piece of indirection; namespace-selector-watching operators have to be configured to read from the monitoring namespace *or* wherever the CRs land.

Current `kix.monitor` is package-owned. Doc 100's §D2 hook proposed capability-owned via `forNamespace`. Netpol precedent argues capability-owned. Probably the right call, but needs the multi-provider decision (§5.2) first — with one provider, either works; with many, capability-owned scales better.

### 5.4 Is "port named `metrics`" enough heuristic?

Packages we checked:
- `coredns` — `metrics` port at 9153. Fits.
- `node-exporter` — `metrics` at 9100. Fits.
- `immich` — not today; metrics are on the same port as the API. Does not fit cleanly.
- `harbor` — multiple components, multiple metrics ports. Needs per-container/per-workload declaration.
- `valkey` — metrics via an exporter sidecar container on a separate port. Fits if we recognize any container's `metrics` port, not just the primary one.

Verdict: the heuristic covers maybe 60% of packages. The rest need explicit `meta.monitoring.port = 2112` or similar. Which is fine — heuristic for the common case, explicit override for the rest.

Adjacent question: should the heuristic attach to the **Service** (look for a port named `metrics` on any service) or the **workload** (look for containerPort)? Services are the scrape target for ServiceMonitor; workloads are the source of truth. Probably: declare on the workload, let `service.fromWorkload` (doc 100 C1) propagate.

### 5.5 Providers without per-target CRDs — adapter or bypass?

Alloy (pure-config), OTel (pure-config), and annotation-only Prometheus have no CR to emit. Two strategies:

- **Per-provider adapter.** The provider module implements a `mkScrapeTarget` that, for CRD-less providers, either stamps annotations on the Service or appends to a collector configmap. Uniform interface, different backends.
- **Bypass for CRD-less providers.** These providers implement config-file scraping externally (static config in their package), and kix's monitoring story simply doesn't cover them automatically. Acceptable if we treat annotations (§4d) as the universal floor and CRD emission as the value-add.

Strong lean: **adapter**. Otherwise "monitoring works for some providers" is a leaky contract.

### 5.6 Alerts/rules: same-namespace or centralized?

PrometheusRule and VMRule are namespaced. Most packages want their alert rules living next to the workload. But some rules are *cross-package* — e.g. "if coredns errors correlate with API errors somewhere" — and don't have a single obvious owner.

Probably: per-package rules ship in the package's namespace; cross-package rules (doc 49, topology-aware) live in the monitoring capability's namespace. Clean split.

### 5.7 Relationship to topology-aware monitoring (doc 49)

Doc 49 is about *generating* monitoring config from the dependency graph (blast-radius alerts, inhibition rules, dependency-chain dashboards). This doc is about *rendering* declared monitoring intent against multiple providers. They stack: first, we need a stable way to talk about monitoring per-workload (this doc); *then* graph-derived rules become "synthetic `meta.monitoring.rules` entries computed at cluster level" — same rendering path, different source. Good architectural signal that the rendering layer should be provider-agnostic regardless of where the intent comes from.

### 5.8 Relationship to service contracts (doc 97)

Monitoring capability exposed via `provideService` / `mkServiceRef` fits naturally: `scope.requireCapability "monitoring"` resolves to whichever provider the cluster has configured, with a typed `out` interface the `kix.monitor` helper calls into. This is the same shape as the database/cache capabilities doc 97 defines. Suggests the right layering: 97's contract mechanism is the substrate, monitoring is one of the first real capabilities to use it.

---

## 6. Decisions that need to land before a design doc

In rough dependency order:

1. **§5.2: multi-provider support — yes/no.** Changes DI shape. Everything downstream depends on it.
2. **§5.3: CR ownership — package or capability.** Changes which namespace holds foreign CRDs. Netpol precedent + multi-provider leaning → capability.
3. **§5.1: `meta.monitoring` schema — structured/thin + providerOverrides.** Decide the field list (port/path/interval/scheme/rules/basicAuth/tls) and draw the line for what goes into `providerOverrides`.
4. **§5.5: CRD-less provider strategy.** Adapter vs. bypass. If adapter, define the `mkScrapeTarget` contract to cover both CRD and config-fragment backends.
5. **§5.4: port-name heuristic — default on or off.** Can be flipped later, but deciding sets the tone for what "good monitoring coverage" means in the scorecard.

Only after these — and after doc 97 lands a contract primitive, if we want to lean on it — does it make sense to write a monitoring RFC / design doc.

---

## 7. Non-goals for this brainstorm

- Designing the DI shape. That's an RFC once §5.2 and §5.3 are answered.
- Picking winners between providers. We plan to support the ones users actually bring.
- Building topology-aware monitoring (doc 49). That stacks on top of whatever this produces and should not block it.
- Dashboards (Grafana ConfigMaps / JSON). Orthogonal concern; same rendering-by-provider pattern but different provider set (Grafana, Datadog, etc.).

---

## 8. Summary

kix already has a workable single-provider monitoring story (`kix.monitor` + `modules/monitoring.nix`) but it silently bakes prometheus-operator into both the DI name and the helper's output shape. The provider landscape splits cleanly into CRD-backed (prom-operator, kube-prometheus-stack, VM) and config-backed (Alloy, OTel, annotation-fallback), with a near-identical per-workload intent shape across all of them and a near-identical alert-rule shape across the CRD-backed ones.

The highest-leverage direction looks like: structured `meta.monitoring` intent on packages, capability-owned rendering at the cluster level (mirror of netpol 92), auto-discovery via port-name heuristic as the common-case default, with explicit overrides for the 40% that don't fit. That shape composes with doc 97's capability contracts and sets up doc 49's topology-aware monitoring without rework.

But we should not commit to it until §5.2 (multi-provider), §5.3 (ownership), and §5.5 (CRD-less providers) are answered.
