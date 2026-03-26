# Composite Packages — Decomposing Bundled Stacks Without Cluster-Level Pain

## Working Document — March 2026

**Status:** RFC
**Predecessors:** doc 11 (infrastructure DI), doc 27 (auto-instantiation), doc 39 (DI-driven defaults), doc 05 (CRD type providers), doc 37 (DI-derived network policies)
**Motivating case:** kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, Prometheus Operator, alert rules, ServiceMonitors)

---

## 1. The Problem

Helm bundles unrelated software into mega-charts because Helm has no dependency system. kube-prometheus-stack is the canonical example: it's 6+ independent projects (Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter) glued together because Helm's only composition mechanism is subcharts.

kix has DI, auto-instantiation, and the module system — everything needed to decompose these properly. But it hasn't been designed yet. The naive approach creates cluster-level mess:

```nix
# What nobody wants to write
instances.monitoring-system = {
  prometheus-operator = { package = packages.prometheus-operator; };
  prometheus = { package = packages.prometheus; config = { ... 30 lines ... }; };
  alertmanager = { package = packages.alertmanager; config = { ... 20 lines ... }; };
  grafana = { package = packages.grafana; config = { ... 40 lines ... }; };
  kube-state-metrics = { package = packages.kube-state-metrics; };
  node-exporter = { package = packages.node-exporter; };
};
```

But the monolithic Helm approach is worse. Today `monitoring.nix` is 900 lines, most of which is alert rules for *other* services (Harbor, StackGres, Valkey) crammed into `additionalPrometheusRulesMap` because there's nowhere else to put them.

Three design challenges:

1. **Composition** — How does a bundle of packages present itself as a single thing to the cluster operator, while remaining decomposable?
2. **Distributed observability** — How do consumer packages (Harbor, Valkey) declare their own ServiceMonitors and PrometheusRules via DI, so monitoring.nix doesn't become a dumping ground?
3. **CRD builder exposure** — Prometheus Operator defines CRDs (ServiceMonitor, PrometheusRule, Prometheus, Alertmanager) that both sibling packages and external consumers need. How does this flow through DI?

---

## 2. Prior Art: What Already Exists

### 2.1 Auto-instantiation (doc 27)

`availablePackages` + optional instances already solve the "too many declarations" problem. If `prometheus` declares `prometheus-operator` as a hard dep, and `prometheus-operator` is in `availablePackages`, it auto-instantiates. The cluster operator never writes the line.

### 2.2 DI-driven defaults (doc 39)

The `ingressNginx ? null` pattern gates features on dep presence. Harbor already uses `prometheus ? null` to conditionally create ServiceMonitors. This is the mechanism for distributed observability.

### 2.3 CRD type providers (doc 05)

`mkTypeProvider` exposes constructor functions that inject `requires` for CRDs and controllers. The monitoring.nix `partsOverlays` hack currently does this manually:

```nix
# Today's workaround — cluster-level partsOverlays to expose CRD builders
partsOverlays = [
  (scope: self: base: {
    root = base.root // {
      out = (base.root.out or {}) // {
        mkServiceMonitor = smRef.out.mkCR;
      };
    };
  })
];
```

This should be package-level, not cluster-level.

### 2.4 Module system (modules.nix)

The cluster is composed of NixOS modules. `monitoring.nix` is already a module with `options.monitoring.enabled`. Modules can set `config.instances` for any namespace — cross-cutting concerns are first-class.

---

## 3. Design: Composite Package Modules

### 3.1 The Key Insight

A "composite package" isn't a new primitive. It's a **NixOS module that instantiates related packages with good defaults and wires them together**. The module system already supports this — the missing piece is a convention and a helper.

```nix
# lib/composite.nix
mkComposite = {
  name,             # e.g. "monitoring"
  namespace,        # default namespace for all sub-packages
  packages,         # { prometheus-operator = pkg; prometheus = pkg; ... }
  defaults ? {},    # default config per sub-package
  wiring ? {},      # default DI overrides between sub-packages
  enableOption ? true,  # whether to generate an enable option
}: { config, lib, packages as allPackages, ... }: {

  options.${name} = lib.mkIf enableOption {
    enabled = lib.mkEnableOption "${name} stack";
  };

  # Each sub-package becomes an instance with sensible defaults.
  # The cluster operator can override any of them via the module system.
  config = lib.mkIf (config.${name}.enabled or true) {
    instances.${namespace} = lib.mapAttrs (instName: pkg: {
      package = pkg;
      config = defaults.${instName} or {};
      deps = wiring.${instName} or {};
    }) packages;
  };
};
```

But this is too rigid. The real power comes from making it a regular module with options:

### 3.2 The Monitoring Stack as a Module

```nix
# packages/monitoring/module.nix
#
# A NixOS module (not a kix package) that composes the monitoring stack.
# The cluster operator uses it like any other module.

{ config, lib, packages, ... }:

let
  cfg = config.monitoring;
in
{
  options.monitoring = {
    enabled = lib.mkEnableOption "monitoring stack";
    namespace = lib.mkOption {
      type = lib.types.str;
      default = "monitoring-system";
    };

    # High-level knobs — not Helm values, not K8s fields.
    # These map to config on the sub-packages.
    prometheus = {
      retention = lib.mkOption { type = lib.types.str; default = "15d"; };
      retentionSize = lib.mkOption { type = lib.types.str; default = "50GiB"; };
      storage = lib.mkOption { type = lib.types.str; default = "100Gi"; };
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
      ingress.host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      scrapeInterval = lib.mkOption { type = lib.types.str; default = "30s"; };
    };

    alertmanager = {
      replicas = lib.mkOption { type = lib.types.int; default = 1; };
      config = lib.mkOption {
        type = lib.types.anything;
        default = {};
        description = "Alertmanager routing config (receivers, routes, etc.)";
      };
    };

    grafana = {
      ingress.host = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      persistence.size = lib.mkOption { type = lib.types.str; default = "10Gi"; };
      datasources = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
        description = "Additional Grafana datasources beyond Prometheus.";
      };
    };

    # Feature flags that gate entire sub-packages
    grafana.enabled = lib.mkOption { type = lib.types.bool; default = true; };
    nodeExporter.enabled = lib.mkOption { type = lib.types.bool; default = true; };
    kubeStateMetrics.enabled = lib.mkOption { type = lib.types.bool; default = true; };
  };

  config = lib.mkIf cfg.enabled {
    instances.${cfg.namespace} = lib.filterAttrs (_: v: v != null) {

      prometheus-operator = {
        package = packages.prometheus-operator;
        aliases = [ "prometheus" "monitoring" ];
      };

      prometheus = {
        package = packages.prometheus;
        config = {
          inherit (cfg.prometheus) retention retentionSize storage replicas scrapeInterval;
          ingress = lib.mkIf (cfg.prometheus.ingress.host != null) {
            host = cfg.prometheus.ingress.host;
          };
        };
      };

      alertmanager = {
        package = packages.alertmanager;
        config = {
          inherit (cfg.alertmanager) replicas;
          routing = cfg.alertmanager.config;
        };
      };

      grafana = lib.mkIf cfg.grafana.enabled {
        package = packages.grafana;
        config = {
          persistence.size = cfg.grafana.persistence.size;
          ingress = lib.mkIf (cfg.grafana.ingress.host != null) {
            host = cfg.grafana.ingress.host;
          };
          additionalDatasources = cfg.grafana.datasources;
        };
      };

      kube-state-metrics = lib.mkIf cfg.kubeStateMetrics.enabled {
        package = packages.kube-state-metrics;
      };

      node-exporter = lib.mkIf cfg.nodeExporter.enabled {
        package = packages.node-exporter;
      };
    };
  };
}
```

### 3.3 What the Cluster Definition Looks Like

```nix
# clusters/nw1/monitoring.nix — after
{ config, ... }:
{
  imports = [ ../../packages/monitoring/module.nix ];

  monitoring = {
    enabled = true;
    prometheus = {
      retention = "90d";
      retentionSize = "320GiB";
      storage = "400Gi";
      ingress.host = "prometheus.${config.cluster.domain}";
    };
    alertmanager.config = {
      route = {
        receiver = "incidentio";
        group_by = [ "namespace" "alertname" ];
      };
      receivers = [
        { name = "null"; }
        { name = "incidentio"; webhook_configs = [{ url = "..."; }]; }
      ];
    };
    grafana = {
      ingress.host = "grafana.${config.cluster.domain}";
      persistence.size = "10Gi";
      datasources = [{
        name = "Logs";
        type = "loki";
        url = "http://loki-gateway.monitoring-system.svc.cluster.local";
      }];
    };
  };
}
```

~30 lines of actual config. The 500+ lines of alert rules are gone — they live in the packages that own them. Compare to today's 900-line monitoring.nix.

---

## 4. Distributed Observability: Packages Own Their Monitoring

### 4.1 The Pattern

The `prometheus ? null` DI pattern already exists (Harbor, Immich, CoreDNS). The rule is:

> A package that exposes metrics declares its own ServiceMonitor and PrometheusRules.
> It takes `prometheus ? null` as an optional dep. When injected, monitoring resources are created. When absent, they aren't.

```nix
# packages/harbor/default.nix (the relevant parts)
{ scope, lib, postgres, ingressNginx ? null, clusterIssuer ? null,
  prometheus ? null }:

let
  hasMetrics = prometheus != null;
  mkServiceMonitor = if hasMetrics then prometheus.out.mkServiceMonitor scope else null;
  mkPrometheusRule = if hasMetrics then prometheus.out.mkPrometheusRule scope else null;
in {
  # ... harbor resources ...

  serviceMonitor = lib.optionalAttrs hasMetrics (mkServiceMonitor {
    name = "${name}";
    spec = {
      selector.matchLabels = self.coreService.out.selector;
      endpoints = [{ port = "metrics"; interval = "30s"; }];
    };
  });

  rules = lib.optionalAttrs hasMetrics (mkPrometheusRule {
    name = "${name}";
    spec.groups = [{
      name = "harbor-alerts";
      rules = [
        {
          alert = "HarborHealthCheckFailed";
          expr = "harbor_health == 0";
          "for" = "5m";
          labels.severity = "critical";
          annotations.summary = "Harbor health check failed";
        }
        # ... all the harbor rules that currently live in monitoring.nix ...
      ];
    }];
  });
}
```

### 4.2 Where the Rules Come From

Today, `monitoring.nix` has alert rules for: Harbor, StackGres, Valkey, DNS, RAID, etcd. After this change:

| Rules | Today | After |
|---|---|---|
| Harbor alerts | monitoring.nix `additionalPrometheusRulesMap` | `packages/harbor/` |
| StackGres alerts | monitoring.nix `additionalPrometheusRulesMap` | `packages/stackgres-cluster/` |
| Valkey alerts | monitoring.nix `additionalPrometheusRulesMap` | `packages/valkey/` |
| DNS alerts | monitoring.nix `additionalPrometheusRulesMap` | `packages/dns-exporter/` or `packages/coredns/` |
| RAID alerts | monitoring.nix `additionalPrometheusRulesMap` | `packages/node-exporter/` (custom rules option) |
| etcd alerts | monitoring.nix `additionalPrometheusRulesMap` | cluster module (etcd is not a kix package) |
| Default K8s alerts | Helm's `defaultRules` | `packages/prometheus/` (built-in) |

The etcd case is interesting — etcd isn't managed by kix, so its rules stay in the cluster definition. This is correct: the cluster definition is the right place for cluster-specific things that aren't managed packages.

### 4.3 ServiceMonitor Duplication Disappears

Today monitoring.nix has 5 near-identical Valkey ServiceMonitor blocks and 3 DNS exporter blocks. After:

- Each Valkey instance creates its own ServiceMonitor via `prometheus ? null` DI. Five instances = five ServiceMonitors, zero duplication.
- Each DNS exporter instance creates its own ServiceMonitor. Per-node config (server IP, node label) is instance config, not monitoring config.

### 4.4 Cross-Namespace Monitoring

A package in namespace `shopfront-prod` needs to create a ServiceMonitor that Prometheus (in `monitoring-system`) discovers. This already works — Prometheus is configured with `serviceMonitorSelectorNilUsesHelmValues = false`, meaning it scrapes all ServiceMonitors regardless of namespace. The ServiceMonitor lives in the package's namespace, and Prometheus finds it. No cross-namespace wiring needed.

---

## 5. CRD Builder Exposure: Operators as Infrastructure Providers

### 5.1 The Current Hack

Today, CRD builders (`mkServiceMonitor`, `mkPrometheusRule`) are injected via a `partsOverlays` in the cluster definition:

```nix
# Today: cluster-level workaround
partsOverlays = [
  (scope: self: base: {
    root = base.root // {
      out = (base.root.out or {}) // {
        mkServiceMonitor = smRef.out.mkCR;
      };
    };
  })
];
```

This is wrong on multiple levels:
- It's in the cluster definition, not the package
- It uses `mkCRDRef` which is a scope-level workaround for "I don't have the CRD resource"
- The `out` attachment is on `root`, which is arbitrary

### 5.2 The Right Way: Package-Level `out` from CRDs

Following doc 05 (CRD type providers) and the cert-manager pattern, the prometheus-operator package should expose CRD builder functions as part of its evaluated output:

```nix
# packages/prometheus-operator/default.nix
{ scope, lib }:
{
  meta = {
    provides = [ "monitoring" "prometheus" ];
    defaultAliases = [ "prometheus" "monitoring" ];
  };

  # ...

  build = { self, config, clusterConfig }:
  let
    # CRD definitions
    serviceMonitorCRD = scope.mkCRD (
      scope.crd.fromKind "ServiceMonitor" { spec.group = "monitoring.coreos.com"; }
      # ...
    );

    prometheusRuleCRD = scope.mkCRD (
      scope.crd.fromKind "PrometheusRule" { spec.group = "monitoring.coreos.com"; }
      # ...
    );

    # Type provider constructors — these go in `out`
    mkServiceMonitor = consumerScope: attrs:
      consumerScope.mkResource ({
        apiVersion = "monitoring.coreos.com/v1";
        kind = "ServiceMonitor";
        requires = [ serviceMonitorCRD self.operatorDeployment ];
      } // attrs);

    mkPrometheusRule = consumerScope: attrs:
      consumerScope.mkResource ({
        apiVersion = "monitoring.coreos.com/v1";
        kind = "PrometheusRule";
        requires = [ prometheusRuleCRD self.operatorDeployment ];
      } // attrs);

  in {
    crds = { inherit serviceMonitorCRD prometheusRuleCRD; /* ... */ };

    operatorDeployment = /* ... */;

    root = {
      resource = self.operatorDeployment;
      requires = [ /* CRDs, RBAC, etc. */ ];
      # Builders exposed via standard `out` mechanism
      outputs = {
        inherit mkServiceMonitor mkPrometheusRule;
      };
    };
  };
}
```

Consumers then use the standard DI pattern:

```nix
# packages/harbor/default.nix
{ scope, lib, prometheus ? null }:
# ...
mkServiceMonitor = if prometheus != null then prometheus.out.mkServiceMonitor scope else null;
```

No `partsOverlays`. No `mkCRDRef`. No cluster-level workarounds.

### 5.3 Sibling Packages in the Composite

Within the monitoring composite, `packages/prometheus` depends on `packages/prometheus-operator` for the `Prometheus` CRD:

```nix
# packages/prometheus/default.nix
# This package creates a Prometheus CR — it depends on the operator.
{ scope, lib, prometheus-operator }:
let
  mkPrometheus = prometheus-operator.out.mkPrometheus scope;
in {
  # The entire package is basically one CR + supporting resources
  prometheusInstance = mkPrometheus {
    name = "prometheus";
    spec = {
      retention = config.retention;
      replicas = config.replicas;
      # ...
    };
  };
  # ...
}
```

The DI system resolves `prometheus-operator` from the same namespace (since the composite module places them together). No manual wiring needed.

---

## 6. Interaction With Other RFCs

### 6.1 Auto-Instantiation (doc 27)

The composite module explicitly declares all sub-packages. But the sub-packages themselves may have transitive deps. Example: `packages/grafana` might depend on `persistent-volume-claim` for its data volume. With `availablePackages`, this auto-instantiates — the composite module doesn't need to know.

### 6.2 DI-Derived Network Policies (doc 37)

Decomposing the monolith makes the network graph richer and more accurate:
- Today: Helm blob → one big NetworkPolicy exception or none at all
- After: Grafana → Prometheus (port 9090), Prometheus → kube-state-metrics (port 8080), etc.

Each edge is a real DI dep with real port information. NetworkPolicy generation gets better data for free.

### 6.3 Connection Graph (doc 34)

Same benefit. The connection graph for monitoring goes from "one opaque blob" to a detailed graph showing Prometheus scraping node-exporter, Grafana querying Prometheus, Alertmanager receiving from Prometheus, etc. This is the graph that should exist.

### 6.4 Resource Type Tags (doc 38)

The CRD builders (`mkServiceMonitor`, `mkPrometheusRule`) are natural tag attachment points. A `ServiceMonitor` resource carries a tag indicating it's a monitoring resource, which the compiler could use for validation (e.g., "this ServiceMonitor references port `metrics` but the target Service has no port named `metrics`").

---

## 7. Migration Path

### Phase 0: Extract CRD builders from cluster-level partsOverlays into a prometheus-operator package

The prometheus-operator package is the foundation. Until it exists, nothing else can use `mkServiceMonitor` properly. This is the cert-manager equivalent — CRDs, RBAC, operator deployment, builder functions on `out`.

**Verification:** `nix build` succeeds, and consumer packages (Harbor, CoreDNS) can use `prometheus.out.mkServiceMonitor` from the DI-resolved instance rather than the `partsOverlays` hack.

### Phase 1: Simple standalones (node-exporter, kube-state-metrics)

Small, self-contained packages. node-exporter is a DaemonSet + ServiceAccount. kube-state-metrics is a Deployment + RBAC + ServiceAccount. Both exist as separate upstream projects with their own containers — they were never logically part of Prometheus.

**Verification:** diff against cluster dump shows identical manifests to what the Helm chart produces.

### Phase 2: Prometheus + Alertmanager as CR-based packages

These packages create `Prometheus` and `Alertmanager` CRs respectively — they depend on prometheus-operator for the CRD constructors. Most of the "config" in today's Helm values maps to CR spec fields.

**Verification:** Prometheus and Alertmanager instances are running, scraping targets, and firing alerts.

### Phase 3: Grafana

Standalone deployment, sidecar complexity, dashboard/datasource management. Could remain a Helm chart initially (via `fromHelmChart`) while the native package is built — the composite module doesn't care.

### Phase 4: Move alert rules into owning packages

Migrate the `additionalPrometheusRulesMap` entries from monitoring.nix into the packages that own the metrics. This is the payoff — monitoring.nix shrinks from 900 lines to ~30.

### Phase 5: Write the composite module

Once all sub-packages exist, the composite module ties them together with a clean option interface.

---

## 8. Open Questions

### 8.1 Where do composite modules live?

Options:
- `packages/monitoring/module.nix` — next to the sub-packages, as a peer
- `modules/monitoring.nix` — a new top-level `modules/` directory for cluster-level modules
- `clusters/modules/monitoring.nix` — cluster-specific

Leaning toward `modules/` — composite modules are neither packages (they don't produce resources directly) nor cluster definitions (they're reusable across clusters). A dedicated directory makes the distinction clear.

### 8.2 Should composite modules be in `availablePackages`?

No. They're NixOS modules, not packages. They compose via `imports`, not DI. Keeping the two mechanisms separate avoids confusion: DI resolves packages (things that produce resources), the module system composes behavior (things that wire packages together).

### 8.3 How does `prometheus` resolve for consumers outside the composite?

Harbor lives in `harbor-system`, Prometheus Operator lives in `monitoring-system`. Harbor says `{ prometheus ? null }`. DI resolution (doc 02) does DNS-like lookup: first check same namespace, then fall back to cluster-wide. Since `prometheus-operator` has `aliases = [ "prometheus" "monitoring" ]`, it resolves from any namespace.

### 8.4 Can sub-packages be used without the composite?

Yes. The composite module is a convenience layer — good defaults and a clean option interface. For a different cluster that only needs Prometheus + node-exporter (no Grafana, no Alertmanager), the operator declares them directly:

```nix
instances.monitoring = {
  prometheus-operator = { package = packages.prometheus-operator; };
  prometheus = { package = packages.prometheus; config = { ... }; };
  node-exporter = { package = packages.node-exporter; };
};
```

The composite module adds convenience, not lock-in.

### 8.5 Grafana dashboards

Today dashboards are configured via Helm values (`dashboardsConfigMaps`, `dashboards`). In a native Grafana package, dashboards could be:
- ConfigMaps created by the Grafana package itself (static dashboards)
- ConfigMaps contributed by other packages via DI (each package ships its own dashboard)
- Grafana API provisioning (out of scope for kix)

The "each package ships its dashboard" pattern follows the same DI mechanism as ServiceMonitors. A Harbor package that takes `grafana ? null` could conditionally create a ConfigMap with the Harbor dashboard JSON. This is a refinement for later — dashboards are less critical than alert rules.
