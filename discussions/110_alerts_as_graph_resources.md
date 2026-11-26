# 110: Alerts as graph resources

**Status:** RFC / Draft
**Relevance:** Active
**Related:** `105_ludo_homelab_operational_readiness.md` (B2, B9), `101_monitoring_provider_landscape.md`, `102_auto_monitoring_wiring.md`, `108_backup_capability_contract.md`, `80_structured_diagnostics.md`, `60_scorecard_rules_design.md` (archived)
**Supersedes:** none — first dedicated alerting design.

## Why this doc

Doc 105 §B2/§B9 listed two homelab gaps: a baseline cluster-ops alert pack, and Alertmanager routing as kix config. The first instinct was to model alerts as `meta.alerts` declarations on workloads with a flavor renderer (parallel to `meta.monitoring` in doc 102).

That instinct is wrong. Per `PRINCIPLES.md` §13 (*Wiring > module system > meta*), `meta` is reserved for kix-concerns hints that drive cross-cutting auto-wiring (statefulness, importance, consistency class) — *not* for plumbing real cluster resources together. An alert is not a hint. It compiles to a `PrometheusRule` CR, which has to be label-matched by a `Prometheus` CR, referenced by an `AlertmanagerConfig` whose receivers point at real `Service`s. That is four wiring edges. Pure DAG territory.

Reframe: **alerts are runtime scorecards**, expressed as ordinary cluster resources, owned by the package that knows the symptom, wired through DI like everything else. No new mental model, and — per PRINCIPLES §8 — no invented vocabulary on top of what the Prometheus ecosystem already uses.

## Audience: who declares what

Three personas (PRINCIPLES §9), three surfaces:

| Persona | Owns | Output |
|---|---|---|
| App / package maintainer | Knows when *their* workload is broken (postgres primary down, backup stale, cert expiring). Knows the `severity` split they already write today. | A `PrometheusRule` resource per symptom, with conventional labels. |
| Platform team (flavor) | Knows the *cluster-wide* symptoms nobody owns (node down, disk full, clock skew, OOM). Picks default profile (`homelab` / `production`) and default `severityMap`. | A baseline-alerts package + a routing package shipped as part of the flavor. |
| Cluster operator (SRE) | Knows *their* receivers (ntfy topic, email, slack), maintenance windows, per-cluster overrides and silences. | Parameterizes the routing package; runs receiver workloads. |

Each layer can be empty (sane defaults) or override the layer below.

## Design

### 1. `scope.mkAlert` — the package-side primitive

Package maintainers don't write raw `PrometheusRule` YAML. A scope helper in `kix/lib/eval/scope.nix`:

```nix
self.mkAlert {
  name        = "PostgresMigrationWalRetentionCritical";
  severity    = "critical";        # warning | critical | info — Prom-ecosystem convention
  expr        = ''...'';
  for         = "5m";
  summary     = "WAL retention exhausted";
  description = "...";
  runbook     = "https://...";     # optional
  tags        = [ "postgres" "stateful" ];   # optional, free-form
}
```

Renders to a `PrometheusRule` with conventional labels:

- `severity=<warning|critical|info>` — **the de-facto Prom-ecosystem label** (kube-prometheus, prom-operator examples, Alertmanager docs all use this). Drives routing.
- `kix.dev/owner=<package-name>` — the only kix-specific label. Drives ownership-aware silences and cross-package `requires`.
- Free-form `tags` join `kix.dev/tag/<tag>=true` for inhibition rules ("silence everything tagged `postgres` during a maintenance window").

The result is a real resource: it lives in the package's namespace, participates in the DAG, can be queried via `out` like any other resource.

**Why a scope helper rather than mkResource:** label conventions are the contract between rules and routing. If maintainers hand-roll the labels, the contract drifts. `scope.mkAlert` is the only correct way to author one — same shape as `mkServiceRef` in doc 97. Author surface stays minimal: `severity` is the only required label-bearing field, and it's a value the maintainer already writes today.

**No invented `kind` taxonomy.** Earlier drafts of this doc proposed a six-value `kind` field (`data-loss` / `availability` / `degraded` / `expiry` / `capacity` / `infra`). Rejected: (a) `kind` is fully invented by us; (b) real-world prom-rule corpora (kube-prometheus, chart-shipped rules, the example inventory in §Appendix A) already encode symptom shape via *naming convention* (`<Component><Symptom><Severity>`) and route purely on `severity`. Adding `kind` asks maintainers to learn a kix-only vocabulary for no routing benefit.

Symptom categorization (USE/RED-style: availability / errors / saturation / latency / data-integrity / lifecycle) is fine to encode via `tags` if a package author wants — but it's never required, never invented as a CRD field, and never routes. PRINCIPLES §8 (standard K8s vocab over invented).

### 2. `kix/packages/cluster-baseline-alerts/` — platform-owned baseline

Five `PrometheusRule`s nobody else owns:

1. `NodeNotReady` — kubelet down >5m. `severity=critical`.
2. `NodeDiskPressure` — root FS >85% (warning) / >95% (critical).
3. `NodeClockSkew` — NTP drift >5s. `severity=warning`.
4. `NodeOOMKilled` — any OOM in last 1h. `severity=warning`.
5. `ClusterCertExpiring` — any cert <14d. `severity=warning` (lifts to `critical` <72h).

These live in a flavor-shipped package because no application package owns "the node" or "the cluster CA". Parameterizable: `{ diskWarn, diskCrit, clockSkewThreshold, certExpiryWindow, includeOOM }`. Rules are sourced from `kube-prometheus` / `node-exporter` mixins where possible — we re-emit through `mkAlert` with our `kix.dev/owner` set, rather than write PromQL from scratch.

Other "10-pack" alerts from doc 105 §A3 are *not* here — they're owned by the relevant capability package:

- PVC near-full → `kix/packages/persistent-volume-claim/` (the package emits its own capacity alert; see §3).
- Pod CrashLoopBackOff → `mkAlerts.standardWorkload` helper called from each consuming package.
- Postgres primary down → stackgres-cluster.
- Backup stale → backup engine (rides doc 108).
- Tailscale node unreachable → tailscale package (rides doc 107).

If the cluster doesn't have those capabilities, the alerts simply don't exist. That's the whole point of letting the DAG own this.

### 3. Sensible defaults — owned by packages, not derived

Getting alerts right is the historically annoying part. Three layers of defaults that keep operator effort to a one-line decision per cluster, **without** any flavor-level walking of the DAG.

#### 3.1 Curated rule library

Capability packages re-emit their existing upstream chart rules through `mkAlert`. Stackgres ships `postgres_exporter` rules in its chart — the kix package re-emits those through `mkAlert` with `kix.dev/owner=stackgres-cluster` set. Same for cert-manager, ingress-nginx, etcd, etc. Package authors **assign `severity`**; they don't write PromQL from scratch. Baseline package re-uses `kube-prometheus` rules.

Battle-tested PromQL in, kix labels added, ship.

#### 3.2 `scope.mkAlerts.<recipe>` helpers

Composite recipes, called from inside a package's own `build`. One line emits the obvious set:

- `scope.mkAlerts.standardWorkload { workload = self.deployment; }` — CrashLoopBackOff, OOMKilled, container-restart-rate, pod-not-ready. Reads `cluster.alerts.profile` for thresholds.
- `scope.mkAlerts.pvcCapacity { pvc = self.root; warnAt = 80; critAt = 95; }` — fires inside `kix/packages/persistent-volume-claim/`. Every PVC instance gets its capacity alert without anyone walking the cluster.
- `scope.mkAlerts.serviceProbe { service = self.svc; }` — black-box availability for an exposed service. Consumed by edge packages (ingress, doc 107 overlay-edge).

These are scope helpers, not flavor walkers — the package that owns the resource emits the alert about that resource. Per PRINCIPLES §9/§10.

#### 3.3 Profile presets

`cluster.alerts.profile = "homelab" | "production"` flips a small set of defaults that the helpers and baseline package read:

| | `homelab` | `production` |
|---|---|---|
| `for:` durations | longer (5m–15m) | tighter (1m–5m) |
| Disk warn/crit | 85% / 95% | 75% / 90% |
| CrashLoop alerting | off (self-healing assumed) | on |
| OOM noise threshold | 1/hour | 1/5min |
| Cert-expiry window | 14d | 30d |

One operator decision; per-rule overrides are escape hatches via `cluster.alerts.overrides.<RuleName>.{ severity, for, threshold, enabled }`.

#### 3.4 Deferred — DAG-derived alerts

An earlier draft proposed a flavor-level package that walks the DAG and emits alerts for resources whose owning package didn't (e.g. PVCs without an explicit capacity rule). Rejected for now: it duplicates ownership, re-introduces auto-magic at a distance, and overlaps heavily with doc 102 monitoring auto-wiring. The PVC-capacity case is better solved by the PVC package emitting its own rule. Revisit only with a concrete driver no per-package author can address (e.g. cross-cluster aggregate alerts).

### 4. `kix/packages/alertmanager-routing/` — operator-owned routing

One package, one `AlertmanagerConfig` resource. Package options:

```nix
{
  receivers = {
    page   = { type = "ntfy"; topic = "ludo-page"; priority = 5; };
    ticket = { type = "ntfy"; topic = "ludo-ticket"; priority = 3; };
    digest = { type = "email"; address = "ops@example.com"; cadence = "daily"; };
  };
  severityMap = {
    critical = "page";
    warning  = "ticket";
    info     = "digest";
  };
  silences = [
    { match = { namespace = "playground"; }; }
    { match = { "kix.dev/owner" = "experimental-thing"; }; }
  ];
}
```

The package `requires` the receiver service(s) (e.g. `ntfy-relay`); DAG ordering guarantees the service exists before the AlertmanagerConfig references it.

`severityMap` is the platform/operator policy boundary: three lines, ecosystem-standard severity values on the left, operator's receivers on the right. Platform ships a default mapping with the flavor; operator overrides per-cluster.

### 5. `kix/packages/ntfy-relay/` (and friends) — receivers

Plain workloads. Deployment + Service exposing an HTTP endpoint that Alertmanager posts to. Other receiver flavors (Telegram bot, email gateway) ship as parallel packages with the same `out.receiverUrl` contract so `alertmanager-routing` can DI-resolve them by type.

### 6. Wiring `PrometheusRule` → `Prometheus`

A `PrometheusRule` is only useful if some `Prometheus` CR's `ruleSelector` matches it. Today this is a hardcoded label selector on the `Prometheus` instance.

Long-term this rides doc 101/102's monitoring auto-wiring — the same mechanism that makes a `Prometheus` discover `ServiceMonitor`s discovers `PrometheusRule`s.

For 110's MVP: hardcode `ruleSelector: { matchExpressions: [{ key: kix.dev/owner, operator: Exists }] }` on the prometheus instance. Documented as a known temporary edge.

### 7. Maintenance-mode integration

`cluster.maintenance` (shipped in B7) surfaces `cluster.out.maintenance.{enable, reason, until}`. The `alertmanager-routing` package consumes it: when `enable = true`, it emits a global `Silence` covering everything *except* alerts marked with a `pageThroughMaintenance: true` annotation (which `mkAlert` exposes as a per-rule opt-in, default false). Two-line wiring, no new primitive.

## What this is *not*

- **Not a `meta.alerts` proposal.** Explicitly rejected per PRINCIPLES §13.
- **Not a monitoring provider design.** Doc 101 surveys providers; 102 designs auto-wiring. This doc assumes prom-operator-shaped CRs because that's what ludo runs. VictoriaMetrics / Alloy support is a renderer swap, deferred.
- **Not a runbook system.** `runbook` is a URL; how runbooks are authored/hosted is out of scope.
- **Not a DAG-walk-derived-alerts system.** Per §3.4 — owners emit their own alerts.
- **Not a scorecard ↔ alert unification.** The shared idea (build-time and runtime symptoms route through the same `severity` policy) is interesting, deferred.

## Migration / scope

- B2 (baseline alert pack) → ships as `cluster-baseline-alerts` package.
- B9 (Alertmanager routing as kix config) → ships as `alertmanager-routing` package.
- B7 (maintenance-mode) → already implemented; this doc wires it.
- Other 105 §A3 alerts → owned by their respective capability packages, gated on those packages existing.

## Phased rollout

**Phase 1 — primitive + baseline.**
- `scope.mkAlert` in `kix/lib/eval/scope.nix`.
- `cluster.alerts.profile` cluster option.
- `kix/packages/cluster-baseline-alerts/` with the five rules sourced from `kube-prometheus`.
- Hardcoded `Prometheus.ruleSelector` matching `kix.dev/owner`.
- Smoke-test in ludo-kind.

**Phase 2 — routing + receivers.**
- `kix/packages/ntfy-relay/`.
- `kix/packages/alertmanager-routing/` consuming `cluster.maintenance` and `severityMap`.
- Wire ludo to the homelab receiver set.

**Phase 3 — capability alerts via helpers.**
- `scope.mkAlerts.standardWorkload`, `pvcCapacity`, `serviceProbe`.
- `kix/packages/persistent-volume-claim/` adopts `pvcCapacity`.
- Stackgres re-emits its chart's existing rules through `mkAlert`.
- Backup engine `BackupStale` (rides doc 108).
- Cert-manager per-issuer expiry.

**Phase 4 — auto-wiring polish.**
- Drop hardcoded `ruleSelector` once doc 102 lands.
- Revisit scorecard ↔ alert unification as a separate RFC.

## Open questions

1. **Should `mkAlert` be allowed at the `cluster` scope** (not just package scope), so an operator can drop an ad-hoc rule into their cluster definition without authoring a package? Probable yes — same shape as `mkResource` at multiple scopes. Confirm when implementing Phase 1.
2. **Receiver type extensibility.** `ntfy` / `email` / `slack` / `telegram` — do receivers share an interface (`out.receiverUrl` + `out.authSecretRef`) or does each get bespoke handling in `alertmanager-routing`? Lean toward shared interface so adding a channel is a package, not an edit. Defer until second receiver lands.
3. **Per-namespace severity overrides.** Useful for multi-team clusters; out of scope for ludo. Revisit when doc 45 multi-team work touches alerting.
4. **Inhibition rules.** Free-form `tags` enable `kix.dev/tag/postgres=true`-style inhibition; the inhibition CR itself isn't designed here. Punt to Phase 3 when capability alerts make it concrete.
5. **Should `ludo/base.nix` opt into the `reliability` scorecard rules** (so B4's `boundedResources` warning fires there)? Tangential to 110 but surfaced during B4 implementation. Probable yes; one-line change.
6. **Profile preset granularity.** Two presets (`homelab` / `production`) may be too coarse — production-edge / production-batch / production-multi-tenant have meaningfully different defaults. Revisit once a second cluster archetype demands it; PRINCIPLES §14 (no hypothetical futures).

## Appendix A — sanity-check against a real-world repo

Inventory from a production repo (collected during 110 design review):

- **App alerts (colocated with charts):** invoice-processor (3), namespace-admission-webhook (3), postgres-migration-operator (2). All split into `*Down` / `*HighErrorRate` / `*<Resource>Backlog` / `*CertExpiringSoon` / `*ValidationErrors` patterns.
- **Infra alerts (centralized):** MinIO (19), Harbor (11), Mayastor (13), Postgres+PgBouncer (15), Actions runners (2), etcd (1), Node RAID (3). ~64 alerts.
- **Severity convention:** every alert has a `severity` label, frequently in `Warning`/`Critical` pairs (`PostgresMigrationWalRetentionWarning` + `*Critical`, Mayastor pool `usage warning`/`critical`). Maintainers *do* know the warn/crit split.
- **Categories observed:** availability/down, error rate, saturation/capacity, latency, data-integrity, lifecycle/certs. Encoded in alert *names*, not as a label.

Confirms: (a) `severity` is the right routing primitive; (b) maintainers already author the warn/crit split; (c) symptom categorization is conveyed by naming + free tags, not a controlled label vocabulary; (d) nearly all alerts in this corpus are package-owned, not cluster-derived — supporting §3.4's deferral of DAG-walk derivation.
