# Pipe-Based Chart Composition — Blast & Rebuild

## Context

Luca's vision (doc 10C) is charts as scannable pipelines:
```nix
mkServiceDeployment { ... } |> withAutoscaler { ... } |> withPDB { ... } |> withMetrics { ... }
```

The V4 migration replaced `monitoring.targets` with `capabilities.monitoring` (correct) but barely touched the charts themselves — they're still 400-900 line flat resource templates. The combinators (`withAutoscaler`, `withPDB`) exist in kixlib but no chart uses them. We need to blast the charts open and rebuild them around pipes.

## Architecture Confirmed

**`self` propagation works**: `withMetadata` uses `self.extend` (fixpoint), so `kixlib'.combinators.mkServiceDeployment` will call `self.workload.mkDeployment` which resolves to the metadata-applied version. Combinators inherit namespace/labels automatically.

**Manifest names must stay identical** — 42 tests reference exact names like `"coredns-deployment"`. Group keys must match.

**Monitoring output reads stay guarded** — `optionalPipe` doesn't remove the need for if/else guards on `config.capabilities.monitoring.*.output.labels` because the guard prevents evaluation of non-existent capability targets. The pipe just controls whether the metrics Service is added to the group.

---

## Step 1: New combinators in `lib/default.nix`

Add to the `combinators` block (after line 1148):

### `mkServiceDeployment`
Creates `{ "${name}-deployment" = ...; "${name}-service" = ...; }` group.

```nix
mkServiceDeployment = {
  name,              # Base name — becomes manifest key prefix
  containers,
  selectorLabels,    # Explicit — charts extend these with component labels
  servicePorts,
  replicas ? 1,
  serviceType ? "ClusterIP",
  strategy ? null,
  volumes ? [],
  serviceAccountName ? null,
  podAnnotations ? {},
  podLabels ? {},     # Extra labels on pod template (merged with selectorLabels)
  deploymentLabels ? {},
  serviceLabels ? {},
  serviceAnnotations ? {},
  podSpec ? {},       # Extra fields merged into pod spec (dnsPolicy, securityContext, etc.)
}: let
  deployment = self.workload.mkDeployment ({
    metadata.labels = deploymentLabels;
    inherit replicas selectorLabels;
    template = self.pod.mkPodTemplate {
      metadata = {
        labels = selectorLabels // podLabels;
        annotations = podAnnotations;
      };
      spec = {
        inherit containers volumes;
      } // lib.optionalAttrs (serviceAccountName != null) {
        inherit serviceAccountName;
      } // podSpec;
    };
  } // lib.optionalAttrs (strategy != null) { inherit strategy; });
  service = self.networking.mkService {
    metadata = {
      inherit name;
      labels = serviceLabels;
      annotations = serviceAnnotations;
    };
    spec = {
      type = serviceType;
      ports = servicePorts;
      selector = selectorLabels;
    };
  };
in {
  "${name}-deployment" = deployment;
  "${name}-service" = service;
};
```

### `withMetrics`
Adds a metrics Service to the group, extracting selector from a workload.

```nix
withMetrics = {
  workloadKey,        # Key of workload to get selector from
  metricsName,        # Manifest key for the metrics Service
  metricsPort,
  portName ? "metrics",
  metricsServiceName ? null,  # K8s Service name (defaults to metricsName)
  monitoringLabels ? {},
  monitoringAnnotations ? {},
  extraServiceAnnotations ? {},
  extraLabels ? {},
}: group: let
  workload = group.${workloadKey};
  selectorLabels = workload.spec.selector.matchLabels;
in group // {
  ${metricsName} = self.networking.mkService {
    metadata = {
      name = if metricsServiceName != null then metricsServiceName else metricsName;
      labels = { "app.kubernetes.io/component" = "metrics"; } // extraLabels // monitoringLabels;
      annotations = extraServiceAnnotations // monitoringAnnotations;
    };
    spec = {
      type = "ClusterIP";
      ports = [{ name = portName; port = metricsPort; targetPort = metricsPort; protocol = "TCP"; }];
      selector = selectorLabels;
    };
  };
};
```

### `mkMonitoringCapability`
Pure helper to build the capability declaration for extraConfig.

```nix
mkMonitoringCapability = { serviceName, namespace, portName ? "metrics", port, path ? "/metrics", selector }:
  { inherit serviceName namespace portName port path selector; };
```

### `withEnable`
Maps `enable` over a manifestList (for conditional groups like cainjector).

```nix
withEnable = enable: list: map (entry: entry // { inherit enable; }) list;
```

---

## Step 2: Refactor CoreDNS (`pkgs/coredns/resources.nix`)

**Target: 441 → ~310 lines** (~30% reduction)

Replace manual deployment + service + metrics + HPA + PDB construction (lines 196-280) with a pipeline. Keep everything else (Corefile builder, port derivation, RBAC, ConfigMap, autoscaler sub-deployment) as-is.

### Before (current):
```nix
deployment = kixlibCoredns.workload.mkDeployment { ... };      # 26 lines
service = kixlibCoredns.networking.mkService { ... };           # 7 lines
metricsService = kixlibCoredns.networking.mkService { ... };    # 17 lines
pdb = kixlibCoredns.policy.mkPodDisruptionBudget { ... };       # 10 lines
hpa = kixlibCoredns.autoscaling.mkHorizontalPodAutoscaler { ... }; # 8 lines
# ... then in manifestList, 5 separate entries with enable conditions
```

### After (pipe):
```nix
inherit (kixlibCoredns.combinators) mkServiceDeployment optionalPipe
  withAutoscaler withPodDisruptionBudget withMetrics groupToManifestList;

mainGroup = mkServiceDeployment {
  name = "coredns";
  containers = [ container ];
  selectorLabels = selectorLabels;
  servicePorts = ports.servicePorts;
  replicas = if cfg.hpa.enabled || cfg.autoscaler.enabled then null else cfg.replicaCount;
  serviceType = cfg.serviceType;
  strategy = { type = "RollingUpdate"; rollingUpdate = { maxUnavailable = 1; maxSurge = "25%"; }; };
  volumes = [ configVolume ];
  inherit serviceAccountName;
  deploymentLabels = { "app.kubernetes.io/version" = cfg.image.tag; };
  podAnnotations = lib.optionalAttrs cfg.isClusterService {
    "scheduler.alpha.kubernetes.io/tolerations" = ''[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'';
  };
  podSpec = { terminationGracePeriodSeconds = 30; }
    // lib.optionalAttrs cfg.isClusterService { dnsPolicy = "Default"; };
}
|> optionalPipe (hasPrometheus && cfg.prometheus.service.enabled) (withMetrics {
  workloadKey = "coredns-deployment";
  metricsName = "coredns-service-metrics";
  metricsServiceName = "coredns-metrics";
  metricsPort = 9153;
  monitoringLabels = monitoringLabels;
  monitoringAnnotations = monitoringAnnotations;
  extraServiceAnnotations = cfg.prometheus.service.annotations;
})
|> optionalPipe cfg.hpa.enabled (withAutoscaler {
  workloadKey = "coredns-deployment";
  hpaName = "coredns-hpa";
  hpaArgs = { inherit (cfg.hpa) minReplicas maxReplicas metrics; };
})
|> optionalPipe pdbEnabled (withPodDisruptionBudget {
  workloadKey = "coredns-deployment";
  pdbName = "coredns-poddisruptionbudget";
  pdbArgs = ...;
});
```

### manifestList becomes:
```nix
manifestList =
  groupToManifestList mainGroup
  ++ [
    { name = "coredns-configmap"; resource = coreDnsConfigMap; enable = true; }
    { name = "coredns-clusterrole"; resource = clusterRole; enable = true; }
    { name = "coredns-clusterrolebinding"; resource = binding; enable = true; }
    { name = "coredns-serviceaccount"; resource = sa; enable = cfg.serviceAccount.create; }
    # Autoscaler sub-deployment (separate kixlib, cannot pipe into main group)
    { name = "coredns-autoscaler-serviceaccount"; resource = autoscalerSa; enable = cfg.autoscaler.enabled; kixlib = autoscalerKixlib; }
    { name = "coredns-autoscaler-configmap"; resource = autoscalerConfigMap; enable = cfg.autoscaler.enabled; kixlib = autoscalerKixlib; }
    { name = "coredns-autoscaler-clusterrole"; resource = autoscalerClusterRole; enable = cfg.autoscaler.enabled; kixlib = autoscalerKixlib; }
    { name = "coredns-autoscaler-clusterrolebinding"; resource = autoscalerBinding; enable = cfg.autoscaler.enabled; kixlib = autoscalerKixlib; }
    { name = "coredns-autoscaler-deployment"; resource = autoscalerDeployment; enable = cfg.autoscaler.enabled; kixlib = autoscalerKixlib; }
  ];
```

**What disappears**: 5 separate resource definitions (~68 lines) replaced by 1 pipeline (~25 lines).

---

## Step 3: Refactor cert-manager (`pkgs/cert-manager/resources.nix`)

**Target: 630 → ~420 lines** (~33% reduction)

cert-manager has 3 near-identical components (controller, webhook, cainjector), each with Deployment + Service + SA. Create a local `mkComponent` helper wrapping `mkServiceDeployment`.

### Local helper (in resources.nix, not kixlib):
```nix
mkComponent = { componentName, labels, container, replicas, servicePorts,
  monitoringLabels ? {}, monitoringAnnotations ? {}, extraPodSpec ? {} }:
  kixlib'.combinators.mkServiceDeployment {
    name = componentName;
    containers = [ container ];
    selectorLabels = labels.selector;
    inherit servicePorts replicas;
    deploymentLabels = labels.all;
    serviceLabels = labels.all // monitoringLabels;
    serviceAnnotations = monitoringAnnotations;
    podLabels = labels.all;
    podAnnotations = prometheusAnnotations;
    podSpec = { enableServiceLinks = false; securityContext = podSecurityContext; inherit nodeSelector; } // extraPodSpec;
  };
```

### Three components become:
```nix
controllerGroup = mkComponent {
  componentName = "cert-manager";
  labels = controllerLabels;
  container = controllerContainer;
  replicas = cfg.replicaCount;
  servicePorts = [{ port = 9402; protocol = "TCP"; name = "tcp-prometheus-servicemonitor"; targetPort = 9402; }];
  monitoringLabels = controllerMonitoringLabels;
  monitoringAnnotations = controllerMonitoringAnnotations;
};

webhookGroup = mkComponent { ... };
cainjectorGroup = mkComponent { ... };
```

### manifestList splices groups + manual resources:
```nix
manifestList =
  groupToManifestList controllerGroup
  ++ [{ name = "cert-manager-sa"; resource = controllerSa; enable = cfg.serviceAccount.create; }]
  ++ controllerRbac.toManifestList cfg.rbac.create
  ++ groupToManifestList webhookGroup
  ++ [{ name = "cert-manager-webhook-sa"; ... }]
  ++ webhookClusterRbac.toManifestList cfg.rbac.create
  ++ webhookRoleBindingRbac.toManifestList cfg.rbac.create
  ++ withEnable cfg.cainjector.enabled (groupToManifestList cainjectorGroup)
  ++ withEnable cfg.cainjector.enabled [{ name = "cert-manager-cainjector-sa"; ... }]
  ++ ...
  ++ [{ name = "cert-manager-startupapicheck-job"; ... }]
  ++ [{ name = "cert-manager-webhook-mutating"; ... }]
  ++ [{ name = "cert-manager-webhook-validating"; ... }];
```

**What disappears**: 3× manual Deployment+Service construction (~90 lines) replaced by 3 calls to `mkComponent` (~30 lines).

---

## Step 4: Refactor Valkey (`pkgs/valkey/resources.nix`)

**Target: 911 → ~780 lines** (modest, ~14% reduction)

Valkey is the most resistant to pipes due to mode branching (sentinel vs replication), StatefulSets (not Deployments), and 3 different workloads with different configs. Full pipe refactor needs `mkStatefulService` which is a bigger design.

### Minimal pipe usage:
- **withMetrics** for the metrics Service (replaces manual metricsSvc construction)
- **withPodDisruptionBudget** for both PDB variants (if we add metadata support)
- **withAutoscaler** for the HPA (already exists, just needs wiring)
- Leave StatefulSet construction manual

### Approach:
1. Create a group from the StatefulSet that the metrics/HPA/PDB attach to
2. Pipe through withMetrics, optionalPipe for PDB/HPA
3. Keep mode-branching, container construction, config rendering as-is

```nix
# The target workload depends on mode
workloadGroup = kixlibValkey.combinators.mkGroup ({
  # Mode-specific StatefulSets stay manual
} // lib.optionalAttrs cfg.sentinel.enabled {
  "valkey-node" = sentinelStatefulSet;
} // lib.optionalAttrs (!cfg.sentinel.enabled) {
  "valkey-primary" = primaryStatefulSet;
  "valkey-replicas" = replicaStatefulSet;
})
|> optionalPipe cfg.metrics.enabled (withMetrics {
  workloadKey = if cfg.sentinel.enabled then "valkey-node" else "valkey-primary";
  metricsName = "valkey-metrics";
  metricsServiceName = "${fullname}-metrics";
  metricsPort = 9121;
  portName = "http-metrics";
  monitoringLabels = valkeyMonitoringLabels;
  monitoringAnnotations = valkeyMonitoringAnnotations;
  extraLabels = labels.all // { "app.kubernetes.io/component" = "metrics"; };
})
|> optionalPipe (cfg.pdb.enabled && cfg.sentinel.enabled) (withPodDisruptionBudget {
  workloadKey = "valkey-node";
  pdbName = "valkey-pdb";
  pdbArgs = { ... };
})
|> optionalPipe (cfg.hpa.enabled) (withAutoscaler {
  workloadKey = if cfg.sentinel.enabled then "valkey-node" else "valkey-replicas";
  hpaName = "valkey-hpa";
  hpaArgs = { ... };
});
```

---

## Step 5: Update golden files & run all checks

After each chart refactor:
1. `nix build .#<variant> --show-trace` for all variants of that chart
2. `./scripts/update-golden.sh`
3. `git diff tests/` — verify ONLY expected changes (ideally zero if resource shapes unchanged)
4. `nix flake check` — all 42 checks must pass
5. Commit per chart

---

## Step 6: Commit strategy

1. **Commit 1**: New combinators in `lib/default.nix` (additive, nothing breaks)
2. **Commit 2**: CoreDNS pipe refactor + golden file updates
3. **Commit 3**: cert-manager pipe refactor + golden file updates
4. **Commit 4**: Valkey pipe refactor + golden file updates

---

## Files to modify

| File | Change |
|------|--------|
| `lib/default.nix` | Add mkServiceDeployment, withMetrics, mkMonitoringCapability, withEnable to combinators |
| `pkgs/coredns/resources.nix` | Replace manual resource defs with pipe chain |
| `pkgs/cert-manager/resources.nix` | Add mkComponent helper, replace 3× Deployment+Service |
| `pkgs/valkey/resources.nix` | Use withMetrics, withAutoscaler, withPDB via pipes |
| `tests/*/golden/*.yaml` | Regenerate (expect minimal/zero diff if shapes unchanged) |

---

## Verification

For each commit:
```bash
# Build all variants
nix build .#coredns --show-trace
nix build .#coredns-prometheus --show-trace
nix build .#valkey-full --show-trace
nix build .#cert-manager --show-trace
nix build .#cluster-example --show-trace

# Regenerate and diff golden files
./scripts/update-golden.sh
git diff tests/

# Full check suite (42 checks)
nix flake check

# Spot-check pipe output in nix repl
nix repl .#
# > config.manifests ? "coredns-deployment"
# > config.manifests ? "coredns-hpa"
# > config.capabilities.monitoring.coredns.output.labels
```

## Key risks

- **Metadata merging order**: `mkResource` does `recursiveUpdate _defaultMetadata metadata` — explicit metadata in combinators wins over withMetadata defaults. This is correct.
- **Golden file churn**: If field ordering changes in the attrset, YAML output may reorder. Semantically identical but creates noise. Mitigation: regenerate, diff carefully, accept if semantic-only.
- **valkey mode branching**: The pipe chain has conditional workloadKeys (`if cfg.sentinel.enabled then "valkey-node" else "valkey-primary"`). This is awkward but correct — the alternative is separate pipe chains per mode which is worse.
