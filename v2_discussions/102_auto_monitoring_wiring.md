# 102: Auto-Monitoring Wiring

**Status:** Brainstorm
**Related:** `100_package_dsl_ergonomics_survey.md` (§D2, open Q4), `96_netpol_autogeneration_blindspots.md`, `97_service_contract_primitives.md`, `92_declarative_network_policy_intents.md`

Spawned from doc 100 §D2 / open question #4: the "port named `metrics` → ServiceMonitor" shortcut proposed in 100 is too provider-specific to design in isolation. This doc surveys the provider landscape and sketches a shape that lets packages stay provider-agnostic while still getting zero-config scraping in the common case.

**Not decided.** This is a design brainstorm; concrete proposals are provisional.

---

## 1. Problem statement

Every package that wants metrics scraped writes the same three-part ritual:

1. Declare `prometheus ? null` as an optional DI dep arg.
2. Compute `hasMetrics = config.metrics.enabled && prometheus != null`.
3. Emit `serviceMonitor = if hasMetrics then prometheus.out.mkServiceMonitor scope { ... selector.matchLabels = self.service.out.selector; endpoints = [ { port = "metrics"; } ]; } else null;`.

Concrete instances (pre-proposal code):

- `kix/packages/immich/default.nix:166` — `prometheus ? null` dep arg.
- `kix/packages/immich/default.nix:184` — `hasMetrics = config.metrics.enabled && prometheus != null`.
- `kix/packages/immich/default.nix:296-316` — the full `if hasMetrics then prometheus.out.mkServiceMonitor … else null` block, ~20 lines of mostly mechanical shape.
- `kix/packages/coredns/default.nix:139` — `prometheus ? null`.
- `kix/packages/coredns/default.nix:162` — `mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;` local alias.
- `kix/packages/coredns/default.nix:411-433` — the `if (config.prometheus.monitor.enabled or false) && prometheus != null then …` block.

And the annotation-scrape flavor (legacy):

- `kix/packages/velero/default.nix:376-381` — pod template annotations `prometheus.io/scrape: "true"`, `prometheus.io/port: "..."`.
- `kix/packages/openebs/default.nix:1360-1365` — same pattern, different package.

The `kix.monitor` composer at `compose.nix:838-935` collapses this to a one-liner per package when adopted — but (a) it's not adopted by most of the packages above, and (b) it's still hardwired to `prometheus.out.mkServiceMonitor`, so it doesn't help clusters that use VictoriaMetrics, OTel, or pod-annotation scrape.

The repetition is a symptom of a deeper issue: **the package is the wrong place for the provider choice**. `immich` has no opinion on how its metrics get scraped; the cluster does.

---

## 2. Personas and intents

### 2.1 Package author — "expose metrics and forget"

Wants zero config. Writes `containerPort = { name = "metrics"; containerPort = 9090; }` in the workload spec. Wants this to *just result in scraping* on every cluster that has any monitoring stack. Should not have to:

- Know which scrape provider the cluster runs.
- Import or declare a CRD (ServiceMonitor / VMServiceScrape / OTel Target).
- Add a dep arg (`prometheus ? null`).
- Write a conditional.

Is willing to specify the following when non-default: scrape path (`/metrics` is the common default; `/stats/prometheus` for Envoy, `/actuator/prometheus` for Spring), scheme (http vs https), auth (bearer token from a Secret), recording rules / alerts (these are package-intrinsic — the package author knows what to alert on).

### 2.2 Cluster operator — prometheus-operator (today's default in this tree)

Has prometheus-operator installed. Wants every `metrics` port to become a ServiceMonitor. Wants to control cluster-level scrape interval, external labels, relabeling. Doesn't want per-package churn when they change provider choices.

### 2.3 Cluster operator — alternative provider

Runs one of:

- **VictoriaMetrics**: `VMServiceScrape` / `VMPodScrape` CRs (shape is nearly identical to ServiceMonitor / PodMonitor but under `operator.victoriametrics.com/v1beta1`).
- **OTel Collector with prom receiver**: wants scrape *config* injected into a shared config (no CR per target; config is the Collector's own `receivers.prometheus.config.scrape_configs` block). Or a `TargetAllocator` CR if the operator is installed.
- **Pod-annotation scrape**: legacy vanilla Prometheus, uses `prometheus.io/scrape: "true"` + `prometheus.io/port: "9090"` + `prometheus.io/path: "/metrics"` on the pod template. No CRs at all.
- **Mixed / none**: some clusters have no scraper; packages should still deploy.

"I want monitoring on" for this persona means: "whatever scraper I run, discover every package that declares a metrics port and pull it in." The package shouldn't care which.

---

## 3. Provider landscape survey

| Provider | Shape wanted | Namespaced? | Needs Service? | Needs CRD? |
|---|---|---|---|---|
| prometheus-operator `ServiceMonitor` | `{ selector, namespaceSelector, endpoints: [{ port, path, scheme, interval, tlsConfig?, bearerTokenSecret? }] }` | yes (sidecars Prometheus) | yes (selector.matchLabels → Service labels) | yes |
| prometheus-operator `PodMonitor` | Same shape but selects pods directly | yes | no (selects pods) | yes |
| VictoriaMetrics `VMServiceScrape` | Near-identical to ServiceMonitor | yes | yes | yes |
| VictoriaMetrics `VMPodScrape` | Near-identical to PodMonitor | yes | no | yes |
| OTel Collector TargetAllocator `PrometheusCR` mode | Reuses ServiceMonitor/PodMonitor CRs | yes | yes | yes (PO CRDs) |
| OTel Collector inline config | `scrape_configs:` entry in Collector CR | no (cluster config) | conceptually yes | Collector CRD |
| Pod annotations (`prometheus.io/scrape`) | `metadata.annotations` on pod template | n/a | no (scraper walks pods) | no |

### 3.1 Common denominator

Everything except inline OTel config wants essentially the same tuple:

```
{ selector: <how to find the pods/service>
, port: <name or number>
, path: <default /metrics>
, scheme: <http|https>
, interval: <optional>
, auth: <none|bearerTokenSecret|mTLS>
, relabelings: <optional>
}
```

Providers differ in **where this tuple lives** (a CR namespace-scoped next to the target, or an annotation on the pod, or a line in a global config), not in what the tuple contains. That's the lever: packages declare the tuple; the provider decides where to place it.

### 3.2 Can a package be fully provider-agnostic?

Mostly yes. The awkward cases:

- **Bearer-token auth** with a non-standard secret key. ServiceMonitor-family CRs take a `bearerTokenSecret: { name, key }`; pod-annotation scrape has no analog — the scraper would need `prometheus.io/scheme` + a shared-token arrangement. A package that strictly requires token auth *cannot* work behind pod-annotation scrape without cluster-level glue. This is a small minority.
- **mTLS-required scrape** (e.g. a sidecar that enforces mTLS on 15090). ServiceMonitor supports `tlsConfig`; pod-annotation scrape doesn't. Same minority as above.
- **Multiple metrics endpoints with different paths** (main app on `/metrics`, Envoy sidecar on `/stats/prometheus`). CRs handle this natively via `endpoints: [...]`; pod annotations only allow one `prometheus.io/path` per pod. Workaround for the pod-annotation case is a PodMonitor-style escape hatch; another is "pick one, annotate the other in a kix/lib composer."
- **Recording rules / alerts**. These are `PrometheusRule` / `VMRule` resources and live downstream of the scrape. All prom-compatible providers consume the same PromQL — so the rule body is portable; only the wrapper CR differs. Pod-annotation scrape has no native rule shape; rules would have to be mounted into the scraper's config.

Provisional conclusion: a package-author-facing API can cover 80% (app with one or two metrics ports, HTTP scrape, `/metrics` path) without knowing the provider. The remaining 20% (mTLS, multiple divergent endpoints, auth) needs a documented escape hatch that drops to the provider-specific CR.

---

## 4. Convention for package authors

### 4.1 Sketch from doc 100

> Inside `scope.mkDeployment/StatefulSet/DaemonSet` detect containers with a port named `metrics` (convention) and auto-emit a ServiceMonitor.

Is the port name enough? **No, not for the whole 80%.** It covers the happy path (HTTP on `/metrics`) but nothing about:

- scrape path — defaults to `/metrics` but Envoy uses `/stats/prometheus`, Spring Boot `/actuator/prometheus`, HAProxy `/-/metrics`. Default-and-override.
- scheme — default http; https needs a flag.
- interval — default cluster-level; override per-package.
- relabeling — not needed for the convention; escape-hatch.
- auth — not needed for the convention; escape-hatch.

### 4.2 Minimal convention (provisional)

A container port named `metrics` is the *signal* that the package has metrics. The *tuple* is declared by a single-attrset meta field on the port (or alongside it):

```nix
# What package authors write (provisional):
containers = [{
  name = "app";
  ports = [{
    name = "metrics";
    containerPort = 9090;
    # Optional overrides; defaults suffice for 80%.
    # path = "/stats/prometheus";
    # scheme = "https";
  }];
}];
```

Extra fields on the port (`path`, `scheme`, `interval`) would be **non-K8s** — violates the "don't invent new fields" rule in `CLAUDE.md`. So the tuple has to live elsewhere. Options:

- **(A)** `meta.monitoring = { path = "/stats/prometheus"; scheme = "http"; port = "metrics"; }` on the package. Clean, discoverable. Implicitly assumes *one* scrape tuple per package.
- **(B)** A dedicated composer, `kix.scrape { port = "metrics"; path = "/stats/prometheus"; }`, added to the `build` list (mirroring `kix.expose` / `kix.monitor`). Supports multiple tuples naturally.
- **(C)** Annotations on the Service (non-K8s-but-k8s-ecosystem: `kix.dev/scrape-path`, `kix.dev/scrape-scheme`). Cluster-side monitoring provider reads the Service and generates the right CR.

Leaning **(B) + (C)**: (B) keeps the author's surface composable, (C) is how the provider-side discovers the tuple without parsing Nix. (A) is too restrictive for packages with multiple metrics ports (§7).

The happy path stays zero-config: if a container has a port named `metrics` and no `kix.scrape` is called, the package author gets an auto-scrape with defaults. If they need to override, they call `kix.scrape { ... }` explicitly.

### 4.3 Escape hatches

Package authors who need the current explicit shape keep it:

- `prometheus ? null` dep arg — still works, still emits whatever they hand-write.
- `kix.monitor` composer — keeps its current shape, now *also* provider-polymorphic (§5).

---

## 5. Discovery mechanism — mirror netpol

### 5.1 The netpol pattern

`kix/lib/netpol.nix:402` (`processInstance`) receives a `networkPolicyEnforcer` handle and calls `enforcerApi.mkPolicy` / `enforcerApi.translateIntentRules` on it. The enforcer is discovered in `kix/lib/eval/cluster.nix` — if a package provides one (e.g. cilium), it's resolved to `enforcerOut`; if absent, `networkPolicyEnforcer = null` and the whole policy-generation step short-circuits. Packages never name cilium directly.

This is exactly the shape monitoring wants.

### 5.2 Monitoring capability (provisional)

Introduce a **monitoring capability** at the cluster level. A package that provides scraping (prometheus-operator, victoriametrics-operator, otel-operator, …) exposes `out.monitor` with the provider's API:

```nix
out.monitor = {
  mkScrape = { scope, selector, namespace, endpoints, labels }: <resource or null>;
  mkPodScrape = { scope, selector, namespace, endpoints, labels }: <resource or null>;
  mkRule = { scope, groups, labels }: <resource>;
  # capability flags so kix/lib can know what's supported
  capabilities = {
    supportsBearerToken = true;
    supportsMtls = true;
    supportsRelabeling = true;
  };
};
```

`kix/lib/eval/cluster.nix` resolves whichever package provides a monitor capability into a cluster-level `monitoringProvider` (parallel to `enforcerOut`). `processInstance` (or a new `processMonitoring`) calls `monitoringProvider.mkScrape` for every workload that has a `metrics` port **iff** `monitoringProvider != null`.

Cluster with no monitoring stack: `monitoringProvider = null`, scrape emission is a no-op, no per-package code change needed.

Cluster with pod-annotation scrape (vanilla Prometheus): the "provider" is a thin shim that generates no CRs and instead **mutates the workload's pod template** to add `prometheus.io/*` annotations. Same hook point; different implementation.

Cluster with VictoriaMetrics: the provider emits `VMServiceScrape` CRs shaped identically to ServiceMonitor. Same hook point.

### 5.3 Where the hook fires

Mirror netpol exactly. Inside `scope.mkDeployment/StatefulSet/DaemonSet`:

1. Detect a container with `ports[*].name == "metrics"`.
2. If a `kix.dev/scrape-*` annotation was set on the workload by an earlier `kix.scrape` call, pick up the tuple; else use defaults (`/metrics`, `http`).
3. If `monitoringProvider != null`, call `monitoringProvider.mkScrape { ... }`. Splice the result into the workload's `extraDeps` (same as `_generatedNetpol`). Result: the Service scrape CR is in the workload's store-path context; wave ordering and netpol-via-context both work automatically.
4. Else: skip, emit no scrape.

The package author never sees `monitoringProvider`. It's plumbing, same as `networkPolicyEnforcer`.

---

## 6. Opt-out vs. opt-in

Doc 100 proposed `meta.monitoring = false`. Evaluating:

- **Default on when a port is named `metrics`**: opt-in by signal, opt-out by flag. This mirrors netpol's default-on behavior and is consistent with "automation prevents mistakes, not saves lines" (CLAUDE.md). Packages that expose a metrics port but specifically don't want it scraped (very rare — usually debug-only metrics) set `meta.monitoring.enabled = false`.
- **Per-port granularity**: needed. A package with `metrics` + `metrics-debug` ports (immich has `metrics-api` + `metrics-ms`, see immich `default.nix:303-311`) wants both scraped; a package with `metrics` + `admin` where `admin` also exposes metrics behind auth wants only `metrics` scraped. The signal already handles this cleanly — only ports named `metrics` or matching a pattern (`metrics` | `metrics-*`) opt in.
- **Per-container granularity**: rarely needed separately from per-port. Skip for v1.

Provisional naming: `meta.monitoring = { enabled = true; portPattern = "metrics|metrics-.*"; }`.

Config-level toggle (end user, not package author): already exists at `compose.nix:566-578` as `options.metrics = kix.options.monitor` with `enabled` + `interval`. Keep it. The new auto-wiring reads the same option.

---

## 7. Edge cases

### 7.1 Sidecar containers

Envoy sidecar on 15090, app on 9090, both exposing Prom metrics. Multiple ports named `metrics` across containers in the same pod. Each becomes one `endpoints[*]` entry in the ServiceMonitor shape. Provider shim collapses them into one CR per Service.

### 7.2 Multiple metrics ports

Immich already has this: `metrics-api` (API server) + `metrics-ms` (microservices). Pattern match on port name prefix `metrics` covers it. Resulting ServiceMonitor has two `endpoints`.

### 7.3 Headless-only services

Package uses a headless Service (`clusterIP: None`) — ServiceMonitor with matching selector still works; prometheus-operator's discovery doesn't care about `clusterIP`. Pod-annotation scrape scrapes pods directly, so also fine. No special handling.

### 7.4 Init-container metrics

Init containers can expose metrics during startup (rare; e.g. migration jobs reporting progress). Scraping them is unreliable — they're short-lived. Skip: only scan `spec.template.spec.containers`, ignore `initContainers`. If a package really needs this, escape hatch.

### 7.5 mTLS-required scrape

ServiceMonitor supports `tlsConfig` with CA, cert, key SecretRefs. Pod-annotation scrape doesn't. Provisional: if `meta.monitoring.tls != null` and the resolved provider's `capabilities.supportsMtls == false`, emit a build-time warning (via doc 80 structured diagnostics) — "this cluster's scrape provider doesn't support mTLS; metrics for X will not be scraped." Don't fail the build; annotations + no scraper = metrics just aren't collected, which is degradation, not breakage.

### 7.6 Recording rules and alerts

These belong with the package (the package author knows what `up{job=immich} == 0 for 5m` should mean). Currently `compose.nix:919-934` emits PrometheusRule via `prometheus.out.mkPrometheusRule`. Generalize: `monitoringProvider.mkRule` takes the same groups shape, emits the provider-specific wrapper (`PrometheusRule` | `VMRule`). Rule body (PromQL) is portable; wrapper isn't. Pod-annotation scrape provider returns null from `mkRule` with a warning; rules have to live in the scraper's config and the package can't help.

### 7.7 Workload kinds that aren't Deployments

Jobs, CronJobs — short-lived; annotation-scrape works, ServiceMonitor doesn't (no stable Service typically). Scope the detection to long-lived workloads (Deployment, StatefulSet, DaemonSet). Jobs drop through the crack; acceptable.

---

## 8. Before / after sketches

### 8.1 Today — immich under prometheus-operator

```nix
# kix/packages/immich/default.nix (current)
{
  config,
  self,
  scope,
  kix,
  prometheus ? null,        # optional DI dep
  ...
}:
let
  hasMetrics = config.metrics.enabled && prometheus != null;
in {
  # ... service, deployment ...

  serviceMonitor =
    if hasMetrics then
      prometheus.out.mkServiceMonitor scope {
        name = name;
        spec = {
          namespaceSelector.matchNames = [ scope.namespaceName ];
          selector.matchLabels = self.service.out.selector;
          endpoints = [
            { port = "metrics-api"; scheme = "http"; }
            { port = "metrics-ms"; scheme = "http"; }
          ];
        };
      }
    else
      null;
}
```

### 8.2 After — immich under prometheus-operator

```nix
# kix/packages/immich/default.nix (after)
{
  config,
  self,
  scope,
  kix,
  ...
}:
{
  # The containers already declare ports named "metrics-api" and
  # "metrics-ms". That's the only signal needed.

  deployment = scope.mkDeployment {
    # ... spec ... containers: ports include
    #   { name = "metrics-api"; containerPort = 8081; }
    #   { name = "metrics-ms"; containerPort = 8082; }
  };

  service = self.deployment |> kix.service.fromWorkload { name = "${name}-server"; } |> scope.mkResource;

  # No serviceMonitor block, no prometheus dep arg, no hasMetrics flag.
  # scope.mkDeployment sees ports matching "metrics.*", consults
  # monitoringProvider (resolved to prometheus-operator shim at cluster level),
  # emits the ServiceMonitor, and splices it into the deployment's extraDeps.

  root = self.service;
}
```

Package loses ~25 lines, gains nothing it can observe — the scrape still happens. Switch the cluster's monitoring stack from prom-operator to VictoriaMetrics: this file doesn't change.

### 8.3 After — same immich under VictoriaMetrics

Identical package file. Cluster definition is the only difference:

```nix
# cluster definition (after)
modules = [
  kix.modules.monitoring    # existing prom-operator stack (disabled)
  {
    monitoring.enabled = false;
    # VM provider takes over monitoring capability
    instances.monitoring-vm.vmoperator.package = packages.victoriametrics-operator;
  }
];
```

The `victoriametrics-operator` package provides `out.monitor.mkScrape` that returns a `VMServiceScrape` instead of a `ServiceMonitor`. The package author's file is untouched.

### 8.4 After — immich under pod-annotation scrape

Cluster runs vanilla Prometheus with file-SD pod-annotation scrape. A thin `annotation-scrape-provider` package provides `out.monitor.mkScrape` that returns **a workload mutator, not a CR** — injects `prometheus.io/scrape: "true"` + `prometheus.io/port: "8081"` + `prometheus.io/path: "/metrics"` into the pod template. `scope.mkDeployment` applies the mutator to itself before sealing.

Same package file, same one-port-named-metrics signal, different downstream effect.

### 8.5 Author needs a non-default path

```nix
# kix/packages/envoy-proxy/default.nix (after)
build = [
  ({ self, scope, kix, ... }: {
    deployment = scope.mkDeployment {
      # container port named "metrics" on 15090
    };
    service = self.deployment |> kix.service.fromWorkload { } |> scope.mkResource;
    root = self.service;
  })
  # Override the default /metrics path.
  (kix.scrape { service = "service"; port = "metrics"; path = "/stats/prometheus"; })
];
```

The `kix.scrape` composer stamps `kix.dev/scrape-path = "/stats/prometheus"` onto the Service; the provider shim reads the annotation and propagates it into the CR / pod-annotation shape. One line; still provider-agnostic.

---

## 9. `kix/lib/` changes, scoped narrowly

- `kix/lib/compose.nix`: add `kix.scrape` composer (mirror of `kix.expose`, returns a build entry that stamps scrape-tuple annotations on a named service). Keep `kix.monitor` as-is for now; deprecate once `kix.scrape` + auto-wiring replaces it.
- `kix/lib/eval/scope.nix`: in `mkDeployment/StatefulSet/DaemonSet`, scan `spec.template.spec.containers[*].ports` for `name` matching the scrape pattern. If found and `monitoringProvider != null`, call `monitoringProvider.mkScrape` and splice into `extraDeps`.
- `kix/lib/eval/cluster.nix`: resolve a cluster-level `monitoringProvider` handle the same way `enforcerOut` is resolved today. `null` if no package provides one.
- `kix/lib/modules/monitoring.nix`: wire `out.monitor.*` on the prometheus-operator instance so it's picked up as `monitoringProvider`.
- New `kix/packages/annotation-scrape-provider/` (later): a pure-shim package that registers as the monitoring provider for clusters using pod-annotation scrape.

Not changed: `kix/lib/netpol.nix` (parallel mechanism, not shared code). `kix/lib/rules/` (no new scorecard rule needed for this — the signal-by-port-name makes mis-wiring structurally unlikely).

---

## 10. Open questions

1. **Port-name pattern — `metrics` exact vs. `metrics.*` regex.** Immich has `metrics-api` / `metrics-ms`. Do we match a pattern, or require authors to name the first port `metrics`? Leaning pattern, but it could swallow ports the author didn't intend.
2. **Annotations-on-Service vs. on-workload for the scrape-tuple carrier.** §4.2 option (C) put annotations on the Service. But pod-annotation-scrape needs them on the pod template. Should `kix.scrape` stamp both? Or should the provider shim translate? The latter is cleaner; the former is simpler.
3. **What happens when multiple monitoring providers are installed?** Cluster with both prom-operator and VM-operator (common during migration). Pick one via explicit cluster config (doc 93 flavor-barrier style) or fail with "ambiguous; disable one"? Same question netpol dodged by only allowing one enforcer.
4. **Recording rules under pod-annotation scrape.** Rules need to live in the scraper's static config. The provider shim can't return a CR. Does it write a ConfigMap that the scraper mounts? That requires knowing the scraper's Deployment — another DI edge. Or does the package just not get rules on these clusters, with a diagnostic? Defer.
5. **OTel Collector inline config.** If the provider writes `scrape_configs` entries into a shared Collector CR spec, emission is order-dependent (every `mkScrape` call appends to the same attrset). Nix fixpoint handles this, but it's a different shape than "one CR per package." May need a separate `mkScrapeInline` branch in the provider API. Deferred until someone actually runs an OTel cluster.
6. **`kix.monitor` deprecation path.** Keep it forever (tightly-controlled escape hatch), or migrate all current callers and remove? Leaning: keep as the explicit-CR-with-full-control path; auto-wiring is the default; `kix.scrape` is the composer-level override. Three tiers, each narrower than the last.
7. **Should `meta.monitoring.enabled = false` disable auto-wiring or also disable explicit `kix.monitor`?** The former (narrow semantics) is safer — explicit always wins. Document it.
8. **Do we need a build-time warning for "package has `metrics` port but no monitoring provider resolved"?** Could be silently correct (cluster operator chose no monitoring) or silently wrong (operator forgot to wire one). Leaning toward an info-level diagnostic on the cluster object, not per-package.
9. **Cross-namespace scrape** — ServiceMonitor's `namespaceSelector.matchNames` today is set to `[ scope.namespaceName ]`. Does the auto-wiring always scrape same-ns, or does the provider need to live in `monitoring` ns and select across? `prometheus-operator` today runs in `monitoring-system` and uses `namespaceSelector` to reach target namespaces — so the ServiceMonitor itself can live in *either* namespace, and the shim picks. Decide per provider.
10. **Intersection with doc 97 `augmentEdge`.** The ServiceMonitor/VMServiceScrape CR has its own store-path dependency on the Service it selects. Do we want the workload's store-path context to transitively depend on the scrape CR too (so netpol discovers a prometheus→target edge)? Netpol today finds this via the scraper's own egress CNP. Probably no change needed, but worth sanity-checking against `netpol.nix:83-99` registry when implementing.

---

## 11. Next steps

This doc is a brainstorm. If it survives review:

1. Spike the `monitoringProvider` resolution in `cluster.nix` against existing prometheus-operator. No behavior change yet — just prove the handle resolves and is reachable from `scope.mkDeployment`.
2. Move one package (coredns is a good candidate — small, has the `if prometheus != null` boilerplate, no sidecars) onto auto-wiring behind a feature flag. Compare generated output to `./result` for equivalence.
3. Design review before expanding: does the Service-annotation carrier pattern hold up, or does the scrape tuple want to live on the workload?
4. Only after (1)-(3): the annotation-scrape provider shim, as proof the abstraction covers a non-PO cluster.

Nothing lands until a real second provider exists to validate against.
