---
name: helm-to-kix
description: >
  Migrate a Helm chart to a kix module in the kixpkgs repo. Use this skill whenever the user
  wants to port, convert, or migrate a Helm chart to kix/Nix, add a new package to kixpkgs,
  or asks about translating Kubernetes Helm templates into Nix modules. Also use when the user
  says things like "add coredns to kixpkgs", "port the nginx-ingress chart", or "create a kix
  module for <service-name>".
---

# Helm-to-Kix Migration

This skill guides you through converting a Helm chart into a kix module for the kixpkgs repo.
The kixpkgs repo lives at `~/Projects/kixpkgs` and follows a standard structure.

## Key Architecture Decisions

Before starting, understand these decisions (documented in `lib/default.nix` header):

1. **Human-readable names** — resources get names like "coredns", NOT Nix store paths.
   `kixlib.resourceName` derives the name from metadata. Store paths are illegal in K8s names.
2. **One manifest per resource** — each resource is a separate entry in `config.manifests`,
   not bundled into a single derivation. This makes verification and inspection work.
3. **Resources are attrsets, not derivations** — all builders return plain attrsets.
   Only `mkManifest` serializes. This means you can always compose further.
4. **Selector labels != all labels** — pass `selectorLabels` to `mkDeployment` with only
   stable labels. Never include version labels in selectors.
5. **Container passthrough** — `mkContainer` passes through ALL arguments. Don't worry
   about listing every field — anything you pass will be preserved.

## Repo Structure

```
kixpkgs/
├── lib/default.nix          # kixlib - shared builders (mkDeployment, mkService, etc.)
├── modules/default.nix      # Base module (defines manifests option)
├── pkgs/<chart-name>/       # One directory per migrated chart
│   ├── default.nix          # Options + wiring (the main module)
│   ├── deployment.nix       # Deployment-specific options (if complex)
│   ├── autoscaler.nix       # Autoscaler options (if chart has one)
│   └── ...                  # Split by resource type only when needed
├── examples/                # Example configs showing how to use modules
├── scripts/verify-parity.sh # Automated helm vs kix behavioral diff checker
└── flake.nix                # Flake that wires everything together
```

## Migration Process

Follow these phases in order. The key insight: do NOT try to translate Helm templates line-by-line.
Instead, understand what resources the chart produces with default values, then build those same
resources idiomatically in Nix using kixlib.

### Phase 1: Fetch and Analyze the Helm Chart

1. **Fetch the chart** to `/tmp/<chart-name>`:
   ```bash
   helm repo add <repo> <url>  # if not already added
   helm pull <repo>/<chart> --untar --destination /tmp/
   ```

2. **Render the default output** as your reference target:
   ```bash
   helm template release-name /tmp/<chart-name> --output-dir /tmp/<chart-name>-rendered
   ```

3. **Read and understand the chart structure**:
   - `values.yaml` — identify every configurable value and its default
   - `_helpers.tpl` — note naming conventions (fullname, labels, selectors)
   - Each template file — understand which resources are created and under what conditions
   - `Chart.yaml` — note the appVersion (container image tag)

4. **Create an inventory** of resources the chart produces. For each resource, note:
   - Kind (Deployment, Service, ConfigMap, etc.)
   - What values control it (enabled flags, conditional creation)
   - Which kixlib builder applies (`workload.mkDeployment`, `networking.mkService`, etc.)
   - Anything that would need a new kixlib primitive (see "When kixlib Needs New Primitives")

### Phase 2: Create the Module Structure

Create `pkgs/<chart-name>/` with the module files.

**default.nix** is always the main file. It should contain:
1. **Options** — one `mkOption` per meaningful Helm value (read `references/options-mapping.md`)
2. **Resource construction** — use kixlib builders to create each K8s resource
3. **Config output** — write EACH resource to a separate `config.manifests` entry

Start with the **minimum viable module**: the core resources (usually Deployment + Service +
ConfigMap + ServiceAccount + RBAC) with default values only. Skip optional features
(autoscaler, HPA, PDB, ServiceMonitor) on the first pass.

### Phase 3: Map values.yaml to mkOption

Read `references/options-mapping.md` for the detailed mapping rules.

### Phase 4: Build Resources with kixlib

Read `references/kixlib-patterns.md` for the builder API. Critical patterns:

```nix
let
  cfg = config.services.<chart-name>;

  # Stable labels for selectors — NEVER include version labels here
  selectorLabels = {
    "app.kubernetes.io/name" = "<chart-name>";
    "app.kubernetes.io/instance" = "release-name";
  };

  # Configure kixlib with chart-wide metadata
  kixlib' = kixlib.withMetadata {
    namespace = cfg.namespace;
    labels = selectorLabels // {
      "app.kubernetes.io/managed-by" = "kix";
    };
  };

  # Build each resource separately
  sa = kixlib'.rbac.mkServiceAccount { };
  clusterRole = kixlib'.rbac.mkClusterRole { rules = [ /* ... */ ]; };
  binding = kixlib'.rbac.mkClusterRoleBinding clusterRole sa;

  configMap = kixlib'.configMap.mkConfigMap { }
    |> kixlib'.configMap.withEntry "config-key" configValue;

  container = kixlib'.pod.mkContainer {
    name = "<chart-name>";
    image = "${cfg.image.repository}:${cfg.image.tag}";
    # all fields pass through — add ports, env, resources, probes, etc.
  };

  deployment = kixlib'.workload.mkDeployment {
    replicas = cfg.replicaCount;
    selectorLabels = selectorLabels;  # IMPORTANT: stable subset of labels
    template = kixlib'.pod.mkPodTemplate {
      metadata.labels = selectorLabels;
      spec.containers = [ container ];
    };
  }
  |> kixlib'.workload.withServiceAccount sa;

  service = kixlib'.networking.mkService {
    spec = {
      type = cfg.serviceType;
      ports = [ /* must be specified explicitly — not auto-derived */ ];
      selector = selectorLabels;
    };
  };
in
{
  # ONE ENTRY PER RESOURCE — not one per module
  config.manifests = lib.optionalAttrs cfg.enable {
    "<chart-name>-sa" = kixlib'.mkManifest sa;
    "<chart-name>-clusterrole" = kixlib'.mkManifest clusterRole;
    "<chart-name>-clusterrolebinding" = kixlib'.mkManifest binding;
    "<chart-name>-configmap" = kixlib'.mkManifest configMap;
    "<chart-name>-deployment" = kixlib'.mkManifest deployment;
    "<chart-name>-service" = kixlib'.mkManifest service;
  };
}
```

### Phase 5: Verify Parity

This is the critical feedback loop.

1. **Wire the chart into flake.nix** first:
   ```nix
   packages.<chart-name> = mkChartManifests ./pkgs/<chart-name> {
     services.<chart-name>.enable = true;
   };
   ```

2. **Run verification**:
   ```bash
   ./scripts/verify-parity.sh <chart-name>
   ```

The script strips cosmetic differences (helm.sh/chart labels, managed-by, checksum annotations,
kix dependency annotations) and compares resources by kind.

**What must match** (behavioral parity):
- Resource kinds and their count
- Container images, commands, args, ports
- Volume mounts and config content
- RBAC rules
- Service ports and selectors
- Pod labels used for selector matching

**What can differ** (cosmetic):
- `helm.sh/chart`, `app.kubernetes.io/managed-by` labels
- `meta.helm.sh/*` annotations
- `checksum/config` vs kix store-path based integrity
- Resource naming conventions

Iterate until the behavioral diff is clean.

### Phase 6: Handle Advanced Features

Only after the core resources match, add optional features:
- HPA / Autoscaler (if the chart has them)
- PodDisruptionBudget
- ServiceMonitor / PrometheusRule
- Ingress

Each should be behind an `enable` flag and only add manifests when enabled.

## When kixlib Needs New Primitives

If the chart needs a resource type kixlib doesn't support yet, add the builder to
`lib/default.nix`. Currently missing (add as needed):
- workload: StatefulSet, DaemonSet, Job, CronJob
- networking: Ingress, NetworkPolicy
- rbac: Role, RoleBinding (namespace-scoped)
- config: Secret
- policy: PodDisruptionBudget
- autoscaling: HorizontalPodAutoscaler
- monitoring: ServiceMonitor

Follow existing patterns: group by namespace, use `self.mkResource`, return an attrset.
Add a detailed comment explaining the new builder.

## Common Pitfalls

- **Don't replicate Helm's naming complexity.** Skip nameOverride/fullnameOverride.
- **Don't use `types.anything` for typed data.** Use specific types and submodules.
- **Don't forget selector parity.** Use `selectorLabels` — a stable subset of labels.
- **Don't put version labels in selectors.** This breaks rolling updates.
- **Don't ignore conditional resources.** Mirror Helm's `if` guards with `lib.optionalAttrs`.
- **Don't forget ports on Services.** `intoService` does NOT auto-derive ports.
- **Leave comments.** Explain why, not just what. Document known issues and TODOs.
