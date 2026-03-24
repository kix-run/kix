# 21: First-class CRD support

## Problem

CRDs are created with package-local `mkCrd` helpers (cert-manager, stackgres-operator) that duplicate boilerplate. CR builders like `mkCertificate` are hand-written and manually exposed via `main.out`. ServiceMonitor creation is copy-pasted across 6+ packages with hardcoded `apiVersion = "monitoring.coreos.com/v1"`.

## Design decisions

### Two constructors

- `scope.mkCRD { ... }` — creates CRD resource + auto-attaches CR builders on `.out` (for packages that own their CRDs)
- `scope.mkCRDRef { ... }` — creates import-like ref with store path for dependency tracking + same builders (for Helm-managed or external CRDs)

### Builder surface on `.out`

CRD resources (and refs) auto-expose three builder styles:

```nix
crd.out.cr      # pipe-friendly transformer: stamps apiVersion + kind
crd.out.mkCR    # full builder: takes consumer scope, auto-routes by CRD scope
crd.out.bind    # binder: curries mkCR with scope, returns plain args->resource function
```

All three attach the CRD's string context to `apiVersion`/`kind`, giving automatic dependency tracking in the DAG.

### Scope mismatch validation

When `.cr` stamps `_crScope` onto args:
- `scope.mkResource` + cluster-scoped CR → **throw**
- `scope.mkClusterResource` + namespaced CR → **throw**
- No `_crScope` → backwards compatible (no validation)

### Scope-side method

`scope.mkCR crd args` delegates to `crd.out.mkCR scope args` — analogous to `scope.mkDeployment`.

## Access patterns

```nix
# Package author — creates CRD with auto-attached builders:
serviceMonitorCRD = scope.mkCRD {
  group = "monitoring.coreos.com";
  kind = "ServiceMonitor";
  plural = "servicemonitors";
  singular = "servicemonitor";
  listKind = "ServiceMonitorList";
};

# Consumer accesses via DI — four equivalent styles:

# A: bind once, use as plain builder
mkServiceMonitor = prometheus.serviceMonitorCRD.out.bind scope;
monitor = mkServiceMonitor { name = "my-app"; spec = { ... }; };

# B: scope.mkCR
monitor = scope.mkCR prometheus.serviceMonitorCRD { name = "my-app"; spec = { ... }; };

# C: explicit pipe (throws on scope mismatch)
monitor = { name = "my-app"; spec = { ... }; }
  |> prometheus.serviceMonitorCRD.out.cr
  |> scope.mkResource;

# D: mkCR on CRD's out
monitor = prometheus.serviceMonitorCRD.out.mkCR scope { name = "my-app"; spec = { ... }; };
```

## Implementation

### `mkCRDBuilders` (lib/k8s.nix)

Shared logic: takes CRD string context + metadata, returns `{ cr, mkCR, bind }`.

### `scope.mkCRD` (lib/eval.nix)

Creates CRD resource via `scope.mkClusterResource`, attaches builders from `mkCRDBuilders` onto `.out`.

### `scope.mkCRDRef` (lib/eval.nix)

Creates a `builtins.toFile` store path (non-deployable, marked `_type = "crd-ref"`). Filtered out by the existing `_type == "k8s-resource"` check in `collectResources`. Attaches same builders.

### toFile name fix (lib/k8s.nix)

`builtins.toFile` names can't carry string context references. The `kind` and `name` args (which may carry CRD context from `.cr`) are stripped of context when building the toFile name. Context is preserved in `manifestJson` (the content) for dependency tracking.

## Helm CRDs

For CRDs managed by Helm charts (e.g. kube-prometheus-stack's ServiceMonitor CRD), use `mkCRDRef`:

```nix
serviceMonitorCRD = scope.mkCRDRef {
  group = "monitoring.coreos.com";
  kind = "ServiceMonitor";
  plural = "servicemonitors";
  requires = [ self.helmRelease ];  # depend on the Helm deployment
};
```

The ref has a store path for context tracking but produces no manifest. CRs created via `.cr` depend on the ref, which depends on the actual CRD owner.

## Instance-level wrappers

The auto-generated builders are generic (just apiVersion/kind). Packages can wrap them with instance-specific logic:

```nix
# cluster-issuers wraps the generic Certificate builder:
mkCertificate = { name, hosts, secretName, ... }:
  mkCert {
    inherit name;
    spec = {
      inherit secretName;
      issuerRef = { name = mainResource.out.name; kind = "ClusterIssuer"; };
      dnsNames = if builtins.isList hosts then hosts else [ hosts ];
    };
  };
```

## DI limitation: hyphenated instance names

Nix identifiers can't contain hyphens. Instance names like `cert-manager` can't be used as DI parameter names directly. Workaround: use `aliases` in cluster config, explicit `deps` overrides, or `mkCRDRef` within the consuming package.

## Open questions

- Should `mkCRD` auto-derive `listKind` from `kind` + "List"? Currently required.
- Should `mkCRDRef` auto-derive `plural` from lowercase `kind` + "s"? Currently traces a warning and defaults.
- Graph visualization: how should CRD refs appear in the dependency graph? They're non-deployable but carry dependency semantics.
- Should there be a mechanism to "upgrade" a `mkCRDRef` to a full `mkCRD` when migrating from Helm to native kix packages?
