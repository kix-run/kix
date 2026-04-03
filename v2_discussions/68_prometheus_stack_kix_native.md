# 68: kube-prometheus-stack — Helm Wrapper to kix-Native Migration

**Status:** Draft
**Related:** `49_topology_aware_monitoring.md` (graph-derived observability), `62a_exposure_as_composable_build_entry.md` (`kix.expose` pattern — model for `kix.monitor`), `40_composite_packages.md` (composite package design), `packages/kube-prometheus-stack/default.nix` (current Helm wrapper), `clusters/nw1/monitoring.nix` (~1019 lines of Helm values and CRD overlay hacks)

---

## Problem

The monitoring stack is the largest remaining Helm chart wrapper in kixpkgs. It causes three concrete problems:

1. **Monolithic opacity.** The kube-prometheus-stack chart bundles six independent components (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics, Prometheus Operator) into one release. Updating Grafana means re-rendering the entire chart. CRD lifecycle is tied to the chart's hook machinery.

2. **Alert rules live in the wrong place.** `clusters/nw1/monitoring.nix` contains ~500 lines of PrometheusRules for Harbor, StackGres, Valkey, CoreDNS, RAID, and DNS — rules that belong in their respective packages. The `additionalPrometheusRulesMap` Helm value is the only escape hatch, and it dumps everything into one cluster file.

3. **CRD builder hacks.** The `partsOverlays` block in `monitoring.nix` (lines 26-55) manually constructs `mkServiceMonitor`, `mkPodMonitor`, and `mkPrometheusRule` via `mkCRDRef` — working around the fact that these should be first-class outputs of native packages that own their CRDs. Consumers (immich, harbor, coredns) already use the `prometheus ? null` DI pattern, but the builder functions come from a Helm chart overlay rather than a proper package `out`.

## Proposal

### Architecture: Monitoring Module

A **monitoring module** — not a composite package — provides the full stack as a first-class cluster concern, following the same pattern as `kix.expose`:

```nix
# clusters/nw1/monitoring.nix (after migration)
{
  options.monitoring.enabled = lib.mkEnableOption "cluster monitoring stack";

  config = lib.mkIf config.monitoring.enabled {
    instances.monitoring-system = {
      prometheus-operator = { ... };
      prometheus = { ... };
      grafana = { ... };
      alertmanager = { ... };
      node-exporter = { ... };
      kube-state-metrics = { ... };
    };
  };
}
```

Individual components are overridable (`config.instances.monitoring-system.grafana.config = ...`) and disableable (`config.instances.monitoring-system.grafana.enable = false`). The module wires cross-component concerns: Grafana datasources pointing at Prometheus/Loki, Alertmanager config referenced by Prometheus, ServiceMonitor selectors.

### Per-Package Alert Rules (Option C)

Packages ship their own default alerts using the existing `prometheus ? null` DI pattern. The monitoring module can override or extend them at the cluster level.

**Before** (all in `clusters/nw1/monitoring.nix`):
```nix
additionalPrometheusRulesMap.harbor-rules = { groups = [ ... ]; };
additionalPrometheusRulesMap.valkey-rules = { groups = [ ... ]; };
additionalPrometheusRulesMap.stackgres-rules = { groups = [ ... ]; };
```

**After** (in each package):
```nix
# packages/harbor/default.nix
{ prometheus ? null, scope, ... }:
{
  build = [
    ./harbor.nix
    # When prometheus DI is satisfied, emit ServiceMonitor + PrometheusRules
    ({ self, ... }: lib.optionalAttrs (prometheus != null) {
      serviceMonitor = prometheus.out.mkServiceMonitor scope { ... };
      alertRules = prometheus.out.mkPrometheusRule scope {
        metadata.name = "harbor-alerts";
        spec.groups = [ ... ];  # rules currently in monitoring.nix lines 235-353
      };
    })
  ];
}
```

The monitoring module provides `prometheus.out.mkServiceMonitor` / `mkPrometheusRule` as proper `out` properties of a native `prometheus-operator` package (which owns the CRDs), eliminating the `partsOverlays` hack.

### Component Decomposition

Each Helm sub-chart becomes a native kix package:

| Helm sub-chart | kix package | Notes |
|---|---|---|
| `prometheusOperator` | `packages/prometheus-operator/` | Owns CRDs (ServiceMonitor, PodMonitor, PrometheusRule, Prometheus, Alertmanager). Exposes `out.mkServiceMonitor`, `out.mkPodMonitor`, `out.mkPrometheusRule`. |
| `prometheus` | `packages/prometheus/` | Prometheus StatefulSet + Service. Depends on `prometheus-operator`. Config: retention, storage, resources. |
| `grafana` | `packages/grafana/` | Already a separate upstream chart. Datasource wiring via DI instead of hardcoded URLs like `http://loki-gateway.monitoring-system.svc.cluster.local`. |
| `alertmanager` | `packages/alertmanager/` | Alertmanager StatefulSet. Routing config (incident.io webhook, etc.) stays cluster-level. |
| `node-exporter` | `packages/node-exporter/` | DaemonSet. Ships its own PrometheusRules for node-level alerts. |
| `kube-state-metrics` | `packages/kube-state-metrics/` | Deployment. Ships its own ServiceMonitor. |

### `kix.monitor` Composable Build Entry

Following the `kix.expose` pattern from doc 62a, a `kix.monitor` build entry lets app developers declare monitoring intent without knowing Prometheus internals:

```nix
build = [
  ./app.nix
  (kix.monitor {
    port = "metrics";           # reference to a named port on self.service
    path = "/metrics";          # scrape path, default /metrics
    interval = "30s";           # scrape interval, default from cluster config
    alerts = {
      highErrorRate = {
        expr = ''rate(http_requests_total{status=~"5.."}[5m]) > 0.05'';
        severity = "warning";
        description = "Error rate above 5%";
      };
    };
  })
];
```

`kix.monitor` is a build entry function that:
1. Introspects `prometheus-operator ? null` from DI
2. When satisfied, emits a ServiceMonitor targeting `self.service` and a PrometheusRule with the declared alerts
3. When unsatisfied (no monitoring in cluster), emits nothing

This parallels how `kix.expose` introspects `ingressNginx ? null` and `clusterIssuer ? null`.

### Helm Feature Mapping

| Helm feature | kix equivalent | Status |
|---|---|---|
| Sub-chart conditionals (`grafana.enabled`) | `lib.mkIf` / optional packages in module | Ready |
| Named templates (`_helpers.tpl`) | Package `out` properties | Ready |
| Pre-install/pre-upgrade hooks | Jobs in resource graph, CLI waits for `status.succeeded >= 1` | Ready |
| Post-install/post-upgrade hooks | `root.postHooks` — deployed after all others, PI depends on them | Implemented (`lib/eval/instance.nix`, `lib/k8s.nix`) |
| CRD install hooks | CRDs as resources in early waves — no hook Job needed | Ready (Helm hook was a workaround) |
| Webhook cert generation hook | cert-manager integration (`clusterIssuer.out.withCert`) | Ready |
| `.Capabilities.KubeVersion` checks (~50 files) | `k8sVersion` module option in `lib/modules.nix` | Ready (already exists) |
| `.Release.IsInstall` guards | Not needed — wave ordering handles first-deploy vs update | N/A |
| `lookup` function | Not used in this chart | N/A |
| `.Files.Get` | Not used in this chart | N/A |

### CRD Lifecycle

CRDs are just resources placed in early waves by the compiler — the same as every other kix package with CRDs (cert-manager, etc.). The Helm chart's `crd-install` hook Jobs exist because Helm cannot express "apply CRDs before the operator starts." kix's wave system handles this natively.

### Webhook Certs

The Helm chart includes a self-signed cert generation Job (`admission-patch`) that runs as a hook. In kix, the prometheus-operator package declares its webhook and uses cert-manager integration:

```nix
# packages/prometheus-operator/webhook.nix
{ clusterIssuer ? null, ... }:
{
  webhook = kix.mkValidatingWebhookConfiguration {
    # ...
  } |> (if clusterIssuer != null then clusterIssuer.out.withCert else lib.id);
}
```

### Grafana Datasource Wiring

Currently hardcoded in `monitoring.nix` line 139:
```nix
url = "http://loki-gateway.monitoring-system.svc.cluster.local";
```

After migration, the Grafana package takes datasource providers via DI:

```nix
# In the monitoring module
grafana = {
  package = ./packages/grafana;
  deps = { inherit prometheus loki alertmanager; };
  config.datasources = {
    prometheus.url = prometheus.out.serviceUrl;   # derived from service
    loki.url = loki.out.gatewayUrl;               # derived from loki's out
    alertmanager.url = alertmanager.out.serviceUrl;
  };
};
```

No hardcoded DNS names. If Loki moves namespaces, the URL updates automatically.

### K8s Version-Aware Rendering

The upstream chart uses `.Capabilities.KubeVersion` in ~50 templates to gate dashboards and recording rules based on available K8s metrics APIs (e.g., `scheduler_pending_pods` renamed in 1.26). Native packages use:

```nix
{ clusterConfig, lib, ... }:
let
  k8sVersion = clusterConfig.k8sVersion or "1.30";
  hasNewSchedulerMetrics = lib.versionAtLeast k8sVersion "1.26";
in {
  # Conditional rule based on K8s version
  schedulerRules = if hasNewSchedulerMetrics
    then ./rules/scheduler-1.26+.nix
    else ./rules/scheduler-legacy.nix;
}
```

This requires `cluster.k8sVersion` to exist in the cluster config schema.

## Motivation

### Quantitative

- `clusters/nw1/monitoring.nix`: 1019 lines, of which ~500 are alert rules that belong in packages, ~100 are cross-namespace ServiceMonitors that packages should own, ~50 are `partsOverlays` CRD builder hacks. After migration, this file shrinks to ~200 lines of cluster-specific config (retention, storage, ingress, alertmanager routing).

- Alert rules for Harbor (7 rules), StackGres/Postgres (10 rules), Valkey (8 rules), CoreDNS (2 rules), RAID (3 rules) move to their respective packages. When a package is removed from a cluster, its alerts disappear automatically.

- Cross-namespace ServiceMonitors (valkey-shopfront-prod, dns-exporter, etc. — lines 753+) become package-owned resources via DI.

### Qualitative

- **Unblocks doc 49** (topology-aware monitoring). Per-package monitoring artifacts are the foundation for graph-derived alerting — blast radius annotations, correlated error suppression, dependency-chain dashboards. None of that works while alerts are centralized in a Helm values blob.

- **Eliminates the CRD overlay hack.** The `partsOverlays` in `monitoring.nix` is the only instance of this pattern in the codebase. Native packages with proper `out` properties make CRD builders a natural part of the package API.

- **Component-level upgrades.** Grafana can be updated independently of Prometheus. node-exporter can be pinned while kube-state-metrics moves forward. Today, any version bump re-renders the entire chart.

### Existing DI Consumers (no changes needed)

These packages already use the `prometheus ? null` pattern and will work unchanged — they just get their builders from a native package instead of a Helm overlay:

- `packages/immich/default.nix` — `prometheus.out.mkServiceMonitor`
- `packages/harbor/default.nix` — `prometheus.out.mkServiceMonitor`
- `packages/coredns/default.nix` — `prometheus.out.mkServiceMonitor`

## Migration Sequence

1. **`packages/prometheus-operator/`** — Extract operator deployment, RBAC, CRDs. Expose `out.mkServiceMonitor`, `out.mkPodMonitor`, `out.mkPrometheusRule` as native `out` properties (replacing `partsOverlays`).

2. **`packages/prometheus/`**, **`packages/alertmanager/`** — Extract server StatefulSets. Depend on `prometheus-operator`.

3. **`packages/grafana/`** — Already a separate upstream chart; wrap it natively with DI-based datasource wiring.

4. **`packages/node-exporter/`**, **`packages/kube-state-metrics/`** — Extract DaemonSet/Deployment. Ship default ServiceMonitors.

5. **Move alert rules to packages** — Harbor, StackGres, Valkey, CoreDNS, RAID rules move from `monitoring.nix` to their respective packages using `prometheus ? null` DI.

6. **Monitoring module** — Wire components together, replace the Helm chart instantiation in `monitoring.nix`.

7. **`kix.monitor` build entry** — Generalize the per-package monitoring pattern into a reusable composable build entry.

## Open Questions

1. **Grafana dashboard management.** The Helm chart ships ~30 pre-built dashboards as ConfigMaps via the sidecar. Do we bundle dashboards in each native package, or keep a central dashboard package? Per-package dashboards align with the vision (doc 49) but add significant file weight to every package.

2. **Recording rules.** The chart generates extensive recording rules (e.g., `node:node_cpu_utilisation:avg1m`). These are cross-cutting — they aggregate metrics from node-exporter but are consumed by dashboards in Grafana. Which package owns them? Likely `prometheus` itself, with a `defaultRecordingRules` option.

3. **Prometheus Operator version coupling.** The operator defines the CRD schema. When we split into separate packages, the Prometheus/Alertmanager packages must consume CRDs from the operator package's version. This is already how cert-manager works (CRDs in the operator package, consumers reference via `mkCRDRef`), but worth calling out.

4. ~~**`cluster.k8sVersion` schema.**~~ Already exists: `k8sVersion` option in `lib/modules.nix` (line 178). Packages access via `clusterConfig.k8sVersion`. Used by `lib/meta.nix` for min/max version compatibility checks.

5. ~~**Migration ordering vs. doc 49.**~~ Resolved: `kix.monitor` shipped as a minimal composable build entry (ServiceMonitor + PrometheusRule). Will be extended with topology features in doc 49.

## Implementation Progress

- [x] Post-hook support (`root.postHooks`) — `lib/eval/instance.nix`, `lib/k8s.nix`
- [x] `kix.monitor` composable build entry — `lib/compose.nix`
- [x] `kix.options.monitor` standardized options — `lib/compose.nix`
- [x] `k8sVersion` cluster option — already existed in `lib/modules.nix`
- [x] Harbor alert rules moved to package — `packages/harbor/default.nix`
- [x] CoreDNS alert rules moved to package — `packages/coredns/default.nix`
- [x] Valkey alert rules moved to package — `packages/valkey/default.nix`
- [ ] Monitoring module (`monitoring.enable = true`)
- [ ] Individual native packages (prometheus-operator, prometheus, grafana, alertmanager, node-exporter, kube-state-metrics)
- [ ] Remove migrated rules from `clusters/nw1/monitoring.nix`
