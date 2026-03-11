# Nix-Inspired Kubernetes Resource Management

## Why This Exists

Helm templates are string soup. Kustomize is patching YAML with more YAML. Neither gives you a real dependency graph, composable packages, or the ability to swap one resource while keeping everything else consistent.

Nix solved this problem for software builds decades ago. This document describes a pattern that applies the same ideas — derivations, fixpoints, string contexts, and overlays — to Kubernetes resource management.

The core insight: **a K8s resource is a derivation.** It has inputs (other resources it references), outputs (its name, ports, endpoints), and a manifest (the build output). If we model resources this way, we get automatic dependency tracking, composable packages with overridable parts, and a real DAG we can query, diff, and deploy in order.

---

## Background: How Nix Solves This

Skip this section if the team is already comfortable with Nix internals.

### Derivations Are Just Data

When you call `mkDerivation` in Nix, nothing gets built. Nix produces an attribute set with an `outPath` — a store path computed by hashing the derivation's description (name, builder, inputs). This happens purely during evaluation, before any building.

### String Context Tracks Dependencies Automatically

When you write `"${openssl}/lib"` in a build script, two things happen simultaneously:

1. The literal store path gets substituted into the string.
2. Nix records `openssl` as a dependency in the string's invisible *context* metadata.

When the enclosing derivation is constructed, Nix walks all attribute values, collects every string context, and populates the `inputDrvs` field of the `.drv` file. You never list dependencies manually — they're inferred from usage.

### The Package Set Is a Fixpoint

`nixpkgs` is defined as `lib.fix (self: { openssl = ...; curl = ... { inherit openssl; }; ... })`. The `self` argument lets any package reference any other package, and lazy evaluation means Nix only computes what's actually needed. Overlays work by composing functions over this fixpoint.

### Overrides Are Surgical

`pkgs.openssl.override { ... }` changes the inputs to openssl while keeping its structure. `overrideAttrs` lets you change individual attributes (phases, patches, flags) without rewriting the whole derivation.

---

## Conceptual Mapping

| Nix Concept | K8s Equivalent |
|---|---|
| derivation | a resource (Deployment, ConfigMap, PVC...) |
| `outPath` | `metadata.name` (+ namespace) — the identity |
| string context / `inputDrvs` | references to other resources' names |
| fixed-output derivation | externally-managed resources (existing PV, external Secret) |
| `env` vars | the resource's spec fields |
| multi-output (`.lib`, `.dev`) | a resource exposing multiple interfaces (port, clusterIP, claimName) |
| `propagatedBuildInputs` | `requires` — transitive deps the consumer didn't ask for |
| `overrideAttrs` | `overrideParts` — swap one resource in a package |
| overlay | swap or modify one package in the cluster |
| `lib.fix` | self-referential package definitions |

---

## The Three Kinds of Dependencies

This is the most important section. K8s resources have three distinct dependency relationships, and conflating them breaks the DAG.

### 1. `deps` — Automatic, from refs (like `buildInputs`)

"I reference this resource by name in my spec."

Examples: Deployment → ConfigMap (via `configMapRef.name`), Deployment → ServiceAccount (via `serviceAccountName`), Ingress → Service (via `backend.service.name`).

These are **inferred automatically** by the tree walker. You never write them by hand.

### 2. `requires` — Manual, inverted refs (like `propagatedBuildInputs`)

"I need this to function, but *it* references *me*, not the other way around."

This is the tricky one. In K8s YAML, a ClusterRoleBinding points to a ServiceAccount. But semantically, the ServiceAccount is useless without its binding. The YAML ref direction is inverted relative to the semantic dependency.

Examples:
- ServiceAccount → its ClusterRoleBinding(s)
- Deployment → its PodDisruptionBudget
- Deployment → its HorizontalPodAutoscaler
- CRD → its controller Deployment
- Namespace → its ResourceQuotas and LimitRanges

`requires` flows **transitively**. If you pull on a Deployment that refs a ServiceAccount, and that ServiceAccount requires a ClusterRoleBinding, the binding comes along. This is what makes "pull on one resource, get everything it needs" work.

### 3. `extraDeps` — Manual, ordering only (like `nativeBuildInputs`)

"Deploy this before me, but don't include it in my closure."

Rarely needed. For cases like "the migration Job must complete before the Deployment rolls out" where there's no ref and no requires relationship.

### Visualizing the Inversion

```
             YAML ref direction        Semantic dep direction
             (what K8s sees)           (what our DAG models)

Binding ──ref──→ Role                  Binding ──ref──→ Role       (same direction)
Binding ──ref──→ SA                    SA ──requires──→ Binding    (INVERTED)
Deploy  ──ref──→ SA                    Deploy ──ref──→ SA          (same direction)
Deploy  ──ref──→ ConfigMap             Deploy ──ref──→ ConfigMap   (same direction)
PDB     ──label→ Deploy pods           Deploy ──requires──→ PDB   (INVERTED)
```

Rule of thumb: if A refs B in the YAML, the dep is `A → B` (automatic). If A needs B but B refs A in the YAML, then `A.requires = [ B ]` (manual).

---

## Core Library: `k8s/lib.nix`

### Refs — The Context Carrier

A `Ref` is a value that remembers which resource produced it. It's our equivalent of a Nix string with context.

```nix
mkRef = resource: output: value: {
  _type = "k8s-ref";
  inherit resource output value;
  # Degrades to plain string in ${} interpolation (loses tracking)
  __toString = self: toString self.value;
};

isRef = v: builtins.isAttrs v && (v._type or "") == "k8s-ref";
```

A resource exposes refs like:

```nix
self = {
  ref = mkRef self "ref" name;                    # primary identity
  out = {
    port = mkRef self "port" 80;                  # named output
    claimName = mkRef self "claimName" name;       # named output
  };
};
```

When you write `configmap.ref` in another resource's spec, the tree walker sees the `_type = "k8s-ref"` tag and records the dependency.

### Tracked Strings — Interpolation Without Losing Context

Native Nix `${}` interpolation calls `__toString`, which returns a plain string and loses our tracking metadata. The `str` combinator preserves it:

```nix
# Instead of: "postgresql://${db.out.host}:${toString db.out.port}/mydb"
# Write:      k8s.str [ "postgresql://" db.out.host ":" db.out.port "/mydb" ]

str = parts: { _type = "k8s-tracked-str"; inherit parts; };
isTrackedStr = v: builtins.isAttrs v && (v._type or "") == "k8s-tracked-str";
```

The trade-off: slightly less ergonomic than `${}`, but dependencies are tracked correctly through string construction.

### The Tree Walker — Automatic Dependency Collection

This is the equivalent of what `builtins.derivation` does internally: walk all attribute values in the spec, find everything tagged as a ref, collect the source resources.

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

The walker recurses into attrsets and lists, resolves refs to their plain values (for the final manifest), and accumulates the source resources (for the dependency list). `mkResource` calls this on spec/data/annotations and gets `deps` for free.

### Closure Computation

The closure follows **both** `deps` (from refs, automatic) and `requires` (manual, inverted relationships) transitively.

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

This is the core operation. `resource.closure` gives you every resource transitively needed, discovered through both reference tracking and manual requires annotations.

### `mkResource` — The Full Constructor

```nix
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
  requires ? [],       # inverted deps — things I need that reference me
  extraDeps ? [],      # ordering-only deps
}:
  let
    resolvedSpec = resolve spec;
    resolvedData = resolve data;
    resolvedStringData = resolve stringData;
    resolvedAnnotations = resolve annotations;

    inferredDeps = lib.unique (
      resolvedSpec.deps
      ++ resolvedData.deps
      ++ resolvedStringData.deps
      ++ resolvedAnnotations.deps
      ++ extraDeps
    );

    self = {
      _type = "k8s-resource";
      inherit apiVersion kind name namespace;
      inherit requires;

      ref = mkRef self "ref" name;
      out = lib.mapAttrs (k: v: mkRef self k v) outputs;

      deps = inferredDeps;
      closure = computeClosure self;

      manifest = {
        inherit apiVersion kind;
        metadata = {
          inherit name namespace;
          labels = { "app.kubernetes.io/name" = name; } // labels;
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
```

---

## Packages: The Inner Fixpoint

A "K8s package" is a self-referential set of resources. The inner fixpoint (`lib.fix`) lets any resource within a package reference any other resource in the same package, and lazy evaluation means only what's needed gets computed.

### Package Constructor

```nix
mkPackage = packageFn: defaults:
  let
    parts = lib.fix (packageFn defaults);
  in parts // {
    # The "outPath" — what other packages see when they reference this one
    main = parts.main or (throw "package must define a 'main' resource");

    # Shortcuts: pkgs.coredns.ref = pkgs.coredns.main.ref
    ref = parts.main.ref;
    out = parts.main.out;

    # Closure rooted at main — this is what you deploy
    closure = parts.main.closure;

    # Cherry-pick closure from a different root
    closureOf = resource: resource.closure;

    # Override individual parts (inner fixpoint)
    overrideParts = overrideFn:
      mkPackage (args: self:
        let base = packageFn args self;
        in base // (overrideFn self base)
      ) defaults;

    # Override package arguments (namespace, image, etc.)
    override = newArgs:
      mkPackage packageFn (defaults // newArgs);
  };
```

### What `main` Means

Every package must declare a `main` resource. This is the resource other packages interact with — it's the public interface. Everything else is implementation detail.

For CoreDNS, `main` is the Service (consumers connect to `kube-dns:53`). For cert-manager, it might be the ClusterIssuer. For a database, it's the Service with host/port outputs.

`main` carries `requires` that pull in the workload and everything behind it. When another package references `pkgs.coredns.ref`, it gets the Service's name — but `pkgs.coredns.closure` includes the Deployment, RBAC, ConfigMap, and everything else needed to make that Service actually work.

---

## Full Example: CoreDNS Package

```nix
# packages/coredns.nix
{ k8s, lib }:

k8s.mkPackage
  ({ namespace ? "kube-system",
     image ? "registry.k8s.io/coredns/coredns:v1.11.1",
     replicas ? 2,
  }:
    self: {

      # ── Configuration ─────────────────────────────────────────

      corefile = ''
        .:53 {
          errors
          health { latefatal }
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
          }
          forward . /etc/resolv.conf
          cache 30
          loop
          reload
          loadbalance
        }
      '';

      configmap = k8s.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "coredns";
        inherit namespace;
        data.Corefile = self.corefile;
      };

      # ── RBAC ───────────────────────────────────────────────────
      #
      # YAML ref direction:   binding → role, binding → SA
      # Semantic dep direction: SA → binding → role
      #
      # The binding's refs to role and SA are tracked automatically.
      # The SA's requires on the binding is declared manually
      # (inverted relationship).

      clusterRole = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "system:coredns";
        spec.rules = [
          {
            apiGroups = [ "" ];
            resources = [ "endpoints" "services" "pods" "namespaces" ];
            verbs = [ "list" "watch" ];
          }
          {
            apiGroups = [ "discovery.k8s.io" ];
            resources = [ "endpointslices" ];
            verbs = [ "list" "watch" ];
          }
        ];
      };

      clusterRoleBinding = k8s.mkResource {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRoleBinding";
        name = "system:coredns";
        spec = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = self.clusterRole.ref;            # auto-tracked
          };
          subjects = [{
            kind = "ServiceAccount";
            name = self.serviceAccount.ref;          # auto-tracked
            inherit namespace;
          }];
        };
      };

      serviceAccount = k8s.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "coredns";
        inherit namespace;
        # ← INVERTED RELATIONSHIP: SA needs its binding to be useful
        requires = [ self.clusterRoleBinding ];
      };

      # ── Workload ───────────────────────────────────────────────

      pdb = k8s.mkResource {
        apiVersion = "policy/v1";
        kind = "PodDisruptionBudget";
        name = "coredns";
        inherit namespace;
        spec = {
          maxUnavailable = 1;
          selector.matchLabels."k8s-app" = "kube-dns";
        };
      };

      workload = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "coredns";
        inherit namespace;
        requires = [ self.pdb ];                     # ← inverted
        spec = {
          inherit replicas;
          selector.matchLabels."k8s-app" = "kube-dns";
          template = {
            metadata.labels."k8s-app" = "kube-dns";
            spec = {
              serviceAccountName = self.serviceAccount.ref;  # auto-tracked
              containers = [{
                name = "coredns";
                inherit image;
                args = [ "-conf" "/etc/coredns/Corefile" ];
                ports = [
                  { containerPort = 53; protocol = "UDP"; name = "dns"; }
                  { containerPort = 53; protocol = "TCP"; name = "dns-tcp"; }
                ];
                volumeMounts = [{
                  name = "config-volume";
                  mountPath = "/etc/coredns";
                  readOnly = true;
                }];
              }];
              volumes = [{
                name = "config-volume";
                configMap.name = self.configmap.ref;          # auto-tracked
              }];
            };
          };
        };
      };

      # ── Service ────────────────────────────────────────────────

      service = k8s.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "kube-dns";
        inherit namespace;
        outputs = { clusterIP = "10.96.0.10"; };
        spec = {
          selector."k8s-app" = "kube-dns";
          clusterIP = "10.96.0.10";
          ports = [
            { name = "dns"; port = 53; protocol = "UDP"; }
            { name = "dns-tcp"; port = 53; protocol = "TCP"; }
          ];
        };
      };

      # ── Main: the public interface ─────────────────────────────
      #
      # From outside, coredns IS the Service.
      # But deploying it requires the workload behind it.

      main = self.service // {
        requires = [ self.workload ];
      };
    })
  { namespace = "kube-system"; }
```

### Tracing the Closure

Starting from `main` (the Service), here's what the closure computation discovers:

```
main (Service/kube-dns)
│
├─ requires → workload (Deployment/coredns)
│   │
│   ├─ ref → serviceAccount (ServiceAccount/coredns)
│   │   │
│   │   └─ requires → clusterRoleBinding (ClusterRoleBinding/system:coredns)
│   │       │
│   │       ├─ ref → clusterRole (ClusterRole/system:coredns)
│   │       │        (leaf — no deps, no requires)
│   │       │
│   │       └─ ref → serviceAccount (already seen, skip)
│   │
│   ├─ ref → configmap (ConfigMap/coredns)
│   │        (leaf — no deps, no requires)
│   │
│   └─ requires → pdb (PodDisruptionBudget/coredns)
│                  (leaf — no deps, no requires)
│
└─ deps = [] (Service has no refs to other resources)

Result: [ Service, Deployment, ServiceAccount, ConfigMap,
          PDB, ClusterRoleBinding, ClusterRole ]
```

Every resource needed to make CoreDNS work. Nothing extra.

---

## Overriding: Swap Deployment → StatefulSet

```nix
myCoredns = pkgs.coredns.overrideParts (self: super: {

  # Keep: configmap, serviceAccount, clusterRole, clusterRoleBinding,
  #        pdb, service — all inherited from super via self.

  # Swap: workload from Deployment to StatefulSet
  workload = k8s.mkResource {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    name = "coredns";
    namespace = "kube-system";
    requires = [ self.pdb ];
    spec = {
      replicas = 3;
      serviceName = self.service.ref;              # NEW — StatefulSets need this
      selector.matchLabels."k8s-app" = "kube-dns";
      template = {
        metadata.labels."k8s-app" = "kube-dns";
        spec = {
          serviceAccountName = self.serviceAccount.ref;   # same SA
          containers = [{
            name = "coredns";
            image = "registry.k8s.io/coredns/coredns:v1.11.1";
            args = [ "-conf" "/etc/coredns/Corefile" ];
            volumeMounts = [
              { name = "config"; mountPath = "/etc/coredns"; readOnly = true; }
              { name = "data"; mountPath = "/var/coredns"; }
            ];
          }];
          volumes = [{
            name = "config";
            configMap.name = self.configmap.ref;           # same configmap
          }];
        };
      };
      volumeClaimTemplates = [{
        metadata.name = "data";
        spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "1Gi";
        };
      }];
    };
  };
});
```

What changed in the closure:

```
BEFORE (Deployment)                    AFTER (StatefulSet)
───────────────────                    ────────────────────
Service/kube-dns                       Service/kube-dns
Deployment/coredns                     StatefulSet/coredns         ← swapped
ServiceAccount/coredns                 ServiceAccount/coredns
ClusterRoleBinding/system:coredns      ClusterRoleBinding/system:coredns
ClusterRole/system:coredns             ClusterRole/system:coredns
ConfigMap/coredns                      ConfigMap/coredns
PDB/coredns                            PDB/coredns
                                       (Service now also in workload
                                        deps via serviceName ref)
```

The RBAC chain, configmap, and PDB carried over automatically. The Service appeared in the workload's `deps` because StatefulSets reference their governing service via `serviceName`, which the tree walker detected.

---

## The Outer Fixpoint: Cluster Composition

### Package Set

```nix
# cluster.nix
{ lib }:

let
  k8s = import ./k8s/lib.nix { inherit lib; };

  basePackages = self: {
    coredns = import ./packages/coredns.nix {
      inherit k8s lib;
    };

    certManager = import ./packages/cert-manager.nix {
      inherit k8s lib;
    };

    myApp = import ./packages/my-app.nix {
      inherit k8s lib;
      coredns = self.coredns;     # cross-package dependency
    };
  };

  applyOverlays = overlays: base:
    let
      applied = lib.foldl'
        (prev: overlay: self:
          let super = prev self;
          in super // (overlay self super))
        base
        overlays;
    in lib.fix applied;

in {
  mkCluster = { overlays ? [] }:
    applyOverlays overlays basePackages;
}
```

### Cross-Package References

```nix
# packages/my-app.nix
{ k8s, lib, coredns }:

k8s.mkPackage
  ({ namespace ? "default", ... }:
    self: {
      deployment = k8s.mkResource {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "my-app";
        inherit namespace;
        spec = {
          template.spec.containers = [{
            name = "app";
            image = "myapp:latest";
            env = [{
              name = "DNS_SERVER";
              # coredns.ref = coredns.main.ref = "kube-dns"
              # This auto-tracks the dep on coredns's main resource
              value = k8s.str [ coredns.ref ":53" ];
            }];
          }];
        };
      };

      main = self.deployment;
    })
  { namespace = "default"; }
```

`myApp.closure` now includes myApp's Deployment AND all of coredns's closure — because `coredns.ref` tracked back to `coredns.main`, which requires the workload, which refs the SA, which requires the binding, etc.

### Overlays

```nix
myCluster = (import ./cluster.nix { inherit lib; }).mkCluster {
  overlays = [
    # Swap coredns to StatefulSet
    (self: super: {
      coredns = super.coredns.overrideParts (cSelf: cSuper: {
        workload = k8s.mkResource { /* StatefulSet version */ };
      });
    })

    # Staging environment
    (self: super: {
      myApp = super.myApp.override {
        namespace = "staging";
      };
    })
  ];
};
```

Overlays compose left-to-right. Each sees `super` (the previous layer) and `self` (the final result, for cross-references). Identical to nixpkgs overlays.

---

## How the Two Fixpoints Interact

```
┌──────────────────────────────────────────────────────────────┐
│  OUTER FIXPOINT (pkgs / cluster)                             │
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
│  │  │ workload ────┘     │ │ ◄────────────────────── myApp   │
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

## Querying the DAG

Since every resource carries its full closure, you can answer questions about the cluster:

```nix
# What does deploying myApp require?
map (r: "${r.kind}/${r.name}") myCluster.myApp.closure
# → [ "Deployment/my-app" "Service/kube-dns" "Deployment/coredns"
#      "ServiceAccount/coredns" "ClusterRoleBinding/system:coredns"
#      "ClusterRole/system:coredns" "ConfigMap/coredns" "PDB/coredns" ]

# What are the direct deps of the coredns workload?
map (r: "${r.kind}/${r.name}") myCluster.coredns.workload.deps
# → [ "ServiceAccount/coredns" "ConfigMap/coredns" ]

# What does the ServiceAccount pull in via requires?
map (r: "${r.kind}/${r.name}") myCluster.coredns.serviceAccount.closure
# → [ "ServiceAccount/coredns" "ClusterRoleBinding/system:coredns"
#      "ClusterRole/system:coredns" ]

# Give me just the RBAC resources for coredns
myCluster.coredns.closureOf myCluster.coredns.serviceAccount
```

This enables tooling that Helm and Kustomize can't provide: deploy only what changed, detect cycles, diff two cluster configurations at the resource level and trace *why* something changed (which input to which resource), produce a deployment plan that respects ordering constraints.

---

## Comparison to Helm

| Concern | Helm | This Pattern |
|---|---|---|
| Dependency tracking | None. Resources are independent YAML docs. | Full DAG. `deps` (auto) + `requires` (manual) + transitive closure. |
| Reference integrity | Strings. Typo in a configmap name → runtime error. | Refs. `configmap.ref` is type-checked at eval time. |
| Composability | Subcharts with `values.yaml` plumbing. Limited override surface. | Fixpoints + `overrideParts`. Override any resource while keeping the rest. |
| Cross-chart deps | Manual `values.yaml` wiring. No enforcement. | Cross-package refs via the outer fixpoint. Auto-tracked. |
| Deploy ordering | None. `helm install` dumps everything at once. | Topological sort on the closure. |
| Diffing | `helm diff` — YAML string comparison. | DAG diff — trace exactly which input changed and what it affected. |
| Reuse | Copy-paste templates. Parameterize everything via `values.yaml`. | `override` for args, `overrideParts` for structure. Inherit what you don't change. |

---

## Common Patterns

### RBAC Helper

Since the SA→binding inversion is so common:

```nix
withRBAC = sa: bindings:
  sa // { requires = (sa.requires or []) ++ bindings; };
```

### Workload + PDB

```nix
withPDB = workload: pdb:
  workload // { requires = (workload.requires or []) ++ [ pdb ]; };
```

### External / Pre-existing Resources

For resources that already exist in the cluster (like a shared PV or external service), model them as leaf resources with no spec — just a name and outputs:

```nix
externalDB = k8s.mkResource {
  apiVersion = "v1";
  kind = "Service";
  name = "external-postgres";
  namespace = "databases";
  outputs = { host = "external-postgres"; port = 5432; };
  # No spec — this resource is not managed by us.
  # It's a fixed-output derivation: we know its identity, we don't build it.
};
```

### Multi-Environment via Override

```nix
staging = pkgs.myApp.override {
  namespace = "staging";
  replicas = 1;
  image = "myapp:staging-latest";
};

production = pkgs.myApp.override {
  namespace = "production";
  replicas = 5;
  image = "myapp:v2.1.0";
};
```

---

## Open Questions and Future Work

### Automatic `requires` Detection

The manual `requires` list is small and well-understood (SA→bindings, workload→PDB), but we could potentially infer some of these by convention. For example: "if a ClusterRoleBinding's subjects include a ServiceAccount, automatically add the binding to that SA's requires." This is a linting/validation layer, not a core mechanism change.

### Manifest Rendering

The current `manifest` output is a Nix attrset. We need a serialization step to produce YAML. This could be `builtins.toJSON` piped through a simple JSON-to-YAML converter, or a direct Nix-to-YAML serializer.

### Diffing

The big payoff of having a DAG: diff two evaluations (e.g., before/after a PR) and get a precise report of which resources changed and which input triggered the change. This is the K8s equivalent of `nix-diff` on two `.drv` files.

### Validation

The ref system gives us enough information to validate at eval time: every `.ref` and `.out` access must point to a resource in the same package (or a passed-in cross-package dep). Dangling refs are eval-time errors, not deploy-time surprises.

### Integration with `kubectl apply`

The closure is topo-sorted. A deploy tool can iterate the closure, apply each resource, wait for readiness, and proceed — respecting the dependency ordering that Helm ignores.
