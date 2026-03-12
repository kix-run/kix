# kixpkgs

Kubernetes packages built with Nix using a fixpoint pattern. Each Helm chart is replaced by a self-referential package where resources reference each other via `self.*`, dependencies are tracked automatically through a tree walker, and transitive closures are computed at eval time. No YAML templating, no module system -- just `lib.fix` and plain attrsets.

## Quick start

```bash
# Build a single package (outputs YAML files, one per resource)
nix build .#coredns
ls result/

# Build a full cluster (all packages composed)
nix build .#cluster-example

# Run all checks (schema validation + assertions + cross-resource validation)
nix flake check

# Visualize the resource dependency DAG
nix build .#fp-dag-svg && open result/dag.svg
```

Manifests land in `./result/`, one YAML file per Kubernetes resource, named `{name}-{kind}.yaml`.

## Project structure

```
lib/
  default.nix           kixlib -- YAML serialization (mkManifest), null stripping
  fixpoint/
    refs.nix            Ref tracking (mkRef, str) -- values that remember their source resource
    resolve.nix         Tree walker -- recurses specs, resolves refs, collects deps
    closure.nix         Transitive closure (BFS over deps + requires)
    resource.nix        mkResource -- wraps a K8s manifest with ref/deps/closure
    package.nix         mkPackage -- inner fixpoint (self-referential resource set)
    cluster.nix         mkCluster -- outer fixpoint (self-referential package set + overlays)
    default.nix         Re-exports everything as the `k8s` API

pkgs-fp/
  coredns/              CoreDNS package (Deployment, Service, RBAC, ConfigMap, optional HPA/PDB/autoscaler)
  valkey/               Valkey package (StatefulSet, sentinel mode, metrics, NetworkPolicy, PDB, HPA)
  cert-manager/         cert-manager package (controller, webhook, cainjector, startupapicheck, extensive RBAC)

clusters/
  example.nix           3-chart cluster (coredns + valkey + cert-manager) with overrides
  test-full.nix         All features enabled -- stress test for optional resource gating
  test-minimal.nix      Single chart with defaults -- negative assertion target

.github/workflows/
  check.yml             CI: nix flake check + build clusters + upload manifest artifacts
```

## How packages work

A package is a function `args -> self -> { resources..., main }` passed to `k8s.mkPackage`. The inner fixpoint (`lib.fix`) lets resources reference each other via `self.*`.

```nix
k8s.mkPackage
  ({ namespace ? "default", replicaCount ? 1, ... }: self: {

    configmap = k8s.mkResource {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "myapp";
      inherit namespace;
      data = { "config.yaml" = "..."; };
    };

    workload = k8s.mkResource {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "myapp";
      inherit namespace;
      requires = [ self.configmap ];  # inverted dep: workload needs the ConfigMap
      spec = {
        template.spec.volumes = [{
          name = "config";
          configMap.name = self.configmap.ref;  # ref tracking: tree walker records the dep
        }];
      };
    };

    service = k8s.mkResource {
      apiVersion = "v1";
      kind = "Service";
      name = "myapp";
      inherit namespace;
      outputs = { port = 8080; };     # named outputs other packages can consume
      spec.selector = { "app" = "myapp"; };
    };

    # main = the public interface. Its closure is what gets deployed.
    main = k8s.withRequires [ self.workload ] self.service;
  })
  { namespace = "default"; }  # default args
```

Key concepts:

- **`ref`** -- `resource.ref` is a tracked value that resolves to the resource's name. When used in another resource's spec, the tree walker automatically records the dependency.
- **`requires`** -- Inverted deps for resources that are needed but don't appear in the spec (e.g., a Deployment requires its ConfigMap to exist, but the ConfigMap doesn't reference the Deployment).
- **`closure`** -- `resource.closure` is the transitive closure (BFS over deps + requires). `pkg.closure` is shorthand for `pkg.main.closure` -- everything needed to deploy.
- **`outputs`** -- Named values exposed as tracked refs. `pkg.out.port` gives you the port number while tracking the dependency on the package.
- **`override`** -- Change package arguments: `pkg.override { namespace = "staging"; replicas = 3; }`. Re-evaluates the entire fixpoint with new args.
- **`overrideParts`** -- Swap individual resources: `pkg.overrideParts (self: super: { workload = ...; })`. Inner fixpoint re-resolves around the change.

## How clusters work

A cluster composes packages using an outer fixpoint, following the same pattern as nixpkgs overlays:

```nix
# clusters/example.nix
{ k8s, lib }:

k8s.mkCluster {
  basePackages = self: {
    coredns = (import ../pkgs-fp/coredns { inherit k8s lib; }).override {
      namespace = "kube-system";
      replicaCount = 2;
      prometheus.service.enabled = true;
      clusterLabels = {
        "app.kubernetes.io/part-of" = "kix-example";
        "team" = "platform";
      };
    };

    valkey = (import ../pkgs-fp/valkey { inherit k8s lib; }).override {
      namespace = "cache";
      sentinel.enabled = true;
      metrics.enabled = true;
    };

    cert-manager = (import ../pkgs-fp/cert-manager { inherit k8s lib; }).override {
      namespace = "cert-manager";
    };
  };

  # overlays = [ (self: super: { ... }) ];  # nixpkgs-style overlays (optional)
}
```

`mkCluster` unions all package closures into a single deduplicated manifest list. The result exposes:

- `.manifests` -- all resources across all packages
- `.packages` -- the package set
- `.dagDot` / `.dagTree` -- DAG visualization (Graphviz DOT / text tree)

## Available packages and variants

Each package has a default configuration plus named variants with specific features enabled:

### CoreDNS

| Target | Description |
|--------|-------------|
| `coredns` | Default (Deployment + Service + RBAC + ConfigMap) |
| `coredns-prometheus` | + metrics Service with scrape annotations |
| `coredns-serviceaccount` | + dedicated ServiceAccount |
| `coredns-pdb` | + PodDisruptionBudget |
| `coredns-hpa` | + HorizontalPodAutoscaler |
| `coredns-autoscaler` | + cluster-proportional autoscaler (separate Deployment) |

### Valkey

| Target | Description |
|--------|-------------|
| `valkey` | Default replication mode (primary + replica StatefulSets) |
| `valkey-sentinel` | Sentinel mode (single node StatefulSet with sentinel sidecar) |
| `valkey-full` | Sentinel + metrics exporter + NetworkPolicy + PDB |
| `valkey-hpa` | Replica HPA |
| `valkey-hpa-sentinel` | Sentinel + replica HPA |

### cert-manager

| Target | Description |
|--------|-------------|
| `cert-manager` | Full install (controller + webhook + cainjector + startupapicheck) |
| `cert-manager-no-cainjector` | Without CA injector |
| `cert-manager-no-startupapicheck` | Without startup API check Job |

### Clusters

| Target | Description |
|--------|-------------|
| `cluster-example` | coredns + valkey (sentinel) + cert-manager with cluster labels |
| `cluster-full` | All features enabled (HPA, PDB, ServiceAccount, metrics, NetworkPolicy) |
| `cluster-minimal` | coredns only, all defaults |

## Checks

`nix flake check` runs:

- **Schema validation** -- every package variant and cluster validated against Kubernetes API schemas via kubeconform (offline, sandboxed with vendored schemas)
- **Cluster assertions** -- verify expected resources exist (and unwanted resources are absent) for example, full, and minimal cluster configurations
- **Cross-resource validation** -- pure eval-time referential integrity checks:
  - ServiceAccount references resolve
  - RoleBinding roleRefs point to existing Roles/ClusterRoles
  - ConfigMap volume refs resolve
  - Service selectors match at least one workload's pod template labels
  - HPA scaleTargetRef points to an existing workload
  - No duplicate resource identities (kind/namespace/name)
  - All resources carry `app.kubernetes.io/managed-by=kix`

## Dev shell

```bash
nix develop

# Print the example cluster's resource DAG as a tree
kix-dag

# Print as Graphviz DOT
kix-dag-dot | dot -Tsvg -o dag.svg

# Render DAG directly to SVG
kix-dag-svg /tmp/dag.svg
```
