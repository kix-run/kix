---
title: "Making It Hard to Get Wrong"
date: 2026-03-18
date_end: 2026-03-23
series: 10
commits:
  - b305478  # feat: rbac DSL, with cert-manager example
  - 9459cb5  # feat: rbac, selector dsl and applied to a few packages
  - d8a2f35  # feat: storage dependency injection, package level meta
  - f4535f6  # feat: service and ingress DSL
---

# Making It Hard to Get Wrong

*2026-03-18 to 2026-03-23 -- Post 10*

---

The system works. Packages produce manifests. Clusters wire them together. Pipes compose resources. Overlays customize them. The remaining question is ergonomics: how do you make this pleasant to use day-to-day?

The answer is what programmers call a **domain-specific language** (DSL) -- a small vocabulary of functions designed for one job. You are not learning a new language. You are using Nix functions that know about Kubernetes. Think of it as a toolkit, not a language.

Three principles guided the design:

- **Don't invent new fields.** The DSL should work with standard Kubernetes manifest fields, not introduce custom spec keys that could confuse users or diverge from K8s semantics.
- **Automation over brevity.** DSL features exist to prevent mistakes -- mismatched selectors, forgotten dependencies -- not to save lines of code.
- **Resources are rich objects.** Resources expose derived properties (name, selector, labels) through `out`, so consumers query the resource directly rather than calling helper functions or relying on string interpolation.

Two stories illustrate these principles in practice.

## Story 1: RBAC

RBAC in Kubernetes requires at least three resources: a **ServiceAccount**, a **ClusterRole** (or Role), and a **ClusterRoleBinding** (or RoleBinding). The names and references across these resources must match exactly. The ClusterRoleBinding's `roleRef` must point at the correct ClusterRole. Its `subjects` must reference the correct ServiceAccount in the correct namespace. Get any of these wrong and the binding silently does nothing. This is the number one source of copy-paste errors in Kubernetes configuration.

Here is how the kix RBAC DSL handles cert-manager's permissions:

```nix
inherit (scope.rbac) grant allow core;

grant self.sa [
  (allow "get" "list" "watch" [
    (core [ "secrets" "configmaps" "events" ])
    (scope.rbac.group "cert-manager.io" [ "certificates" "issuers" "clusterissuers" ])
  ])
  (allow "update" "patch" [
    (core [ "secrets" ])
  ])
]
```

**`grant`** takes two arguments: a ServiceAccount and a list of permission groups. It generates the ClusterRole, the ClusterRoleBinding, and wires the names automatically. The ServiceAccount is `self.sa` -- a reference to the package's own ServiceAccount resource, accessed through `out`.

**`allow`** takes verbs and a list of resource groups. Each group specifies an API group and the resources within it. **`core`** is shorthand for the core API group (the empty string in Kubernetes). `scope.rbac.group` handles named API groups like `cert-manager.io`.

The DSL does not invent new permission semantics. The verbs are standard Kubernetes verbs. The resource names are standard Kubernetes resource names. The API groups are standard API groups. What the DSL eliminates is the structural boilerplate -- the three separate resource definitions that must cross-reference each other correctly.

You cannot get a mismatched binding because there is only one place to declare the intent. The grant, the role, and the binding are a single expression. The DSL derives the wiring.

## Story 2: Storage dependency injection

Many packages need persistent storage. Harbor needs it for its registry data. Prometheus needs it for metrics. The naive approach is to hardcode the storage class inside the package:

```nix
storageClassName = "localzfs-retain";
```

This breaks the moment you deploy to a different cluster. A cloud cluster uses `gp3`. A dev cluster uses `standard`. The storage backend is a property of the **cluster**, not the **package**.

The solution is dependency injection through the module system. The package declares that it needs a storage class:

```nix
# In the package:
options.persistence.storageClass = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;
};
```

The cluster definition provides it:

```nix
# In the cluster definition:
instances.apps = {
  harbor = {
    package = packages.harbor;
    config.persistence.storageClass = "localzfs-retain";
  };
};
```

The package does not know about `localzfs-retain`. It declares a typed option with a null default. The cluster fills it in. If you forget, the build warns you. The package stays portable. The cluster stays explicit about its infrastructure choices.

This is not a new pattern -- NixOS modules work the same way. But applying it to Kubernetes packages solves a real problem. Helm charts handle this with `values.yaml` overrides, but those overrides are untyped strings. Misspell the storage class name and Helm will not notice. kix's module system catches the type mismatch at build time.

## Why these two stories

RBAC and storage injection illustrate different ends of the DSL spectrum. The RBAC DSL is a **combinator language** -- small composable functions (`grant`, `allow`, `core`) that eliminate structural repetition. Storage injection is plain **module system plumbing** -- typed options flowing from cluster to package. One is a custom DSL. The other is just Nix modules doing what they already do.

Both follow the same principles. Neither invents new Kubernetes semantics. Both prevent mistakes that would otherwise surface only at deploy time. Both treat resources as rich objects whose properties flow through the system rather than being copied by hand.

The goal was never to make Kubernetes configuration shorter. It was to make it harder to get wrong.
