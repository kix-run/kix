# kixpkgs: Nix-Inspired Kubernetes Resource Management — Simplified Overview

## Read This First

This is the condensed version of the full design doc (`02_kixpkgs-design-doc.md`). Same technical depth, less repetition. Read the full doc for complete code listings, extended examples, and the appendices with full `k8s/lib.nix` source.

---

## 1. The Problem

Helm and Kustomize give you no dependency graph, no reference integrity, and no composability. Rename a ConfigMap and the Deployment breaks at runtime. Forget a ClusterRoleBinding and the Pod can't do anything. Two charts both need cert-manager CRDs — no way to express that.

**kixpkgs** applies Nix's core ideas (derivations, fixpoints, string contexts, overlays, modules) to Kubernetes resource management.

---

## 2. Core Mapping: Nix → Kubernetes

| Nix | K8s Equivalent |
|---|---|
| derivation | resource (Deployment, ConfigMap...) |
| `outPath` | `metadata.name` + namespace |
| string context / `inputDrvs` | refs to other resources' names (auto-tracked) |
| multi-output (`.lib`, `.dev`) | resource outputs (port, claimName, clusterIP) |
| `propagatedBuildInputs` | `requires` (transitive inverted deps) |
| `overrideAttrs` | `overrideParts` |
| overlay | cluster overlay |
| `lib.fix` | self-referential package definitions (inner + outer) |
| `callPackage` | scope injection (namespace, labels, instance name) |
| `stdenv` | namespace |
| NixOS module | cross-cutting module (monitoring, network policy) |

---

## 3. Refs and Automatic Dependency Tracking

Since we can't patch the Nix runtime, we use tagged attrsets instead of string contexts.

**Refs** — a value that remembers which resource produced it:

```nix
mkRef = resource: output: value: {
  _type = "k8s-ref";
  inherit resource output value;
  __toString = self: toString self.value;
};
```

A resource exposes refs as its public interface:

```nix
self = {
  ref = mkRef self "ref" name;            # primary identity
  out = {
    port = mkRef self "port" 80;          # named outputs
    claimName = mkRef self "claimName" name;
  };
};
```

**Tracked strings** — preserve deps through interpolation (native `${}` calls `__toString` and loses tracking):

```nix
# Instead of: "postgresql://${db.out.host}:${toString db.out.port}/mydb"
# Write:
k8s.str [ "postgresql://" db.out.host ":" db.out.port "/mydb" ]
```

**Tree walker** — recurses into attrsets and lists, finds all `_type = "k8s-ref"` tags, collects source resources. `mkResource` calls this on spec/data/annotations and gets deps for free — no manual dependency declaration.

**Closure** — follows both `deps` (from refs, automatic) and `requires` (manual, for inverted relationships) transitively. `resource.closure` gives you every resource needed.

---

## 4. The Three Kinds of Dependencies

This is the most important concept.

### `deps` — Automatic, from refs

"I reference this resource by name in my spec."

Deployment → ConfigMap (via `configMapRef.name`), Ingress → Service (via `backend.service.name`). **Inferred automatically** by the tree walker whenever you use `.ref` or `.out`.

### `requires` — Manual, inverted refs

"I need this to function, but *it* references *me*, not the other way around."

```
         YAML ref direction          Semantic dep direction
Binding ──ref──→ SA                  SA ──requires──→ Binding    (INVERTED)
PDB     ──label→ Deploy pods         Deploy ──requires──→ PDB   (INVERTED)
```

Common cases: ServiceAccount → its RoleBindings, Deployment → its PDB/HPA, Custom Resource → its CRD + controller.

`requires` flows **transitively**. Pull on a Deployment → get its ServiceAccount → get the ClusterRoleBinding.

### `extraDeps` — Ordering only

"Deploy this before me, but don't include it in my closure." Rarely needed.

---

## 5. Packages: The Inner Fixpoint

A package is a self-referential set of resources wrapped in `lib.fix`. The inner fixpoint lets any resource within a package reference any other.

```nix
# kixpkgs/coredns.nix
{ scope, config }:

in self: {
  configmap = scope.mkResource {
    apiVersion = "v1"; kind = "ConfigMap";
    name = "coredns";
    data.Corefile = self.corefile;
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1"; kind = "ServiceAccount";
    name = "coredns";
    requires = [ self.clusterRoleBinding ];     # inverted dep
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "system:coredns";
    spec.roleRef.name = self.clusterRole.ref;          # auto-tracked
    spec.subjects = [{
      name = self.serviceAccount.ref;                  # auto-tracked
      namespace = self.serviceAccount.namespace;
    }];
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = "coredns";
    requires = [ self.pdb ];
    spec.template.spec = {
      serviceAccountName = self.serviceAccount.ref;
      volumes = [{ configMap.name = self.configmap.ref; }];
    };
  };

  # The public interface — what other packages get.
  main = self.service // { requires = [ self.workload ]; };
}
```

**`main`** is the resource other packages interact with. For CoreDNS it's the Service. `main` carries `requires` that pull in everything behind it. `coredns.closure` includes Deployment, RBAC, ConfigMap, PDB — everything.

**`overrideParts`** lets you swap one resource while inheriting the rest:

```nix
myCoredns = coredns.overrideParts (self: super: {
  workload = scope.mkResource { /* StatefulSet instead of Deployment */ };
  # RBAC, ConfigMap, PDB carry over automatically
});
```

---

## 6. The Outer Fixpoint: Cluster Composition

The outer fixpoint handles packages within a cluster — like `nixpkgs` itself.

```nix
basePackages = self: {
  coredns = instantiate ./packages/coredns.nix { };
  myApp = instantiate ./packages/my-app.nix {
    database = self.postgres;     # cross-package dependency
  };
  postgres = instantiate ./packages/postgresql.nix { };
};
```

**Overlays** compose left-to-right, identical to nixpkgs:

```nix
myCluster = mkCluster {
  overlays = [
    (self: super: {
      coredns = super.coredns.overrideParts (cSelf: cSuper: {
        workload = /* StatefulSet version */;
      });
    })
  ];
};
```

Inner fixpoint = parts within a package. Outer fixpoint = packages within a cluster. `overrideParts` swaps one node in the inner; overlays swap one package in the outer. Refs re-resolve automatically in both cases.

---

## 7. Namespaces as First-Class Resources

Namespaces are resources, not strings. This gives us:

- **Auto-dependency**: `namespace = ns` (resource, not string) → auto-dep on the Namespace
- **Policy bundling**: Namespace `requires` its ResourceQuota, LimitRange, NetworkPolicies
- **Cluster-scoped sentinel**: `namespace = clusterScoped` for ClusterRoles, PVs, etc.
- **Cross-namespace refs**: `dbService.fqdn` → `"postgres.data.svc.cluster.local"` with auto-tracked dep

**Scope** pre-binds the namespace so packages never handle it directly:

```nix
mkScope = instanceName: namespaceName:
  let ns = namespaceResources.${namespaceName};
  in {
    inherit instanceName;
    mkResource = args: k8s.mkResource (args // { namespace = ns; });
    mkClusterResource = args: k8s.mkResource (args // { namespace = clusterScoped; });
    str = k8s.str;
  };
```

---

## 8. The End-User DSL

The user writes declarative config. The system wires everything.

```nix
# clusters/production.nix
{
  cluster.labels = { "team" = "platform"; };

  namespaces.production = {
    resourceQuota.hard = { "requests.cpu" = "20"; };
  };
  namespaces.data = {};

  services.postgres = {
    enable = true;
    namespace = "data";
    storage = "100Gi";
  };

  services.prod-app = {
    enable = true;
    namespace = "production";
    replicas = 5;
    image = "myapp:v2.1.0";
    database = config.instances.postgres;
  };

  monitoring.enabled = true;
}
```

**`buildCluster` evaluates this** by: building namespace resources → building scopes → evaluating instances → applying cross-cutting modules → merging module outputs back → exposing closures and manifests.

```bash
nix eval .#cluster.manifests | kubectl apply -f -           # deploy everything
nix eval .#cluster.deploy.prod-app.manifests | kubectl apply -f -  # just one app + deps
nix eval .#cluster.dag.closureOf "prod-app"                 # what does it need?
```

---

## 9. Cross-Cutting Concerns: Modules and Builders

Three pieces, no coupling:

| Package | Module | Builder |
|---|---|---|
| "I have metrics on port 9153" → | "Find all instances with monitoring capabilities" → | "Produce a ServiceMonitor resource" |

**Packages** declare **capabilities** (plain data, no imports):

```nix
capabilities.monitoring = {
  endpoints = [{ port = "metrics"; interval = "15s"; }];
  serviceLabels = self.labels;
  metricsService = self.metricsService;
};
```

**Modules** iterate instances, read capabilities, call **builders**:

```nix
apply = { instances, clusterConfig }:
  lib.mapAttrs (name: instance:
    let cap = instance.capabilities.monitoring or null;
    in if cap == null then {} else {
      serviceMonitor = builders.mkServiceMonitor { /* from cap */ };
      attachTo = cap.metricsService;
    }
  ) instances;
```

The evaluator merges module outputs back via `requires`. The ServiceMonitor ends up in the closure without the package knowing it exists.

**Adding a new concern** (e.g., NetworkPolicies): write a builder, have packages declare a capability, write a module. No changes to existing packages or modules.

---

## 10. CRDs and Type Providers

CRDs are special: a CR doesn't reference its CRD by name, and needs both the CRD (for the API server) and the controller (for reconciliation).

**Type providers** bundle CRD + controller + constructor:

```nix
mkTypeProvider = { crd, controller }:
  {
    mk = { name, namespace, spec, ... }@args:
      k8s.mkResource ({
        apiVersion = crd.apiVersion;
        kind = crd.kind;
        requires = (args.requires or []) ++ [ crd controller ];
      } // args);
  };
```

A CRD-providing package (e.g., cert-manager) exposes type providers. Consumers use them:

```nix
certificate = cm.types.certificate.mk {
  name = "my-tls";
  namespace = scope.namespace;
  spec.secretName = "my-tls";
  spec.issuerRef.name = self.issuer.ref;   # auto-tracked
};
```

This automatically ensures: CRDs before controller, controller before CRs. Two packages sharing the same cert-manager instance get the same type providers — closure deduplication handles the rest.

---

## 11. What This Gets You Over Helm

| Concern | Helm | kixpkgs |
|---|---|---|
| Dependencies | None | Full DAG: auto + manual + transitive |
| Reference integrity | Strings, runtime errors | Refs, eval-time checks |
| Composability | Subcharts + values.yaml | Fixpoints + `overrideParts` |
| Cross-chart deps | Manual wiring | Auto-tracked via outer fixpoint |
| Deploy ordering | Dump everything at once | Topo-sorted closure |
| CRD handling | Separate step, hope for the best | Type providers, automatic ordering |
| Cross-cutting | Hardcoded per chart | Modules + capabilities + builders |

---

## Where to Go Next

- Full design doc with complete code listings: `02_kixpkgs-design-doc.md`
- Appendix A in the full doc: complete `k8s/lib.nix` implementation
- Appendix B: summary table of all abstractions
- Section 14: open questions (validation, diffing, secret management, schema validation)
