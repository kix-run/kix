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

## IMPORTANT: Plan Before You Build

Helm chart migrations are large, multi-file tasks that touch kixlib, the module, the flake,
and parity testing. Rushing in without a plan leads to rework.

**Before writing any code, enter plan mode and produce a migration plan.** The plan should
cover every phase below and be reviewed by the user before execution begins. This is not
optional — the user expects to see and approve the plan first.

### How to Plan

1. **Enter plan mode** (use the EnterPlanMode tool)
2. Work through Phases 1–2 below (fetch, analyze, inventory) as research
3. Write a concrete plan covering:
   - Inventory of every resource the chart produces (kind, name, conditional?)
   - Which kixlib builders exist for each, and which need to be added
   - Options mapping: which `values.yaml` keys become `mkOption`s in the first pass
   - Any known gotchas (unusual template logic, CRDs, complex conditionals)
   - What "done" looks like — expected resource count, parity check passing
4. Present the plan to the user and wait for approval
5. **Exit plan mode** and execute

If the chart is complex (many resource types, autoscaler sidecars, CRDs), break the plan
into stages — core resources first, optional features second — and get approval for each.

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

### Phase 2: Write the Migration Plan

**This phase happens in plan mode.** Do not skip it.

Using the inventory from Phase 1, write a plan that includes:

1. **Resource list** — every K8s resource to produce, with the kixlib builder for each
2. **New kixlib primitives needed** — any builders that don't exist yet
3. **Options mapping** — which `values.yaml` keys become `mkOption`s
   - First pass: only the options needed for default-values parity
   - Future: optional features behind enable flags
4. **Known complexity** — anything unusual in the Helm templates
   (e.g., conditional RBAC, dual deployments, CRD installation, init containers)
5. **Execution order** — what to build first, what to defer
6. **Definition of done** — expected resource count, parity check command

Present this plan to the user and wait for approval before proceeding.

### Phase 3: Create the Module Structure

Create `pkgs/<chart-name>/` with the module files.

**default.nix** is always the main file. It should contain:
1. **Options** — one `mkOption` per meaningful Helm value (read `references/options-mapping.md`)
2. **Resource construction** — use kixlib builders to create each K8s resource
3. **Config output** — write EACH resource to a separate `config.manifests` entry

Start with the **minimum viable module**: the core resources (usually Deployment + Service +
ConfigMap + ServiceAccount + RBAC) with default values only. Skip optional features
(autoscaler, HPA, PDB, ServiceMonitor) on the first pass.

### Phase 4: Map values.yaml to mkOption

Read `references/options-mapping.md` for the detailed mapping rules.

### Phase 5: Build Resources with kixlib

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

### Phase 6: Verify Parity

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

### Phase 7: Handle Advanced Features

Only after the core resources match, add optional features:
- HPA / Autoscaler (if the chart has them)
- PodDisruptionBudget
- ServiceMonitor / PrometheusRule
- Ingress

Each should be behind an `enable` flag and only add manifests when enabled.

### Phase 8: Expert Review

After the module builds and parity looks reasonable, spawn a Claude Code team to do a
thorough review. This catches issues that are easy to miss when you're deep in the
implementation — wrong defaults, missing resources, subtle parity gaps.

Spawn **two parallel agents** using the Team tool:

1. **Nix module reviewer** — Reviews the kix module code for quality:
   - Read `pkgs/<chart-name>/default.nix` and all files in `pkgs/<chart-name>/scripts/`
   - Read `lib/default.nix` (kixlib) for API context
   - Check: options have correct types and sensible defaults
   - Check: resource construction follows kixlib patterns (withMetadata, selectorLabels, etc.)
   - Check: no Nix anti-patterns (types.anything where types.submodule should be used, etc.)
   - Check: scripts use `@PLACEHOLDER@` substitution (not inline `''${...}` escaping)
   - Check: comments explain "why", TODOs have enough context
   - Report any issues found

2. **Helm parity auditor** — Compares kix output against the Helm chart:
   - Read the Helm chart's `values.yaml`, `_helpers.tpl`, and all template files
   - Read the rendered Helm output (`/tmp/<chart-name>-rendered/` or render it)
   - Read the kix module and built manifests (`result/`)
   - Check: every resource the Helm chart produces has a kix equivalent
   - Check: container images, commands, args, ports, env vars match
   - Check: volume mounts, config content, RBAC rules match
   - Check: service ports, selectors, and service types match
   - Check: conditional resources (behind enable flags) are all accounted for
   - Report missing resources, wrong values, or behavioral differences

Review the team's findings and fix any real issues before considering the migration done.

## When kixlib Needs New Primitives

If the chart needs a resource type kixlib doesn't support yet, add the builder to
`lib/default.nix`. Currently missing (add as needed):
- workload: DaemonSet, Job, CronJob
- networking: Ingress
- rbac: Role, RoleBinding (namespace-scoped)
- config: Secret
- autoscaling: HorizontalPodAutoscaler

Follow existing patterns: group by namespace, use `self.mkResource`, return an attrset.
Add a detailed comment explaining the new builder.

## Shell Scripts in ConfigMaps

Many Helm charts embed shell scripts in ConfigMaps (startup scripts, health checks, etc.).
In Nix multiline strings (`'' ... ''`), `${...}` triggers Nix interpolation — but these
scripts use `${VAR}` for bash variable expansion. Escaping every `${` as `''${` is fragile.

**Best practice: store scripts as separate `.sh` files and use `@PLACEHOLDER@` substitution.**

```
pkgs/<chart-name>/
├── default.nix
└── scripts/
    ├── start-primary.sh    # plain bash, no Nix escaping needed
    ├── start-replica.sh
    └── health-check.sh     # uses @HEADLESS_SERVICE@ for Nix-injected values
```

In `default.nix`, read and substitute:
```nix
startPrimaryScript = builtins.readFile ./scripts/start-primary.sh
  |> builtins.replaceStrings
    [ "@HEADLESS_SERVICE@" "@NAMESPACE@" "@REPLICA_COUNT@" ]
    [ headlessSvcFqdn      cfg.namespace   (toString totalReplicas) ];
```

This gives you:
- **No escaping hell** — bash `${VAR}` is just literal text in `.sh` files
- **Explicit interpolation points** — `@FOO@` stands out visually
- **Editor/shellcheck support** — `.sh` files get proper syntax highlighting

The `@PLACEHOLDER@` convention comes from nixpkgs' `substitute`/`substituteAll` builders.

Use inline Nix strings only for very short scripts (< 5 lines) with no shell variables.

## Common Pitfalls

- **Don't replicate Helm's naming complexity.** Skip nameOverride/fullnameOverride.
- **Don't use `types.anything` for typed data.** Use specific types and submodules.
- **Don't forget selector parity.** Use `selectorLabels` — a stable subset of labels.
- **Don't put version labels in selectors.** This breaks rolling updates.
- **Don't ignore conditional resources.** Mirror Helm's `if` guards with `lib.optionalAttrs`.
- **Don't forget ports on Services.** `intoService` does NOT auto-derive ports.
- **Don't embed large shell scripts as Nix strings.** Use separate `.sh` files with `@PLACEHOLDER@` substitution (see above).
- **Leave comments.** Explain why, not just what. Document known issues and TODOs.
