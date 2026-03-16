# kixpkgs: Nix-Inspired Kubernetes Resource Management

## Design Document — March 2026

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Background: How Nix Solves Dependency Management](#2-background-how-nix-solves-dependency-management)
3. [Conceptual Mapping: Nix → Kubernetes](#3-conceptual-mapping-nix--kubernetes)
4. [Core Library: Refs, Tree Walking, and Automatic Dependency Tracking](#4-core-library-refs-tree-walking-and-automatic-dependency-tracking)
5. [The Three Kinds of Dependencies](#5-the-three-kinds-of-dependencies)
6. [Packages: The Inner Fixpoint](#6-packages-the-inner-fixpoint)
7. [The Outer Fixpoint: Cluster Composition and Overlays](#7-the-outer-fixpoint-cluster-composition-and-overlays)
8. [Namespaces as First-Class Resources](#8-namespaces-as-first-class-resources)
9. [The End-User DSL: Declarative Cluster Configuration](#9-the-end-user-dsl-declarative-cluster-configuration)
10. [Cross-Cutting Concerns: Modules and Builders](#10-cross-cutting-concerns-modules-and-builders)
11. [CRDs and Type Providers](#11-crds-and-type-providers)
12. [Full Example: A Complete Cluster](#12-full-example-a-complete-cluster)
13. [Comparison to Existing Tools](#13-comparison-to-existing-tools)
14. [Open Questions and Future Work](#14-open-questions-and-future-work)

---

## 1. Motivation

Helm templates are string soup. Kustomize is patching YAML with more YAML. Neither gives you a real dependency graph, composable packages, or the ability to swap one resource while keeping everything else consistent.

Consider what goes wrong today:

- A Deployment references a ConfigMap by name. Rename the ConfigMap and the Deployment breaks at runtime — nothing catches this at authoring time.
- A ServiceAccount is useless without its ClusterRoleBinding, but nothing in Helm connects them. Forget the binding and the Pod can't do anything.
- Two Helm charts both need cert-manager CRDs. There's no way to express "this chart requires that chart's types" beyond documentation.
- You want to deploy just one app, but you don't know what else it needs. Helm has no concept of transitive dependencies.
- You run the same app in staging and production. In Helm, that's two values files and prayer.

Nix solved all of these problems for software builds decades ago. This document describes **kixpkgs** — a system that applies the same ideas (derivations, fixpoints, string contexts, overlays, and a module system) to Kubernetes resource management.

---

## 2. Background: How Nix Solves Dependency Management

This section covers the Nix primitives that kixpkgs is modeled on. If the team is already comfortable with Nix internals, skip to Section 3.

### 2.1 Derivations Are Just Data

When you call `mkDerivation` in Nix, nothing gets built. Nix produces an attribute set with an `outPath` — a store path computed by hashing the derivation's description (name, system, builder, and the outPaths of all input derivations). This happens purely during evaluation, before any building occurs.

A derivation serialized as a `.drv` file looks roughly like this (JSON representation):

```json
{
  "/nix/store/abc123-hello-2.12.1.drv": {
    "outputs": {
      "out": { "path": "/nix/store/xyz789-hello-2.12.1" }
    },
    "inputDrvs": {
      "/nix/store/...-bash-5.2.drv": { "outputs": ["out"] },
      "/nix/store/...-stdenv-linux.drv": { "outputs": ["out"] },
      "/nix/store/...-openssl-3.0.drv": { "outputs": ["out", "dev"] }
    },
    "inputSrcs": [
      "/nix/store/...-default-builder.sh"
    ],
    "builder": "/nix/store/...-bash-5.2/bin/bash",
    "args": ["-e", "/nix/store/...-default-builder.sh"],
    "env": {
      "buildInputs": "/nix/store/...-openssl-3.0",
      "name": "hello-2.12.1",
      "out": "/nix/store/xyz789-hello-2.12.1",
      "src": "/nix/store/...-hello-2.12.1.tar.gz",
      "system": "x86_64-linux"
    },
    "system": "x86_64-linux"
  }
}
```

Key fields: `outputs` declares what this derivation produces (most packages just have `"out"`, but multi-output derivations have `"out"`, `"dev"`, `"lib"`, etc.). `inputDrvs` is the dependency graph — each key is a `.drv` store path for a dependency, and the value says which outputs are needed. `env` contains every attribute that becomes an environment variable in the build sandbox.

The store paths form a Merkle DAG: change any leaf derivation and all hashes above it change. Evaluation computes this DAG. Building just realizes the contents at those paths.

### 2.2 String Context Tracks Dependencies Automatically

When you write `"${openssl}/lib"` in a build script, two things happen simultaneously:

1. The literal store path gets substituted into the string.
2. Nix records `openssl` as a dependency in the string's invisible *context* metadata.

This context propagates through all string operations — concatenation, interpolation, regex replacement. When the enclosing derivation is constructed, Nix walks all attribute values, collects every string context, and populates the `inputDrvs` field of the `.drv` file.

You never list dependencies manually. They're inferred from usage.

### 2.3 Multi-Output Derivations

Some packages produce multiple outputs. OpenSSL, for example, has `out` (binaries), `dev` (headers), and `lib` (shared libraries). You select a specific output with `pkgs.openssl.lib`. This changes which output appears in `inputDrvs`:

```json
"/nix/store/...-openssl-3.0.drv": { "outputs": ["lib"] }
```

Bare `pkgs.openssl` is shorthand for `pkgs.openssl.out` — the default output.

### 2.4 The Package Set Is a Fixpoint

`nixpkgs` is defined as:

```nix
lib.fix (self: {
  openssl = mkDerivation { ... };
  curl = mkDerivation { buildInputs = [ self.openssl ]; ... };
  # ... thousands more
})
```

The `self` argument lets any package reference any other package, and lazy evaluation means Nix only computes what's actually needed. Overlays work by composing functions over this fixpoint:

```nix
# An overlay that replaces openssl
self: super: {
  openssl = super.openssl.overrideAttrs { patches = [ ./my-patch.diff ]; };
}
```

Everything that depends on openssl (like curl) automatically picks up the patched version through `self`.

### 2.5 `propagatedBuildInputs`

Regular `buildInputs` are only available during the build. `propagatedBuildInputs` flow transitively: if package A has `propagatedBuildInputs = [ B ]`, then anything that depends on A also gets B in its build environment. This models the case where "using A requires also having B available."

### 2.6 Overrides Are Surgical

`pkgs.openssl.override { ... }` changes the inputs to openssl while keeping its structure. `overrideAttrs` lets you change individual attributes (phases, patches, flags) without rewriting the whole derivation. The fixpoint re-resolves, so everything that depends on openssl gets the new version automatically.

---

## 3. Conceptual Mapping: Nix → Kubernetes

| Nix Concept | K8s Equivalent | Notes |
|---|---|---|
| derivation | resource (Deployment, ConfigMap...) | The fundamental unit |
| `outPath` | `metadata.name` (+ namespace) | The identity other things reference |
| string context / `inputDrvs` | refs to other resources' names | Auto-tracked by tree walker |
| multi-output (`.lib`, `.dev`) | resource outputs (port, claimName, clusterIP) | Named interfaces for dependents |
| `propagatedBuildInputs` | `requires` | Transitive deps for inverted relationships |
| `overrideAttrs` | `overrideParts` | Swap one resource, keep the rest |
| overlay | cluster overlay | Swap one package in the cluster |
| `lib.fix` | self-referential package definitions | Both inner and outer fixpoints |
| `callPackage` | scope injection | Namespace, labels, instance name |
| fixed-output derivation | external/pre-existing resources | Known identity, not managed by us |
| `stdenv` | namespace | The environment resources live in |
| NixOS module | cross-cutting module | Monitoring, network policy, etc. |

---

## 4. Core Library: Refs, Tree Walking, and Automatic Dependency Tracking

This section describes `k8s/lib.nix` — the foundation everything else is built on.

### 4.1 Refs: The Context Carrier

In Nix, `"${openssl}/lib"` carries invisible metadata about which derivation produced the string. We can't modify the Nix runtime, so we use tagged attrsets instead.

A `Ref` is a value that remembers which resource produced it:

```nix
mkRef = resource: output: value: {
  _type = "k8s-ref";
  inherit resource output value;
  # Degrades to plain string in ${} interpolation (loses tracking)
  __toString = self: toString self.value;
};

isRef = v: builtins.isAttrs v && (v._type or "") == "k8s-ref";
```

A resource exposes refs:

```nix
self = {
  ref = mkRef self "ref" name;                   # primary identity ("outPath")
  out = {
    port = mkRef self "port" 80;                 # like .lib, .dev
    claimName = mkRef self "claimName" name;
  };
};
```

When you write `configmap.ref` in another resource's spec, the tree walker sees the `_type = "k8s-ref"` tag and records the dependency.

### 4.2 Tracked Strings: Interpolation Without Losing Context

Native Nix `${}` interpolation calls `__toString`, which returns a plain string — our tracking metadata is lost. The `str` combinator preserves it:

```nix
# Instead of: "postgresql://${db.out.host}:${toString db.out.port}/mydb"
# Write:      k8s.str [ "postgresql://" db.out.host ":" db.out.port "/mydb" ]

str = parts: { _type = "k8s-tracked-str"; inherit parts; };
```

Slightly less ergonomic than `${}`, but dependencies are tracked correctly through string construction. This is our equivalent of Nix's string context propagation through concatenation.

Supporting this natively would mean patching the nix runtime.

### 4.3 The Tree Walker: Automatic Dependency Collection

This is the equivalent of what `builtins.derivation` does internally: walk all attribute values, find everything tagged as a ref, collect the source resources.

```nix
resolve = val:
  if isRef val then {
    resolved = val.value;
    deps = [ val.resource ];
  }
  else if isTrackedStr val then
    let
      resolvePart = p:
        if isRef p then { s = toString p.value; deps = [ p.resource ]; }
        else { s = toString p; deps = []; };
      parts = map resolvePart val.parts;
    in {
      resolved = lib.concatStrings (map (p: p.s) parts);
      deps = lib.concatMap (p: p.deps) parts;
    }
  else if builtins.isList val then
    let rs = map resolve val; in {
      resolved = map (r: r.resolved) rs;
      deps = lib.concatMap (r: r.deps) rs;
    }
  else if builtins.isAttrs val then
    let rs = lib.mapAttrs (_: resolve) val; in {
      resolved = lib.mapAttrs (_: r: r.resolved) rs;
      deps = lib.concatMap (k: rs.${k}.deps) (builtins.attrNames rs);
    }
  else { resolved = val; deps = []; };
```

The walker recurses into attrsets and lists, resolves refs to their plain values (for the final manifest), and accumulates the source resources (for the dependency list). `mkResource` calls this on spec/data/annotations and gets deps for free — no manual dependency declaration.

### 4.4 Closure Computation

The closure follows **both** `deps` (from refs, automatic) and `requires` (manual, for inverted relationships) transitively:

```nix
computeClosure = root:
  let
    go = { seen, order, queue }:
      if queue == [] then order
      else
        let
          head = builtins.head queue;
          rest = builtins.tail queue;
          id = "${head.kind}/${head.name}@${head.namespace}";
        in
        if builtins.hasAttr id seen then
          go { inherit seen order; queue = rest; }
        else
          go {
            seen = seen // { ${id} = true; };
            order = order ++ [ head ];
            queue = rest ++ head.deps ++ head.requires;
          };
  in go { seen = {}; order = []; queue = [ root ]; };
```

`resource.closure` gives you every resource transitively needed — the full set of things that must exist for this resource to function.

### 4.5 `mkResource`: The Full Constructor

```nix
mkResource = {
  apiVersion,
  kind,
  name,
  namespace ? "default",     # can be: string | namespace resource | clusterScoped
  labels ? {},
  annotations ? {},
  spec ? {},
  data ? {},
  stringData ? {},
  outputs ? {},
  requires ? [],             # inverted deps (things I need that reference me)
  extraDeps ? [],            # ordering-only deps
}:
  let
    # Resolve namespace (details in Section 8)
    nsInfo = resolveNamespace namespace;

    resolvedSpec = resolve spec;
    resolvedData = resolve data;
    resolvedStringData = resolve stringData;
    resolvedAnnotations = resolve annotations;

    inferredDeps = lib.unique (
      resolvedSpec.deps
      ++ resolvedData.deps
      ++ resolvedStringData.deps
      ++ resolvedAnnotations.deps
      ++ nsInfo.nsDep
      ++ extraDeps
    );

    self = {
      _type = "k8s-resource";
      inherit apiVersion kind name;
      inherit requires;
      namespace = nsInfo.nsString;

      ref = mkRef self "ref" name;
      out = lib.mapAttrs (k: v: mkRef self k v) outputs;
      fqdn = mkRef self "fqdn"
        (if nsInfo.nsString != null
         then "${name}.${nsInfo.nsString}.svc.cluster.local"
         else name);

      deps = inferredDeps;
      closure = computeClosure self;

      manifest = { /* rendered K8s object with resolved values */ };
    };
  in self;
```

---

## 5. The Three Kinds of Dependencies

This is the most important section of the document. K8s resources have three distinct dependency relationships, and conflating them breaks the DAG.

### 5.1 `deps` — Automatic, from refs

"I reference this resource by name in my spec."

Examples: Deployment → ConfigMap (via `configMapRef.name`), Deployment → ServiceAccount (via `serviceAccountName`), Ingress → Service (via `backend.service.name`).

These are **inferred automatically** by the tree walker. You never write them by hand. Every time you write `configmap.ref` or `service.out.port` in a resource's spec, the walker discovers the dependency.

### 5.2 `requires` — Manual, inverted refs

"I need this to function, but *it* references *me*, not the other way around."

This is the tricky one. In K8s YAML, a ClusterRoleBinding points to a ServiceAccount. But semantically, the ServiceAccount is useless without its binding. The YAML ref direction is inverted relative to the semantic dependency.

```
             YAML ref direction        Semantic dep direction
             (what K8s sees)           (what our DAG models)

Binding ──ref──→ Role                  Binding ──ref──→ Role       (same)
Binding ──ref──→ SA                    SA ──requires──→ Binding    (INVERTED)
Deploy  ──ref──→ SA                    Deploy ──ref──→ SA          (same)
PDB     ──label→ Deploy pods           Deploy ──requires──→ PDB   (INVERTED)
```

Common inverted relationships:

- ServiceAccount → its RoleBinding(s) / ClusterRoleBinding(s)
- Deployment/StatefulSet → its PodDisruptionBudget
- Deployment → its HorizontalPodAutoscaler
- Custom Resource → its CRD (the CR doesn't reference the CRD by name)
- Custom Resource → its controller Deployment

`requires` flows **transitively**. If you pull on a Deployment that refs a ServiceAccount, and that ServiceAccount requires a ClusterRoleBinding, the binding comes along. This is what makes "pull on one resource, get everything it needs" work.

Rule of thumb: if A refs B in the YAML, the dep is `A → B` (automatic). If A needs B but B refs A in the YAML, then `A.requires = [ B ]` (manual).

### 5.3 `extraDeps` — Ordering only

"Deploy this before me, but don't include it in my closure."

Rarely needed. For cases like "the migration Job must complete before the Deployment rolls out" where there's no ref and no requires relationship.

---

## 6. Packages: The Inner Fixpoint

A "K8s package" is a self-referential set of resources, analogous to a Nix derivation with overridable phases. The inner fixpoint (`lib.fix`) lets any resource within a package reference any other resource in the same package.

### 6.1 Package Structure

```nix
# kixpkgs/coredns.nix
{ scope, config }:

let
  cfg = {
    replicas = config.replicaCount or 2;
    image = config.image or "registry.k8s.io/coredns/coredns:v1.11.1";
  };

in self: {
  # "self" is the fixpoint — every part sees the final value
  # of every other part.

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "coredns";
    data.Corefile = self.corefile;
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "coredns";
    requires = [ self.clusterRoleBinding ];   # inverted dep
  };

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "system:coredns";
    spec = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = self.clusterRole.ref;               # auto-tracked
      };
      subjects = [{
        kind = "ServiceAccount";
        name = self.serviceAccount.ref;            # auto-tracked
        namespace = self.serviceAccount.namespace;
      }];
    };
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "coredns";
    requires = [ self.pdb ];
    spec = {
      replicas = cfg.replicas;
      selector.matchLabels = self.labels;
      template = {
        metadata.labels = self.labels;
        spec = {
          serviceAccountName = self.serviceAccount.ref;
          containers = [{
            name = "coredns";
            image = cfg.image;
            volumeMounts = [{
              name = "config";
              mountPath = "/etc/coredns";
              readOnly = true;
            }];
          }];
          volumes = [{
            name = "config";
            configMap.name = self.configmap.ref;
          }];
        };
      };
    };
  };

  service = scope.mkResource { /* ... */ };
  pdb = scope.mkResource { /* ... */ };

  labels = {
    "app.kubernetes.io/name" = "coredns";
    "app.kubernetes.io/instance" = scope.instanceName;
  };

  # The "outPath" — what other packages get when they reference this one.
  main = self.service // {
    requires = [ self.workload ];
  };
}
```

### 6.2 The `main` Resource

Every package must declare a `main` resource. This is the resource other packages interact with — the public interface. Everything else is implementation detail.

For CoreDNS, `main` is the Service (consumers connect to `kube-dns:53`). For cert-manager, it might be the ClusterIssuer constructor. For a database, it's the Service with host/port outputs.

`main` carries `requires` that pull in the workload and everything behind it. When another package references `coredns.ref`, it gets the Service's name — but `coredns.closure` includes the Deployment, RBAC, ConfigMap, and everything else.

### 6.3 Tracing a Closure

Starting from CoreDNS's `main`:

```
main (Service/kube-dns)
│
├─ dep → Namespace/kube-system                ← namespace is a dep
│
└─ requires → workload (Deployment/coredns)
    │
    ├─ ref → ServiceAccount/coredns
    │   └─ requires → ClusterRoleBinding/system:coredns
    │       ├─ ref → ClusterRole/system:coredns     (leaf)
    │       └─ ref → ServiceAccount                 (already seen)
    │
    ├─ ref → ConfigMap/coredns                      (leaf)
    │
    └─ requires → PDB/coredns                       (leaf)

Result: [ Service, Namespace, Deployment, SA, ConfigMap,
          PDB, ClusterRoleBinding, ClusterRole ]
```

### 6.4 Overriding Parts

`overrideParts` lets you swap one resource while inheriting everything else:

```nix
myCoredns = coredns.overrideParts (self: super: {
  # Swap Deployment → StatefulSet. Everything else inherited from super.
  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "coredns";
    requires = [ self.pdb ];              # same PDB
    spec = {
      serviceName = self.service.ref;     # NEW ref — tracked automatically
      # ...
      serviceAccountName = self.serviceAccount.ref;  # same SA
      configMap.name = self.configmap.ref;            # same configmap
    };
  };
});
```

The RBAC chain, ConfigMap, and PDB carry over automatically. The Service appears in the workload's new `deps` because StatefulSets reference their governing service via `serviceName`. The DAG reflects reality.

---

## 7. The Outer Fixpoint: Cluster Composition and Overlays

The inner fixpoint handles parts within a package. The outer fixpoint handles packages within a cluster — like `nixpkgs` itself.

### 7.1 Package Set

```nix
basePackages = self: {
  coredns = instantiate ./packages/coredns.nix { /* ... */ };
  certManager = instantiate ./packages/cert-manager.nix { /* ... */ };
  myApp = instantiate ./packages/my-app.nix {
    coredns = self.coredns;        # cross-package dependency
    database = self.postgres;
  };
  postgres = instantiate ./packages/postgresql.nix { /* ... */ };
};
```

### 7.2 Overlays

Overlays compose left-to-right, identical to nixpkgs:

```nix
mkCluster = { overlays ? [] }:
  let
    applied = lib.foldl'
      (prev: overlay: self:
        let super = prev self;
        in super // (overlay self super))
      basePackages
      overlays;
  in lib.fix applied;
```

Usage:

```nix
myCluster = mkCluster {
  overlays = [
    # Swap coredns to StatefulSet
    (self: super: {
      coredns = super.coredns.overrideParts (cSelf: cSuper: {
        workload = /* StatefulSet version */;
      });
    })

    # Staging overrides
    (self: super: {
      myApp = super.myApp.override { namespace = "staging"; replicas = 1; };
    })
  ];
};
```

### 7.3 How the Two Fixpoints Interact

```
┌──────────────────────────────────────────────────────────────┐
│  OUTER FIXPOINT (cluster / package set)                      │
│                                                              │
│  coredns ──────────────────┐                                 │
│  │  ┌────────────────────┐ │                                 │
│  │  │ INNER FIXPOINT     │ │                                 │
│  │  │                    │ │                                 │
│  │  │ configmap ◄──┐     │ │                                 │
│  │  │ sa ◄─────────┤     │ │                                 │
│  │  │   └requires→ │     │ │                                 │
│  │  │     binding──┤     │ │                                 │
│  │  │       └ref→ role   │ │                                 │
│  │  │ pdb ◄────────┤     │ │   cross-package ref             │
│  │  │ workload ────┘     │ │ ◄───────────────────── myApp    │
│  │  │ service ───────────┼─┘                                 │
│  │  │ main = service     │                                   │
│  │  └────────────────────┘                                   │
│  │                                                           │
│  │  overrideParts swaps ONE node in the inner fixpoint;      │
│  │  refs and requires re-resolve automatically.              │
│  │                                                           │
│  │  overlays swap ONE package in the outer fixpoint;         │
│  │  cross-package refs re-resolve automatically.             │
└──────────────────────────────────────────────────────────────┘
```

---

## 8. Namespaces as First-Class Resources

### 8.1 The Problem

With namespaces as plain strings, four things break:

1. The Namespace resource must exist before anything is created in it, but nothing tracks that.
2. Namespaces carry policy resources (ResourceQuota, LimitRange, NetworkPolicy) that need to be deployed alongside them — another inverted relationship.
3. Cross-namespace references (app in `production` talking to DB in `data`) are invisible strings.
4. Cluster-scoped resources (ClusterRole, PersistentVolume, Namespace itself) don't live in any namespace.

### 8.2 Namespace as Resource

```nix
mkNamespace = {
  name,
  labels ? {},
  resourceQuota ? null,
  limitRange ? null,
  networkPolicies ? [],
}:
  let
    nsResource = mkResource {
      apiVersion = "v1";
      kind = "Namespace";
      name = name;
      namespace = clusterScoped;
      inherit labels;
    };

    quota = /* ResourceQuota resource if configured */;
    lr = /* LimitRange resource if configured */;
    netpols = /* NetworkPolicy resources if configured */;

    policyResources = /* collect all non-null policies */;

  in nsResource // {
    requires = policyResources;   # namespace requires its policies
  };
```

### 8.3 Automatic Namespace Dependencies

When `namespace` is a resource (not a string), `mkResource` automatically adds it to `deps`:

```nix
deployment = mkResource {
  apiVersion = "apps/v1";
  kind = "Deployment";
  name = "myapp";
  namespace = ns;           # resource, not string → auto-dep
  # ...
};
```

The closure now includes the Namespace and its policies. Deploy order is correct by construction.

### 8.4 Cluster-Scoped Resources

```nix
clusterScoped = { _type = "k8s-cluster-scope"; };

clusterRole = mkResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRole";
  name = "system:coredns";
  namespace = clusterScoped;     # no namespace in manifest, no namespace dep
};
```

### 8.5 Cross-Namespace References via `fqdn`

Every resource gets an `fqdn` output that includes its namespace:

```nix
fqdn = mkRef self "fqdn"
  "${name}.${namespace}.svc.cluster.local";
```

Cross-namespace usage:

```nix
env = [{
  name = "DATABASE_URL";
  value = scope.str [
    "postgresql://" dbService.fqdn ":" dbService.out.port "/mydb"
  ];
  # dbService.fqdn = "postgres.data.svc.cluster.local"
  # This auto-tracks the dep on dbService, which pulls in Namespace/data
}];
```

### 8.6 Namespace as Environment

The `scope` injected into packages pre-binds the namespace:

```nix
mkScope = instanceName: namespaceName:
  let ns = namespaceResources.${namespaceName};
  in {
    inherit instanceName;
    namespace = ns;
    mkResource = args: k8s.mkResource (args // { namespace = ns; });
    mkClusterResource = args: k8s.mkResource (args // { namespace = clusterScoped; });
    str = k8s.str;
  };
```

Packages never handle namespaces directly. They use `scope.mkResource` and get the right namespace and cluster labels automatically.

---

## 9. The End-User DSL: Declarative Cluster Configuration

### 9.1 Design Goal

The user experience should be closer to NixOS modules than nixpkgs `callPackage`. You write a declaration of what you want, the system wires everything. No manual `callPackage`, no namespace resource construction, no string-based cross-references.

### 9.2 The Interface

```nix
# clusters/my-cluster.nix
{
  cluster.labels = {
    "app.kubernetes.io/part-of" = "my-platform";
    "team" = "platform";
  };

  namespaces.production = {
    resourceQuota.hard = {
      "requests.cpu" = "20";
      "limits.memory" = "64Gi";
    };
    networkPolicies = [{ /* ... */ }];
  };

  namespaces.staging = {};
  namespaces.data = {};

  services.coredns = {
    enable = true;
    namespace = "kube-system";
    replicaCount = 2;
    prometheus.service.enabled = true;
    prometheus.monitor.enabled = true;
  };

  services.postgres = {
    enable = true;
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  services.my-app = {
    enable = true;
    namespace = "production";
    replicas = 5;
    image = "myapp:v2.1.0";
    database = config.instances.postgres;
    dns = config.instances.coredns;
  };

  services.staging-app = {
    package = "my-app";                        # same package, different instance
    namespace = "staging";
    replicas = 1;
    image = "myapp:staging-latest";
    database = config.instances.postgres;      # same DB
    dns = config.instances.coredns;
  };

  monitoring = {
    enabled = true;
    defaultInterval = "15s";
  };
}
```

### 9.3 What `buildCluster` Does

The evaluator performs these steps:

1. **Build namespace resources.** Every namespace referenced by a service gets a Namespace resource with its configured policies.
2. **Build scopes.** Each instance gets a scope with its namespace, instance name, and pre-bound resource constructors.
3. **Evaluate instances.** Each service entry is resolved to a kixpkg, instantiated through its package function with scope and config, and wrapped in the fixpoint.
4. **Apply cross-cutting modules.** Modules (monitoring, network isolation, etc.) iterate over all instances, read capabilities, and produce resources using builders.
5. **Merge module outputs.** Module-produced resources are attached back to instances via `requires`.
6. **Expose outputs.** Per-instance closures, full cluster closure, manifests, DAG queries.

### 9.4 What Packages Look Like

Packages are dumb. They produce resources and declare capabilities as plain data. They don't know about monitoring, network policies, or any cross-cutting concern. They don't know what namespace they're in.

```nix
# kixpkgs/my-app.nix
{ scope, config }:

let
  db = config.database;     # another instance — has .ref, .out, .fqdn
  dns = config.dns;

in self: {
  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = scope.instanceName;
    spec = {
      template.spec.containers = [{
        name = "app";
        image = config.image;
        env = [{
          name = "DATABASE_URL";
          value = scope.str [
            "postgresql://" db.fqdn ":" db.out.port "/mydb"
          ];
        }];
      }];
    };
  };

  service = scope.mkResource { /* ... */ };

  capabilities = {
    monitoring = {
      endpoints = [{ port = "metrics"; interval = "15s"; }];
      serviceLabels = self.labels;
    };
  };

  main = self.service // { requires = [ self.deployment ]; };
}
```

### 9.5 Day-to-Day Usage

```bash
# Deploy everything
nix eval .#cluster.manifests | kubectl apply -f -

# Deploy just one instance (with all its transitive deps)
nix eval .#cluster.deploy.my-app.manifests | kubectl apply -f -

# What does my-app need?
nix eval .#cluster.dag.closureOf "my-app"
# → Namespace/production (+ policies), Namespace/data (+ policies),
#   all of postgres, all of coredns, all of my-app

# What would be affected if I change postgres?
nix eval .#cluster.dag.dependentsOf "postgres"
# → { my-app = ...; staging-app = ...; }
```

---

## 10. Cross-Cutting Concerns: Modules and Builders

### 10.1 The Pattern

Packages expose **capabilities** (plain data describing what they offer). Modules **consume** capabilities and produce resources using **builders**. Three concerns, three pieces of code, no coupling.

```
Package                         Module                        Builder
───────                         ──────                        ───────
"I have metrics on port 9153"   "Find all instances with      "Given a selector and
                           →     monitoring capabilities" →    endpoints, produce a
                                                               ServiceMonitor resource"
```

### 10.2 Builders

Reusable resource constructors. Not packages — just functions that take structured data and return resources.

```nix
# kixlib/builders.nix
{ k8s, lib }:

rec {
  mkServiceMonitor = {
    name,
    namespace,
    selector,
    endpoints ? [{ port = "metrics"; interval = "15s"; }],
    labels ? {},
  }: k8s.mkResource {
    apiVersion = "monitoring.coreos.com/v1";
    kind = "ServiceMonitor";
    inherit name namespace;
    labels = labels // { "managed-by" = "kixlib"; };
    spec = {
      inherit endpoints;
      selector.matchLabels = selector;
    };
  };

  mkPDB = { name, namespace, selector, maxUnavailable ? 1 }:
    k8s.mkResource {
      apiVersion = "policy/v1";
      kind = "PodDisruptionBudget";
      inherit name namespace;
      spec = {
        inherit maxUnavailable;
        selector.matchLabels = selector;
      };
    };

  mkDenyAllIngress = { name, namespace }:
    k8s.mkResource {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      inherit name namespace;
      spec = {
        podSelector = {};
        policyTypes = [ "Ingress" ];
        ingress = [];
      };
    };

  # ... more builders as needed
}
```

### 10.3 Package Capabilities

Packages declare what they offer as plain data. They don't import builders, don't know about ServiceMonitors, don't produce monitoring resources:

```nix
# Inside a package definition
capabilities = {
  monitoring = {
    endpoints = [{
      port = "metrics";
      interval = "15s";
      path = "/metrics";
    }];
    serviceLabels = self.labels;
    metricsService = self.metricsService;
  };

  network = {
    allowFromNamespaces = [ "production" "staging" ];
  };
};
```

### 10.4 Modules

Modules iterate over all instances, read capabilities, and produce resources:

```nix
# kixlib/modules/monitoring.nix
{ k8s, lib, builders }:

{
  apply = { config, instances, clusterConfig }:
    let
      monCfg = clusterConfig.monitoring or {};
      enabled = monCfg.enabled or false;
      defaultInterval = monCfg.defaultInterval or "15s";
    in if !enabled then {} else

    lib.mapAttrs (instanceName: instance:
      let
        svcCfg = clusterConfig.services.${instanceName} or {};
        monitorRequested =
          (svcCfg.prometheus.monitor.enabled or false)
          || (svcCfg.metrics.serviceMonitor.enabled or false);
        cap = instance.capabilities.monitoring or null;
      in if !monitorRequested || cap == null then {}
      else {
        serviceMonitor = builders.mkServiceMonitor {
          name = "${instanceName}-monitor";
          namespace = instance._meta.namespace;
          selector = cap.serviceLabels;
          endpoints = map (ep: ep // {
            interval = ep.interval or defaultInterval;
          }) cap.endpoints;
          labels = clusterConfig.cluster.labels or {};
        };
        attachTo = cap.metricsService;
      }
    ) instances;
}
```

The evaluator merges module outputs back into instances by adding produced resources to the `attachTo` target's `requires` list. The ServiceMonitor ends up in the instance's closure without the package knowing it exists.

### 10.5 Adding a New Cross-Cutting Concern

To add automatic NetworkPolicies:

1. Write a builder: `builders.mkDenyAllIngress`, `builders.mkAllowFrom`.
2. Packages declare `capabilities.network = { allowFromNamespaces = [ ... ]; }`.
3. Write a module that reads the capability and produces NetworkPolicy resources.
4. User enables it: `networkIsolation.enabled = true;`.

No changes to existing packages. No changes to existing modules. The concerns are orthogonal.

### 10.6 Flow for a Single Instance

Using CoreDNS as an example:

```
 ┌───────────────────────────────────────────────────────────────┐
 │  1. USER DECLARES                                             │
 │     services.coredns = { replicaCount=2; prometheus...=true } │
 │                                                               │
 │  2. PACKAGE EVALUATES                                         │
 │     Produces: ConfigMap, SA, ClusterRole, CRB, Deployment,    │
 │               Service, MetricsService                         │
 │     Exposes:  capabilities.monitoring = { endpoints, labels } │
 │                                                               │
 │  3. MONITORING MODULE RUNS                                    │
 │     Sees capabilities.monitoring on coredns                   │
 │     Calls builders.mkServiceMonitor                           │
 │     Returns { serviceMonitor = <resource>;                    │
 │               attachTo = metricsService }                     │
 │                                                               │
 │  4. EVALUATOR MERGES BACK                                     │
 │     metricsService.requires += [ serviceMonitor ]             │
 │                                                               │
 │  5. FINAL CLOSURE                                             │
 │     Namespace/kube-system                                     │
 │     ClusterRole, ClusterRoleBinding (cluster-scoped)          │
 │     ServiceAccount, ConfigMap, PDB                            │
 │     Deployment/coredns                                        │
 │     Service/kube-dns                                          │
 │     Service/coredns-metrics                                   │
 │     ServiceMonitor/coredns-monitor      ← from module         │
 └───────────────────────────────────────────────────────────────┘
```

---

## 11. CRDs and Type Providers

### 11.1 What Makes CRDs Special

CRDs introduce three unique problems:

**Invisible dependency.** A `Certificate` CR doesn't reference the `certificates.cert-manager.io` CRD by name anywhere in its spec. It uses `apiVersion: cert-manager.io/v1` and `kind: Certificate`. The tree walker can't find this — it's structural.

**Two-phase dependency.** A CR needs (1) the CRD to exist (the API server rejects unknown types) and (2) the controller Deployment to be running (otherwise the CR sits unreconciled). Neither appears in the CR's spec.

**Platform vs consumer.** cert-manager the *package* installs CRDs + controller. Your *app* creates Certificate CRs. The dependency crosses package boundaries differently from "my app talks to postgres" — it's "my app uses a type that cert-manager defines."

### 11.2 The Model: Type Providers

A package that installs CRDs exposes **type providers** — objects that bundle the CRD resource, the controller, and a constructor function. The consumer uses the constructor and gets the full dependency chain wired automatically.

```nix
# kixlib/crd.nix

mkCRD = { name, group, kind, versions, scope ? "Namespaced", spec ? {} }:
  k8s.mkResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = name;
    namespace = k8s.clusterScoped;
    inherit spec;
  } // { inherit group kind versions; apiVersion = "${group}/${head versions}"; };

mkTypeProvider = { crd, controller }:
  {
    inherit crd controller;

    # The constructor. Creates a CR that automatically depends on
    # the CRD and requires the controller.
    mk = { name, namespace, spec, ... }@args:
      k8s.mkResource ({
        apiVersion = crd.apiVersion;
        kind = crd.kind;
        inherit name namespace spec;
        requires = (args.requires or []) ++ [ crd controller ];
      } // builtins.removeAttrs args [ "requires" ]);
  };
```

### 11.3 cert-manager Package

```nix
# kixpkgs/cert-manager.nix
{ scope, config }:

in self: {
  # CRDs as resources
  crds = {
    certificate = crdLib.mkCRD {
      name = "certificates.cert-manager.io";
      group = "cert-manager.io";
      kind = "Certificate";
      versions = [ "v1" ];
    };
    issuer = crdLib.mkCRD { /* ... */ };
    clusterIssuer = crdLib.mkCRD { /* ... */ };
  };

  # Controller: Deployment + RBAC
  controller = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-controller";
    # ...
  };

  # Type providers — the public interface for consumers
  types = {
    certificate = crdLib.mkTypeProvider {
      crd = self.crds.certificate;
      controller = self.controller;
    };
    issuer = crdLib.mkTypeProvider {
      crd = self.crds.issuer;
      controller = self.controller;
    };
    clusterIssuer = crdLib.mkTypeProvider {
      crd = self.crds.clusterIssuer;
      controller = self.controller;
    };
  };

  # Main requires all CRDs
  main = self.controller // {
    requires = builtins.attrValues self.crds;
  };
}
```

### 11.4 Consuming Type Providers

The consuming package receives the cert-manager instance and uses its type constructors:

```nix
# kixpkgs/my-app.nix
{ scope, config }:

let cm = config.certManager;

in self: {
  # The type provider .mk function creates a CR that automatically
  # requires the CRD and controller. No manual wiring.
  issuer = cm.types.clusterIssuer.mk {
    name = "${scope.instanceName}-letsencrypt";
    namespace = k8s.clusterScoped;
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory";
        privateKeySecretRef.name = "${scope.instanceName}-acme-key";
        solvers = [{ http01.ingress.class = "nginx"; }];
      };
    };
  };

  certificate = cm.types.certificate.mk {
    name = "${scope.instanceName}-tls";
    namespace = scope.namespace;
    spec = {
      secretName = "${scope.instanceName}-tls";
      issuerRef = {
        name = self.issuer.ref;        # ref tracked automatically
        kind = "ClusterIssuer";
      };
      dnsNames = config.domains or [ "app.example.com" ];
    };
  };

  # ... rest of app ...
}
```

### 11.5 Resulting Closure and Deploy Order

```
my-app.closure deploy order:

 1. Namespace/cert-manager                          ← cert-manager's NS
 2. Namespace/production                            ← app's NS
 3. CRD/certificates.cert-manager.io                ← CRDs first
 4. CRD/clusterissuers.cert-manager.io
 5. ClusterRole/cert-manager-controller
 6. ClusterRoleBinding/cert-manager-controller
 7. ServiceAccount/cert-manager
 8. Deployment/cert-manager-controller              ← controller after CRDs
 9. ClusterIssuer/my-app-letsencrypt                ← CRs after controller
10. Certificate/my-app-tls
11. ConfigMap/my-app-config
12. Deployment/my-app
13. Service/my-app
14. Ingress/my-app
```

CRDs before controller, controller before CRs, CRs before the things that use them. All derived from the DAG.

### 11.6 The Singleton Property

Two packages both want cert-manager types. There's only one cert-manager instance:

```nix
services.my-app.certManager = config.instances.cert-manager;
services.other-app.certManager = config.instances.cert-manager;
```

Both use the same type providers. Both produce CRs that require the same CRD and controller resources. Closure deduplication handles the rest — CRDs and controller appear once in the final manifests.

---

## 12. Full Example: A Complete Cluster

This puts everything together — the user-facing config, the packages, the modules, the CRDs, and the resulting DAG.

### 12.1 Cluster Configuration

```nix
# clusters/production.nix
{
  cluster.labels = {
    "app.kubernetes.io/part-of" = "my-platform";
    "team" = "platform";
  };

  namespaces = {
    production = {
      resourceQuota.hard = {
        "requests.cpu" = "20";
        "limits.memory" = "64Gi";
      };
      limitRange.limits = [{
        type = "Container";
        default = { cpu = "500m"; memory = "512Mi"; };
        defaultRequest = { cpu = "100m"; memory = "128Mi"; };
      }];
      networkPolicies = [{
        podSelector = {};
        policyTypes = [ "Ingress" ];
        ingress = [{
          from = [{ namespaceSelector.matchLabels."env" = "production"; }];
        }];
      }];
    };
    staging = {};
    data = {
      resourceQuota.hard = {
        "persistentvolumeclaims" = "10";
        "requests.storage" = "500Gi";
      };
    };
    cache = {};
  };

  services.coredns = {
    enable = true;
    namespace = "kube-system";
    replicaCount = 2;
    prometheus.service.enabled = true;
    prometheus.monitor.enabled = true;
  };

  services.cert-manager = {
    enable = true;
    namespace = "cert-manager";
  };

  services.postgres = {
    enable = true;
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  services.valkey = {
    enable = true;
    namespace = "cache";
    sentinel.enabled = true;
    metrics.enabled = true;
    metrics.serviceMonitor.enabled = true;
    auth.existingSecret = "valkey-auth";
  };

  services.prod-app = {
    enable = true;
    package = "my-app";
    namespace = "production";
    replicas = 5;
    image = "myapp:v2.1.0";
    domains = [ "app.example.com" "www.example.com" ];
    database = config.instances.postgres;
    dns = config.instances.coredns;
    certManager = config.instances.cert-manager;
  };

  services.staging-app = {
    enable = true;
    package = "my-app";
    namespace = "staging";
    replicas = 1;
    image = "myapp:staging-latest";
    database = config.instances.postgres;
    dns = config.instances.coredns;
    certManager = config.instances.cert-manager;
  };

  monitoring = {
    enabled = true;
    defaultInterval = "15s";
  };
}
```

### 12.2 The Full DAG for `prod-app`

```
prod-app.closure:

  Service/prod-app (ns: production)
  ├─ dep → Namespace/production
  │         ├─ req → ResourceQuota/production-quota
  │         ├─ req → LimitRange/production-limits
  │         └─ req → NetworkPolicy/production-netpol-0
  │
  ├─ req → Deployment/prod-app (ns: production)
  │         ├─ ref → ConfigMap/prod-app-config
  │         ├─ dep → Service/postgres-postgres (ns: data)   ← cross-ns via fqdn
  │         │         ├─ dep → Namespace/data
  │         │         │         └─ req → ResourceQuota/data-quota
  │         │         └─ req → StatefulSet/postgres-postgres
  │         │                   ├─ ref → SA, Secret, ConfigMap, PVC
  │         │                   └─ ...
  │         └─ dep → Service/coredns (ns: kube-system)      ← cross-ns via fqdn
  │                   ├─ dep → Namespace/kube-system
  │                   └─ req → Deployment/coredns
  │                             ├─ ref → SA → req → CRB → ref → ClusterRole
  │                             ├─ ref → ConfigMap/coredns
  │                             └─ req → PDB/coredns
  │
  ├─ req → Ingress/prod-app
  │         └─ ref → ClusterIssuer/prod-app-letsencrypt
  │                   ├─ req → CRD/clusterissuers.cert-manager.io
  │                   └─ req → Deployment/cert-manager-controller
  │                             ├─ dep → Namespace/cert-manager
  │                             ├─ ref → SA → req → CRB → ref → ClusterRole
  │                             └─ req → CRD/certificates... (+ other CRDs)
  │
  ├─ req → Certificate/prod-app-tls
  │         ├─ ref → ClusterIssuer (seen)
  │         ├─ req → CRD/certificates (seen)
  │         └─ req → Deployment/cert-manager (seen)
  │
  └─ (from monitoring module)
     Service/prod-app-metrics
     └─ req → ServiceMonitor/prod-app-monitor

  Topo-sorted deploy order:
   1. Namespace/kube-system
   2. Namespace/cert-manager
   3. Namespace/data + ResourceQuota/data-quota
   4. Namespace/production + ResourceQuota, LimitRange, NetworkPolicy
   5. CRD/certificates.cert-manager.io
   6. CRD/clusterissuers.cert-manager.io
   7. ClusterRole/cert-manager-controller
   8. ClusterRoleBinding/cert-manager-controller
   9. ClusterRole/system:coredns
  10. ClusterRoleBinding/system:coredns
  11. ServiceAccount/cert-manager (ns: cert-manager)
  12. Deployment/cert-manager-controller
  13. ServiceAccount/coredns (ns: kube-system)
  14. ConfigMap/coredns
  15. PDB/coredns
  16. Deployment/coredns
  17. Service/coredns
  18. ServiceAccount/postgres (ns: data)
  19. Secret/postgres-credentials, ConfigMap/postgres-config, PVC/postgres-data
  20. StatefulSet/postgres-postgres
  21. Service/postgres-postgres
  22. ClusterIssuer/prod-app-letsencrypt
  23. Certificate/prod-app-tls
  24. ConfigMap/prod-app-config (ns: production)
  25. Deployment/prod-app
  26. Service/prod-app
  27. Service/prod-app-metrics
  28. ServiceMonitor/prod-app-monitor
  29. Ingress/prod-app
```

One `nix eval .#cluster.deploy.prod-app.manifests` produces all of this, in the correct order, from a 20-line service declaration.

---

## 13. Comparison to Existing Tools

### Helm

| Concern | Helm | kixpkgs |
|---|---|---|
| Dependency tracking | None. Resources are independent YAML docs. | Full DAG with `deps` (auto) + `requires` (manual) + transitive closure. |
| Reference integrity | Strings. Typo in a ConfigMap name → runtime error. | Refs. `configmap.ref` is type-checked at eval time. |
| Composability | Subcharts with `values.yaml` plumbing. Limited override surface. | Fixpoints + `overrideParts`. Override any resource while keeping the rest. |
| Cross-chart deps | Manual `values.yaml` wiring. No enforcement. | Cross-package refs via the outer fixpoint. Auto-tracked. |
| Deploy ordering | None. Dumps everything at once. | Topological sort on the closure. |
| CRD handling | Install CRDs in a separate step. Hope the order is right. | Type providers. CRD → controller → CR ordering is automatic. |
| Multi-instance | Multiple releases with different values files. | Same package, different instances. Cross-instance refs are tracked. |
| Cross-cutting | Hardcoded into each chart or done externally. | Modules consume capabilities, produce resources via builders. |

### Kustomize

| Concern | Kustomize | kixpkgs |
|---|---|---|
| Customization | Patch YAML with more YAML. Strategic merge patches. | Override individual parts in a fixpoint. Type-safe. |
| Base reuse | Copy base directories. Overlays are file-system-coupled. | Package functions. Compose with Nix. |
| Dependencies | None. Resources are independent files. | Full DAG. |
| Cross-environment | Directory structure per environment. | Same package, different `config` and `namespace`. |

### CDK8s / Pulumi

| Concern | CDK8s/Pulumi | kixpkgs |
|---|---|---|
| Language | TypeScript/Python/Go. General-purpose. | Nix. Purpose-built for this. |
| Dependency tracking | Implicit via construct tree (CDK8s) or resource references (Pulumi). | Explicit DAG with automatic inference. |
| Reproducibility | Depends on package manager state. | Nix guarantees reproducibility. |
| Override model | Inheritance / props. Limited ability to swap internals of a third-party construct. | Fixpoints + overlays. Override anything at any level. |

---

## 14. Open Questions and Future Work

### Validation

The ref system gives us enough information to validate at eval time: every `.ref` and `.out` access must point to a resource that exists. Dangling refs are eval-time errors, not deploy-time surprises. We should build a validation pass that checks this and produces clear error messages.

### Diffing

The big payoff of having a DAG: diff two evaluations (before/after a PR) and get a precise report of which resources changed and which input triggered the change. This is the K8s equivalent of `nix-diff` on two `.drv` files. Implementation: serialize the closure to a stable format and compare.

### Manifest Rendering and YAML Serialization

The current `manifest` output is a Nix attrset. We need a serialization step to produce YAML. This could be `builtins.toJSON` piped through a JSON-to-YAML converter, or a direct Nix-to-YAML function.

### Integration with `kubectl apply`

The closure is topo-sorted. A deploy tool can iterate the closure, apply each resource, wait for readiness (via `kubectl wait`), and proceed — respecting the dependency ordering that Helm ignores.

### Automatic `requires` Detection

The manual `requires` list is small and well-understood (SA→bindings, workload→PDB/HPA). We could potentially infer some of these by convention: "if a ClusterRoleBinding's subjects include a ServiceAccount, automatically add the binding to that SA's requires." This is a validation/linting layer, not a core mechanism change.

### CRD Version Conflict Detection

If two instances somehow introduce conflicting CRD versions, the evaluator should detect and report this at eval time. Currently this would only surface at apply time.

### Secret Management

kixpkgs deliberately does not generate secrets. The model for secrets is: packages reference them by name (via `existingSecret` config options), and the actual secret provisioning is handled externally (SOPS, External Secrets Operator, Vault). A future module could integrate with External Secrets Operator via type providers.

### Schema Validation for Package Config

Package config is currently untyped — just an attrset passed through. We could add NixOS-style option declarations (`lib.mkOption`) to packages for typed config with defaults, documentation, and validation.

---

## Appendix A: Complete `k8s/lib.nix`

```nix
{ lib }:

let k8s = rec {

  # ── Cluster scope sentinel ───────────────────────────────────
  clusterScoped = {
    _type = "k8s-cluster-scope";
    ref = null;
    namespace = null;
  };
  isClusterScoped = v: builtins.isAttrs v && (v._type or "") == "k8s-cluster-scope";

  # ── Refs ─────────────────────────────────────────────────────
  mkRef = resource: output: value: {
    _type = "k8s-ref";
    inherit resource output value;
    __toString = self: toString self.value;
  };
  isRef = v: builtins.isAttrs v && (v._type or "") == "k8s-ref";

  # ── Tracked strings ─────────────────────────────────────────
  str = parts: { _type = "k8s-tracked-str"; inherit parts; };
  isTrackedStr = v: builtins.isAttrs v && (v._type or "") == "k8s-tracked-str";

  # ── Tree walker ──────────────────────────────────────────────
  resolve = val:
    if isRef val then {
      resolved = val.value;
      deps = [ val.resource ];
    }
    else if isTrackedStr val then
      let
        resolvePart = p:
          if isRef p then { s = toString p.value; deps = [ p.resource ]; }
          else { s = toString p; deps = []; };
        parts = map resolvePart val.parts;
      in {
        resolved = lib.concatStrings (map (p: p.s) parts);
        deps = lib.concatMap (p: p.deps) parts;
      }
    else if builtins.isList val then
      let rs = map resolve val; in {
        resolved = map (r: r.resolved) rs;
        deps = lib.concatMap (r: r.deps) rs;
      }
    else if builtins.isAttrs val then
      let rs = lib.mapAttrs (_: resolve) val; in {
        resolved = lib.mapAttrs (_: r: r.resolved) rs;
        deps = lib.concatMap (k: rs.${k}.deps) (builtins.attrNames rs);
      }
    else { resolved = val; deps = []; };

  # ── Namespace resolution ─────────────────────────────────────
  resolveNamespace = namespace:
    if isClusterScoped namespace then {
      nsString = null;
      nsDep = [];
    }
    else if builtins.isAttrs namespace
         && (namespace._type or "") == "k8s-resource" then {
      nsString = namespace.name;
      nsDep = [ namespace ];
    }
    else {
      nsString = namespace;
      nsDep = [];
    };

  # ── Closure computation ──────────────────────────────────────
  computeClosure = root:
    let
      go = { seen, order, queue }:
        if queue == [] then order
        else
          let
            head = builtins.head queue;
            rest = builtins.tail queue;
            id = "${head.kind}/${head.name}@${toString (head.namespace or "cluster")}";
          in
          if builtins.hasAttr id seen then
            go { inherit seen order; queue = rest; }
          else
            go {
              seen = seen // { ${id} = true; };
              order = order ++ [ head ];
              queue = rest ++ head.deps ++ head.requires;
            };
    in go { seen = {}; order = []; queue = [ root ]; };

  # Multi-root closure
  computeClosure' = roots:
    let
      go = { seen, order, queue }:
        if queue == [] then order
        else
          let
            head = builtins.head queue;
            rest = builtins.tail queue;
            id = "${head.kind}/${head.name}@${toString (head.namespace or "cluster")}";
          in
          if builtins.hasAttr id seen then
            go { inherit seen order; queue = rest; }
          else
            go {
              seen = seen // { ${id} = true; };
              order = order ++ [ head ];
              queue = rest ++ head.deps ++ head.requires;
            };
    in go { seen = {}; order = []; queue = roots; };

  # ── Resource constructor ─────────────────────────────────────
  mkResource = {
    apiVersion,
    kind,
    name,
    namespace ? "default",
    labels ? {},
    annotations ? {},
    spec ? {},
    data ? {},
    stringData ? {},
    outputs ? {},
    requires ? [],
    extraDeps ? [],
  }:
    let
      nsInfo = resolveNamespace namespace;
      resolvedSpec = resolve spec;
      resolvedData = resolve data;
      resolvedStringData = resolve stringData;
      resolvedAnnotations = resolve annotations;

      inferredDeps = lib.unique (
        resolvedSpec.deps
        ++ resolvedData.deps
        ++ resolvedStringData.deps
        ++ resolvedAnnotations.deps
        ++ nsInfo.nsDep
        ++ extraDeps
      );

      self = {
        _type = "k8s-resource";
        inherit apiVersion kind name;
        inherit requires;
        namespace = nsInfo.nsString;

        ref = mkRef self "ref" name;
        out = lib.mapAttrs (k: v: mkRef self k v) outputs;
        fqdn = mkRef self "fqdn"
          (if nsInfo.nsString != null
           then "${name}.${nsInfo.nsString}.svc.cluster.local"
           else name);

        deps = inferredDeps;
        closure = computeClosure self;

        manifest = {
          inherit apiVersion kind;
          metadata = {
            inherit name;
            labels = { "app.kubernetes.io/name" = name; } // labels;
          } // lib.optionalAttrs (nsInfo.nsString != null) {
            namespace = nsInfo.nsString;
          } // lib.optionalAttrs (resolvedAnnotations.resolved != {}) {
            annotations = resolvedAnnotations.resolved;
          };
        } // lib.optionalAttrs (resolvedSpec.resolved != {}) {
          spec = resolvedSpec.resolved;
        } // lib.optionalAttrs (resolvedData.resolved != {}) {
          data = resolvedData.resolved;
        } // lib.optionalAttrs (resolvedStringData.resolved != {}) {
          stringData = resolvedStringData.resolved;
        };
      };
    in self;

  # ── Namespace constructor ────────────────────────────────────
  mkNamespace = {
    name,
    labels ? {},
    annotations ? {},
    resourceQuota ? null,
    limitRange ? null,
    networkPolicies ? [],
    requires ? [],
  }:
    let
      nsResource = mkResource {
        apiVersion = "v1";
        kind = "Namespace";
        inherit name labels annotations;
        namespace = clusterScoped;
      };

      quota = if resourceQuota == null then null else mkResource {
        apiVersion = "v1";
        kind = "ResourceQuota";
        name = "${name}-quota";
        namespace = nsResource;
        spec = resourceQuota;
      };

      lr = if limitRange == null then null else mkResource {
        apiVersion = "v1";
        kind = "LimitRange";
        name = "${name}-limits";
        namespace = nsResource;
        spec = limitRange;
      };

      netpols = lib.imap0 (i: spec: mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "NetworkPolicy";
        name = "${name}-netpol-${toString i}";
        namespace = nsResource;
        inherit spec;
      }) networkPolicies;

      policyResources =
        (lib.optional (quota != null) quota)
        ++ (lib.optional (lr != null) lr)
        ++ netpols
        ++ requires;

    in nsResource // {
      requires = policyResources;
      inherit quota;
      limitRange = lr;
      inherit netpols;
    };

}; in k8s
```

---

## Appendix B: Summary of Abstractions

| Abstraction | Purpose | Who writes it | Who uses it |
|---|---|---|---|
| `k8s.mkResource` | Create a resource with auto-tracked deps | kixlib core | Package authors |
| `k8s.mkNamespace` | Create a namespace with policies | kixlib core | Cluster evaluator |
| `k8s.str` | String interpolation that preserves dep tracking | kixlib core | Package authors |
| `crdLib.mkCRD` | Declare a Custom Resource Definition | kixlib core | CRD-providing packages |
| `crdLib.mkTypeProvider` | Bundle CRD + controller into a type constructor | kixlib core | CRD-providing packages |
| `builders.mkServiceMonitor` | Create a ServiceMonitor from structured data | kixlib builders | Modules |
| `builders.mkPDB` | Create a PodDisruptionBudget | kixlib builders | Modules or packages |
| `scope.mkResource` | Pre-bound mkResource with namespace and labels | Cluster evaluator | Package authors |
| `capabilities.*` | Plain data describing what a package offers | Package authors | Modules |
| `modules.*.apply` | Read capabilities, produce cross-cutting resources | Module authors | Cluster evaluator |
| `overrideParts` | Swap one resource in a package's inner fixpoint | Package system | Cluster operators |
| `overlay` | Swap one package in the cluster's outer fixpoint | Package system | Cluster operators |
| `buildCluster` | Evaluate the full cluster from declarative config | kixlib evaluator | End users |
