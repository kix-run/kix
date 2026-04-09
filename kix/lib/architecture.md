# Kixpkgs lib/ Architecture Overview

## Executive Summary

The kixpkgs `lib/` directory implements a **declarative Kubernetes manifest generator** built on Nix. At its core:

1. **Cluster definitions** (module system) declare desired state: instances, namespaces, flavors, and policies.
2. **Evaluation engine** (eval/) performs dependency injection, fixpoint resolution, and resource closure computation.
3. **Resource constructors** (k8s.nix, helm.nix, compose.nix) build K8s manifests with **automatic dependency tracking via Nix store-path context**.
4. **Cross-cutting concerns** (netpol.nix, rbac.nix, scorecard.nix) derive network policies, RBAC rules, and policy violations from the resource graph.

The architecture balances **declarative, type-safe configuration** with **automatic wiring**—cluster operators specify what they want, and the system derives the rest.

---

## Entry Point Flow: mkFlake → Cluster → Manifests

### 1. **mkFlake.nix** — Flake Boilerplate

**Purpose:** Orchestrate the complete build pipeline from cluster definitions to rendered manifests, checks, and CLI metadata.

**Public surface:**
- `mkFlake { inputs, clusters?, systems? }` → flake outputs with `.packages`, `.checks`, `.legacyPackages`

**Dependencies:**
- Imports `./lib` (kix library)
- Calls `buildCluster` on each cluster definition
- Runs schema/validation checks via `kixChecks` and `piChecks`

**How it's consumed:**
- Projects define a `flake.nix` that calls `mkFlake` with their cluster defs
- Clusters can be paths (auto-imported), functions (auto-DI), or attrsets

### 2. **buildCluster** (eval/cluster.nix) — The Evaluation Fixpoint

**Purpose:** Transform a cluster definition (modules, instances, namespaces) into a complete resource graph with manifests, activation CR, and metadata.

**Flow:**
1. **Module composition** (lib.evalModules): Merges cluster modules; produces merged config
2. **Auto-instantiation**: Discovers implicit deps and activates optional instances
3. **Namespace creation**: Stamps namespace resources with labels/annotations
4. **Dependency resolution index**: Maps instance names/aliases to namespaces for DNS-like lookup
5. **Phase-1 pre-pass**: Introspects packages to discover deps and config injections (without fixpoint)
6. **Instance evaluation loop** (nested fixpoint): For each instance, resolves DI, calls build, collects resources
7. **Manifest aggregation**: Gathers all resources, stamps dependency annotations, builds store DAG
8. **Scorecard/netpol post-processing**: Derives policies and rule violations

**Key outputs:**
- `cluster.rawManifests` — flat list of all K8s resources (with store-path dependency annotations)
- `cluster.activation` — Activation CRD that roots the store DAG (for `nix-store --tree` traversal)
- `cluster.packageIndex` — JSON registry of all instances and versions
- `cluster.scorecardReport` — structured policy findings (optional)

### 3. **env.nix** — Environment Stamping (Optional)

**Purpose:** Multi-environment deployments—stamp instances into env-prefixed namespaces with config overrides.

**Public surface:**
- `mkEnv envName { config, overrides } instanceSets` → stamped instances (dev-app, dev-data, etc.)

**Used when:** Cluster operators want the same package stack deployed to dev/staging/prod with different configs.

---

## The Module System (modules.nix)

Kixpkgs uses **NixOS-style modules** for cluster composition. This enables:
- **Composition**: Multiple teams contribute fragments that merge safely
- **Overridability**: Modules use `mkDefault` / `mkForce` for priority control
- **Lazy evaluation**: All config remains unevaluated until needed (critical for DI)

**Key options:**

| Option | Type | Purpose |
|--------|------|---------|
| `clusterLabels` | attrs | Labels injected into every resource |
| `instances` | nested attrs | Per-namespace instance declarations |
| `availablePackages` | attrs | Package registry for auto-instantiation |
| `namespaces` | attrs | Per-namespace labels, annotations, quotas, network policies |
| `cluster.provider` | str | Distribution name (k3s, eks, etc.) for flavor dispatch |
| `cluster.capabilities` | attrs | Hardware facts: `multiNode`, `loadBalancer`, `managedControlPlane`, etc. |
| `cluster.network` | attrs | Pod/Service CIDRs, upstream DNS |
| `globalPartsOverlays` | list | Functions applied to all instance outputs (post-build) |
| `scorecard` | attrs | Rule definitions, overrides, defaults |
| `networkPolicy` | attrs | Enable/disable CiliumNetworkPolicy generation |

**Instance structure:**
```nix
instances.namespace.instanceName = {
  package = packages.foo;          # Function, inline attrset, or kix.mkImport
  config = { ... };                # Package options (merged, lazy)
  aliases = [ "alias1" ];          # DI resolution keys
  deps = { key = value; };         # Explicit DI overrides
  optional = false;                # Dormant until required
  labelStyle = "kix" | "helm";     # Label convention
  selectorLabels = null;           # Override auto-derived selector
  partsOverlays = [ ... ];         # Per-instance post-build overlays
};
```

---

## Dependency Injection & Resolution (eval/resolve.nix)

**Design:** DNS-like lookup with **namespace-scoped resolution** and explicit overrides.

### Resolution Index

Built once per cluster from static metadata (no fixpoint).

```nix
resolutionIndex.byKey.mypackage = [
  { namespace = "ns1"; instanceName = "pkg1"; meta = {...}; }
  { namespace = "ns2"; instanceName = "pkg2"; meta = {...}; }
]
```

### resolveArg Decision Tree

For each function arg (e.g., `{ vault, ... }`):
1. **Explicit override wins** (instCfg.deps.vault)
2. **Same namespace?** One match → use it; multiple → error
3. **Other namespaces?** Prefer managed instances over imports
4. **Has default?** If yes, leave unbound (package defines it); if no → error

### Two-Phase Package Calling

**Phase 1** (pre-pass, pre-fixpoint):
- Introspect package function signature
- Discover DI deps
- Resolve targets via DNS (no `ref` yet)
- Build config injections (e.g., prometheus.out.mkServiceMonitor)

**Phase 2** (inside fixpoint):
- Bind all deps to actual instances from `ref` (the fixpoint)
- Evaluate config (deferredModule → merged attrset)
- Call build function
- Collect resources and outputs

---

## Instance Evaluation (eval/instance.nix)

**Transforms one package into resources.**

### Flow

1. **Normalize package**: Function vs inline attrset shape detection
2. **Scope creation**: Per-instance context with labels, selectors, cluster info
3. **Discover DI deps**: Read function args, enrich from metadata
4. **Resolve deps**: DNS lookup + explicit overrides
5. **Evaluate config**: Deep-merge package defaults + module config
6. **Call build function**: `build({ self, config, scope, kix, deps... })`
7. **Collect resources**: Walk `self` attrset recursively, extract k8s-resources
8. **Compute closure**: Follow store-path context to find transitive deps
9. **Generate network policies** (netpol.processInstance): Egress from workloads, warn on hostNetwork
10. **Evaluate scorecard rules**: Package meta constraints, package-level findings
11. **Build PackageInstance CR**: Metadata root for this package's DAG subgraph
12. **Create activation deps**: Link PackageInstance to its resources via `requires`

### "self" Convention

Packages define resources in `self` (analogous to a set of parts):
```nix
build = { scope, kix, ... }: {
  root = scope.mkResource { ... };
  service = self.root |> kix.service.fromWorkload { ... } |> scope.mkResource;
  ingress = self.service |> kix.ingress.fromService { ... } |> scope.mkResource;
};
```

The CLI and evaluator use predictable names (`root`, `service`, `ingress`) to wire cross-package references.

---

## Resource Constructors (k8s.nix)

### mkResource — Content-Addressed Store Path

**Purpose:** Build a K8s manifest with **automatic dependency tracking via Nix string context**.

**Key features:**
- **Real names in manifests**, not store paths (K8s uses string names)
- **Dependency annotation**: Parses manifest JSON context, stamps `metadata.annotations."kix.dev/depends-on"` with tagged hashes
- **Auto-derived outputs**: `name`, `fqdn`, `selector`, `identityHash`
- **User outputs**: Override/extend auto-derived via `outputs = { customField = value; }`
- **Namespace handling**: Detects `clusterScoped`, namespace resources, or string keys

**Core output fields** (all carry store-path context for automatic DAG edges):
```nix
out = {
  name = "service-name";                         # String, context-attached
  fqdn = "svc.namespace.svc.cluster.local";     # For DNS
  selector = { "app.kubernetes.io/name" = "..."; }; # For Service selectors
  identityHash = "abc123...";                    # Canonical hash of this resource
  # User-defined outputs...
};
```

### mkImportResource — Lightweight Reference

For `kix.mkImport` (platform-provided services): derives `out` without store paths.

### mkPackageInstance & mkActivation — CRD Roots

- **PackageInstance**: Per-package root resource with annotations for root, inverse-deps, requires, post-hooks
- **Activation**: Cluster-level root; references all PackageInstances via string context (captures transitive closure)

The CLI reads the Activation CR's store path to compute the full DAG for deploy ordering.

### Secret Helpers (mkSecretHelpers)

Shared builders for secret references with **cross-namespace validation**:
- `keyRef("password")` → `{ valueFrom.secretKeyRef = { name, key }; }`
- `mkEnv { PASS = "password"; }` → list of env entries
- `envFrom` → `{ secretRef = { name }; }`
- `volume("mount-name")` → volume definition with _kix.namespace marker

---

## Resource Composition Helpers (compose.nix / "kixlib")

Pure helpers passed to packages as the `kix` argument.

### Service/Ingress builders

```nix
kix.service.fromWorkload { name, type = "ClusterIP", ports? } workload
  → spec with auto-derived selector + ports

kix.ingress.fromService { name, host, port?, className? } service
  → Ingress spec with auto-derived backend

kix.httpRoute.fromService { ... parentRef } service
  → Gateway API HTTPRoute
```

### Mount helpers

```nix
kix.mount.pvc(pvc) { mountPath = "/data"; }
kix.mount.configMap(cm) { mountPath = "/etc/config"; items = [...]; }
kix.mount.secret(secret) { mountPath = "/keys"; }
kix.mount.emptyDir { mountPath, name }

kix.withMounts([ m1, m2, m3 ]) deployment  # Single container
kix.withMountsOn("container-name")([ ... ]) deployment  # Named container
```

### expose & monitor Build Entries

Smart build functions that wire infrastructure deps:

```nix
build = [
  ({ self, scope, kix, gateway, ingressNginx, clusterIssuer, ... }: { ... })
  (kix.expose { service = "service"; })  # Auto-picks Gateway or Ingress
  (kix.monitor { service = "service"; port = "metrics"; })  # Auto-picks prometheus
];
```

These declare their DI deps via function args; the eval system auto-discovers them.

---

## Helm Integration (helm.nix)

**Purpose:** Import Helm charts as kix packages via IFD.

### Entry point: fromHelmChart

```nix
fromHelmChart {
  chart = fetchHelmChart { repo = "..."; name = "postgresql"; ... };
  values = { persistence.enabled = true; };
  releaseName = "postgres";
  rootSelector = { kind = "Service"; };  # Which resource is the root
}
```

### Processing pipeline

1. **IFD**: Run `helm template` on the chart
2. **Parse JSON**: Import rendered manifests
3. **Unwrap Lists**: Flatten `kind:List` documents
4. **Filter nulls**: Remove empty/test-hook resources
5. **Strip Helm metadata**: Remove Helm annotations/labels that interfere with kix
6. **Wrap resources**: Convert each JSON resource to k8s-resource via `wrapHelmResource`
7. **Select root**: Prefer Service > Deployment > StatefulSet > first
8. **Wire deps**: Non-root resources become `requires` of root

**Key cleanups:**
- Removes `helm.sh/`, `meta.helm.sh/`, `checksum/` annotations
- Strips `helm.sh/chart`, `app.kubernetes.io/managed-by` labels
- Removes default `strategy` fields (K8s doesn't persist them)

---

## CRD System (crd.nix & scope.mkCRD)

**Purpose:** Declaratively define and instantiate custom resources.

### Builders (pipeable)

```nix
crd.fromKind "MyResource" { spec.group = "example.io"; }
  |> crd.clusterScoped
  |> crd.withShortNames ["myres"]
  |> crd.withSchema { ... openAPIV3Schema ... }
  |> scope.mkCRD
```

### CRD Refs (scope.mkCRDRef)

For operators that manage CRDs:
```nix
crdsResource = scope.mkCRD { ... };
crdRef = scope.mkCRDRef crdsResource;  # Lightweight reference
```

Packages that consume the CRD declare it as a dep, ensuring Nix orders them correctly.

---

## Network Policy Generation (netpol.nix)

**Purpose:** Auto-derive CiliumNetworkPolicies from the store-path dependency graph.

### Per-Instance Egress Policies (evaluateInstance)

For each workload (Deployment, StatefulSet, DaemonSet):
- **DNS egress**: To kube-dns (always allowed)
- **Service egress**: To each Service referenced in store context
- **Self-egress** (StatefulSet): Pod-to-pod within the set (replication, discovery)
- **API server egress**: If instance has RBAC or CRD resources
- **External egress** (optional): If meta.network.allowExternalEgress is true

### Cluster-Level Ingress Policies (generateIngressPolicies)

After fixpoint, invert egress edges: for each target Service, allow traffic from source workloads.

### Default Deny (generateDefaultDeny)

Per-namespace policy that denies all ingress/egress unless explicitly allowed.

**Config:**
```nix
networkPolicy = {
  enable = true;
  defaultDeny = true;
  directions = "both";  # "ingress", "egress", or "both"
  ciliumInstance = cilium;  # Optional reference for dep ordering
};
```

---

## RBAC DSL (rbac.nix)

**Purpose:** Pipe-friendly RBAC rule builders for ClusterRole/Role resources.

### Ref constructors

```nix
rbac.core = group "" ["configmaps" "secrets" "pods" ...];
rbac.core.configmaps  # → { apiGroup = ""; resource = "configmaps"; }
rbac.group "apps" ["deployments", "statefulsets"]
```

### Intents (Ref → [Rule])

```nix
rbac.core.pods |> rbac.watch        # get, list, watch
rbac.core.secrets |> rbac.reconcile # get, list, watch, patch, update (+ status)
rbac.core.secrets |> rbac.allow ["read"]
```

### Modifiers

```nix
rbac.core.pods |> rbac.restrictTo ["my-pod"]  # Scope to specific resourceNames
rbac.core.endpoints |> rbac.sub "status"      # Access sub-resources
```

---

## Policy Rules Engine (scorecard.nix)

**Purpose:** Declare and evaluate multi-level resource policy rules with configurable severity.

### Evaluation Levels

1. **Manifest**: Individual resource (pod must have resource limits)
2. **Package**: All resources from one instance
3. **Namespace**: All instances in a namespace
4. **Cluster**: Across all namespaces

### Severity Override Chain

For each rule at each level:
1. Per-rule disable (byRule.X.enabled = false)
2. Per-owner override (byOwner."pattern")
3. Per-namespace override (byNamespace."pattern")
4. Rule's own severity
5. Cluster ruleDefaults.severity

### Built-in Rule Library (rules/)

- `rules.security.*` — Pod security, image policy, RBAC, secrets
- `rules.reliability.*` — Resource limits, liveness probes, PDB, anti-affinity
- `rules.governance.*` — Labeling, ownership, documentation

---

## Flavors (flavors/)

**Purpose:** Platform profiles that set cluster capabilities and provide platform-owned imports.

**Example: k3s.nix**
- Sets `cluster.provider = "k3s"`
- Declares capabilities: loadBalancer (servicelb), CNI (flannel), ingressController (traefik)
- Provides platform imports: `platform-dns` (coredns), `platform-storage` (local-path)
- These imports use `kix.mkImport` so explicit packages can shadow them

**All flavors:**
- k3s, kind, kubeadm (self-hosted)
- eks, gke, gke-autopilot, aks (managed)
- openshift, rke2, talos (specialized)

Cluster definitions import a flavor via modules: `modules = [ kix.flavors.k3s ... ]`

---

## Modules (modules/)

**Purpose:** Reusable cluster-level building blocks.

**Example: modules/monitoring.nix**
- Declares `monitoring.enabled`, `monitoring.namespace`, per-component options
- Auto-instantiates prometheus-operator, prometheus, alertmanager, node-exporter, grafana
- Wires them together with ServiceMonitor/PrometheusRule references

Usage:
```nix
modules = [ kix.modules.monitoring { monitoring.enabled = true; } ];
```

---

## Helpers & Utilities (eval/)

### eval/helpers.nix
- `mergeCollide`: Merge with collision detection (for safe composition)
- `collectTypedAttrs`: Recursively gather typed objects (k8s-resources, etc.) from nested attrsets
- `knownFolders`: Warnings for content-type mismatches

### eval/scope.nix
- `mkScope`: Constructs the per-instance context object
- Workload builders: mkDeployment, mkStatefulSet, mkDaemonSet (implicit label/selector injection)
- Capability checks: validateLoadBalancer, validateDaemonSets, validatePrivilege, etc.
- Cross-namespace validation: checkNamespacedRefs (for mounts, secrets, CRDs)

### eval/view.nix
- `mkPackageView`: Strips internal metadata, re-exports public outputs for cli/registry

### eval/namespace.nix
- `mkNamespace`: Creates Namespace resource with optional labels, annotations, ResourceQuota, NetworkPolicies

### eval/import.nix
- `mkImport`: Creates lightweight references for platform-provided services
- `evaluateImportInstance`: Builds minimal PackageInstance CRs for imports (no resource collection)

### eval/auto.nix
- `computeAutoInstances`: Discovers missing deps, activates optionals, builds auto-instances

---

## Default.nix — Top-Level Exports

**Re-exports all major components:**

| Export | Source | Purpose |
|--------|--------|---------|
| Resource constructors | k8s.nix | mkResource, mkPackageInstance, mkActivation, kixCRDs, attachCtxDeep, extractStoreHash, nsOf, resourceId |
| Evaluation | eval.nix | buildCluster, mkScope, mkNamespace, evaluateInstance, resolveArg, callPackagePhase1, etc. |
| Environments | env.nix | mkEnv |
| Composition | compose.nix | kixlib (service, ingress, httpRoute, mount, expose, monitor builders) |
| Metadata | meta.nix | peekPackageMeta |
| RBAC | rbac.nix | group, watch, reconcile, allow, restrictTo, sub |
| Scorecard | scorecard.nix | rule engine + severity resolution |
| Helm | helm.nix | fetchHelmChart, helmTemplateDerivation, fromHelmChart, wrapHelmResource |
| Flavors | flavors/ | k3s, kind, kubeadm, eks, gke, gke-autopilot, aks, openshift, rke2, talos |
| Modules | modules/ | monitoring |
| CRD tools | crd.nix | fromKind, clusterScoped, withShortNames, withSchema, etc. |
| Utilities | mkManifest, mkManifests | YAML file derivation + directory assembly |

---

## Integration: How External Code Uses lib/

### Cluster Definitions (clusters/*.nix)

```nix
{ kix, packages }:
kix.buildCluster {
  name = "my-cluster";
  modules = [
    kix.flavors.k3s
    {
      clusterLabels = { team = "platform"; };
      instances.kube-system.coredns = {
        package = packages.coredns;
        config = { replicaCount = 3; };
      };
    }
  ];
}
```

### Packages (kix/packages/*/default.nix)

```nix
{ scope, lib, kix, configProvider, ... }:
{
  options.replicas = lib.mkOption { type = lib.types.int; default = 1; };
  build = { self, config, scope, kix, ... }: {
    deployment = scope.mkDeployment { ... };
    service = self.deployment |> kix.service.fromWorkload { ... } |> scope.mkResource;
  };
}
```

### mkFlake — Flake Integration

```nix
# flake.nix
outputs = inputs: inputs.kix.lib.mkFlake {
  inherit inputs;
  clusters = {
    prod = ./clusters/prod.nix;
  };
};
```

---

## Data Flow Diagram

```
┌─────────────────────────────────────┐
│  Cluster Definition (.nix)          │
│  modules: [flavor, module, {...}]   │
└──────────────┬──────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  lib.evalModules (mkFlake)           │
│  Merges all modules → config         │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  buildCluster (eval/cluster.nix)    │
│  • Auto-instantiation               │
│  • Namespace creation               │
│  • Resolution index build           │
│  • Phase-1 pre-pass                 │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  Nested Fixpoint (per-instance)      │
│  evaluateInstance (eval/instance.nix)│
│  • DI resolution (DNS lookup)        │
│  • Build function call              │
│  • Resource collection              │
│  • Closure computation              │
│  • Netpol generation                │
│  • Scorecard evaluation             │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  Manifest Aggregation               │
│  • Stamp dep annotations            │
│  • Build PackageInstance CRs        │
│  • Create Activation root           │
│  • Collect scorecard findings       │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  mkManifests (default.nix)          │
│  YAML serialization + directory     │
└──────────────────────────────────────┘
```

---

## Key Design Patterns

### 1. **Store-Path as DAG Edge**

Resources don't explicitly declare deps. Instead:
- Resource manifests embed store-path context in JSON
- `k8s.mkResource` parses context, stamps `kix.dev/depends-on` annotation
- CLI reads annotations to reconstruct DAG for deploy ordering

### 2. **Lazy Evaluation + Fixpoint**

- Module config remains deferred (not evaluated) until needed
- Instance evaluation runs inside `builtins.fix` — each instance can reference any other via `ref`
- Breaking cycles: imports are optional and don't create hard deps

### 3. **DNS-Like DI Resolution**

Instead of magic global singletons, DI mimics DNS:
- Each instance gets a "name" (DNS label) and optional aliases
- Requester specifies arg name; resolver does namespace-scoped lookup
- Multiple candidates → error (ambiguous) unless same namespace (prefer local)

### 4. **Platform Imports**

Flavors declare imports (coredns, storage provisioner) using `kix.mkImport`:
- Lightweight references without build logic
- Shadowed by explicit packages (if cluster installs its own DNS, flavor's import is ignored)
- Enables optional deps without circular build requirements

### 5. **_type Markers**

Internal convention: any object with `_type` field is a **leaf** (k8s-resource, k8s-import, etc.).
- `collectTypedAttrs` stops descending at _type boundaries
- CLAUDE.md and checkNamespacedRefs validate _type contracts

### 6. **_kix Metadata**

Reserved key for internal markers (stripped before serialization):
- `_kix.namespace`: For cross-namespace validation on secret/mount references
- `_kix.source`: Provenance (secret, configMap, pvc, etc.)
- `_kix.reflected`: Secret mirrored by external controller

---

## Testing & Validation

- **Schema checks** (kixChecks.schemaCheck): Validates K8s manifests against OpenAPI schemas
- **Manifest validation** (kixChecks.validateManifestSet): Cross-resource references, field types
- **PI wiring checks** (piChecks.validatePIWiring): PackageInstance DAG integrity
- **Scorecard evaluation**: Reports findings during build (failures fail the build if severity=error)

---

## Summary Table

| Layer | Module | Purpose | Key Exports |
|-------|--------|---------|------------|
| **Entry** | mkFlake.nix | Flake orchestration | mkFlake → packages, checks, legacyPackages |
| **Evaluation** | eval.nix | DI, fixpoint, instance build | buildCluster, evaluateInstance, resolveArg |
| **Resources** | k8s.nix | Manifest construction | mkResource, mkPackageInstance, mkActivation |
| **Composition** | compose.nix | Pure builders | kixlib (service, ingress, mount, expose, monitor) |
| **Helm Bridge** | helm.nix | Chart imports | fromHelmChart, helmTemplateDerivation |
| **Environment** | env.nix | Multi-env stamping | mkEnv |
| **Policy** | netpol.nix | Network policies | processInstance, generateIngressPolicies |
| **RBAC** | rbac.nix | Role builders | group, watch, reconcile, allow |
| **Scorecard** | scorecard.nix | Policy rules | evaluateRules, resolveEffectiveSeverity |
| **Module Options** | modules.nix | Cluster schema | instances, namespaces, capabilities, scorecard |
| **Platforms** | flavors/*.nix | Distro profiles | k3s, eks, gke, kind, openshift, talos, etc. |
| **Features** | modules/monitoring.nix | Prometheus stack | Auto-instantiates monitoring components |
| **Helpers** | eval/{helpers,scope,view,namespace,import,auto,resolve} | Utilities | Collision merge, resource collection, capability checks |
| **CRDs** | crd.nix | Custom resources | fromKind, clusterScoped, withSchema, withShortNames |

---

This architecture elegantly separates concerns: **cluster operators** define desired state (modules), **packages** implement the logic (build functions), and **the evaluation engine** wires them together with automatic dependency injection, closure computation, and policy derivation.
