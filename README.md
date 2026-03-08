# kixpkgs

Kubernetes packages built with Nix. Each Helm chart is replaced by a native Nix module, evaluated with `lib.evalModules` -- the same module system that powers NixOS. You get typed options, cross-module references, and composable resource builders instead of Go templates and YAML.

## Quick start

```bash
# Build a single chart's manifests (outputs JSON files, one per resource)
nix build .#coredns

# Build a multi-chart cluster definition
nix build .#cluster-example

# Run all checks (structural assertions + kubeconform schema validation)
nix flake check
```

Manifests land in `./result/`, one JSON file per Kubernetes resource.

## Project structure

```
lib/              kixlib -- shared resource builders (mkDeployment, mkService, etc.)
modules/          Module system: base manifests option + intent merging layers
  cluster.nix       Level 1: cluster-wide defaults (domain, labels)
  registry.nix      Level 2: service endpoint registry
  monitoring.nix    Level 3: cross-cutting ServiceMonitor generation
  network-policy.nix Level 3: NetworkPolicy aggregation (skeleton)
pkgs/<name>/      One directory per migrated chart (coredns, valkey)
clusters/         Cluster definitions that compose multiple charts
scripts/          Parity testing tools (verify-parity.py)
tests/            Per-chart parity test fixtures
```

## Defining a cluster

A cluster definition is a Nix module that enables services and sets options. See `clusters/example.nix`:

```nix
{
  # Cluster-wide labels applied to every resource
  cluster.labels = {
    "app.kubernetes.io/part-of" = "kix-example";
    "team" = "platform";
  };

  # Each service gets its own namespace
  services.coredns = {
    enable = true;
    namespace = "kube-system";
    replicaCount = 2;
  };

  services.valkey = {
    enable = true;
    namespace = "cache";
    sentinel.enabled = true;
    metrics.enabled = true;
    auth.existingSecret = "valkey-auth";
  };

  # Cross-cutting monitoring aggregates scrape targets from all charts
  monitoring = {
    enabled = true;
    defaultInterval = "15s";
  };
}
```

The flake evaluates this with `mkCluster`, which loads all chart modules and the shared module infrastructure. Each chart writes its resources to `config.manifests`, and the result is a directory of JSON files ready for `kubectl apply`.

## How chart modules work

Each chart module under `pkgs/<name>/` declares options under `services.<name>` and writes Kubernetes resources to `config.manifests`. Resources are built using kixlib builders (`mkDeployment`, `mkService`, `mkConfigMap`, etc.), which return plain attribute sets. Only `mkManifest` serializes to JSON.

```nix
# Simplified example of what a chart module does
config.manifests."coredns-deployment" = kixlib.mkManifest deployment;
config.manifests."coredns-service" = kixlib.mkManifest service;
```

kixlib is passed to every module via `specialArgs`. It provides:

- Resource builders: `workload.mkDeployment`, `workload.mkStatefulSet`, `networking.mkService`, `configMap.mkConfigMap`, `rbac.mkClusterRole`, etc.
- Composition helpers: `workload.withServiceAccount`, `workload.intoService`, `pod.withVolumeMount`
- Global metadata: `withMetadata` sets namespace/labels/annotations on all resources
- Null stripping and preprocessing pipeline in `mkManifest`

## Intent merging

The module system supports three levels of intent merging, so charts interact and share state rather than being evaluated in isolation:

**Level 1 -- Cluster defaults** (`modules/cluster.nix`): Cluster-wide settings like DNS domain and organization labels. Charts consume these via `lib.mkDefault`, so per-chart overrides still win.

**Level 2 -- Service registry** (`modules/registry.nix`): Charts declare their endpoints (host, port, protocol). Other charts or modules reference them by name without hardcoding DNS. The registry is mode-aware -- valkey's primary endpoint changes automatically between sentinel and replication mode.

**Level 3 -- Cross-cutting modules** (`modules/monitoring.nix`, `modules/network-policy.nix`): Aggregate declarations from all charts and materialize shared resources. When `monitoring.enabled = true`, the monitoring module creates ServiceMonitors from declared scrape targets across all charts, replacing per-chart ServiceMonitor creation.

All levels are always loaded. Nix laziness means zero overhead for charts that don't use them.

## Testing

### Structural checks and schema validation

```bash
nix flake check
```

This runs two kinds of checks:

- **Structural assertions**: Verify that intent merging works (registry populated, monitoring targets wired, cross-cutting resources created).
- **Schema validation**: Validates all manifests against Kubernetes API schemas using kubeconform.

### Parity tests

Parity tests compare kix output against Helm's `helm template` output to verify migration correctness:

```bash
./scripts/verify-parity.py all coredns
./scripts/verify-parity.py all valkey
```

## Available packages

| Package | Description |
|---------|-------------|
| `coredns` | CoreDNS with default settings |
| `valkey` | Valkey (replication mode) |
| `valkey-sentinel` | Valkey with sentinel |
| `valkey-full` | Valkey with sentinel, metrics, ServiceMonitor, NetworkPolicy, PDB |
| `cluster-example` | Multi-chart cluster (coredns + valkey with sentinel and monitoring) |

## Current status

This project is **experimental and actively developed**. Two charts have been migrated (CoreDNS and Valkey). The intent merging system is functional but the cross-cutting network policy module is still a skeleton. Additional resource types (DaemonSet, Job, Ingress, Secret, HPA) will be added as new charts need them.
