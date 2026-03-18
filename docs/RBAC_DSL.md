# RBAC DSL

This guide covers the RBAC DSL available via `scope.rbac`. It builds on the
patterns from the [Package Guide](PACKAGE_GUIDE.md) — in particular sections 7
(Inverse Dependencies) and 6 (When to Use `requires`).

If you haven't read those sections, the key fact is: **you don't need to add
RBAC resources to `requires`**. kix detects them automatically because the
bindings reference your ServiceAccount, which is already in the closure.

---

## The Problem

Raw RBAC is verbose. Every ClusterRole needs `apiVersion`, `kind`, `name`,
`labels`, and a list of `{ apiGroups; resources; verbs }` rule objects. Every
binding duplicates the name, labels, and repeats the `roleRef` + `subjects`
boilerplate. A package with 8 roles and 8 bindings easily hits 500+ lines of
pure boilerplate.

The DSL replaces all of that with intent-based, pipe-friendly expressions:

```nix
# Before: 48 lines
controllerRoleIssuers = scope.mkClusterResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRole";
  name = "${name}-controller-issuers";
  labels = controllerLabels;
  extra.rules = [
    { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" "issuers/status" ]; verbs = [ "update" "patch" ]; }
    { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" ]; verbs = [ "get" "list" "watch" ]; }
    { apiGroups = [ "" ]; resources = [ "secrets" ]; verbs = [ "get" "list" "watch" "create" "update" "delete" ]; }
    { apiGroups = [ "" ]; resources = [ "events" ]; verbs = [ "create" "patch" ]; }
  ];
};
controllerBindingIssuers = scope.mkClusterResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRoleBinding";
  name = "${name}-controller-issuers";
  labels = controllerLabels;
  extra = {
    roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "ClusterRole"; name = "${self.controllerRoleIssuers}"; };
    subjects = [{ kind = "ServiceAccount"; name = "${self.controllerServiceAccount}"; namespace = ns; }];
  };
};

# After: 5 lines (role + binding generated together)
"${name}-controller-issuers" = grant [
  (cm.issuers   |> reconcile)
  (core.secrets |> readWrite)
  (core.events  |> emit)
];
```

---

## Quick Start

Here's a minimal package using the DSL for a single ClusterRole + binding:

```nix
{ scope, config, lib }:

let
  cfg = scope.defaults config { image = "myapp:latest"; };
  name = scope.instanceName;
  ns = scope.namespaceName;
  labels = { "app.kubernetes.io/name" = "myapp"; };

  inherit (scope.rbac) group core grant watch mkClusterRoleSet;
in

self:
let
  clusterRoles = mkClusterRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = "${self.serviceAccount}"; namespace = ns; }];
    labels = labels;
    roles = {
      "${name}-myapp" = grant [
        (core.configmaps |> watch)
        (core.secrets    |> watch)
      ];
    };
  };
in {
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = name;
    inherit labels;
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = name;
    inherit labels;
    spec.template.spec.serviceAccountName = "${self.serviceAccount}";
    # ...
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = name;
    inherit labels;
    requires = [ self.deployment ];
    spec.selector = labels;
    spec.ports = [{ port = 80; }];
  };

  main = self.service;

} // clusterRoles   # ← spreads ClusterRole + ClusterRoleBinding onto self
```

Three things to notice:

1. **`// clusterRoles` at the end** — this is how the generated resources
   become visible to kix. The `//` merges them onto `self` as top-level
   attributes, which is how kix discovers resources.

2. **No `requires`** — the ClusterRoleBinding references the ServiceAccount
   via `"${self.serviceAccount}"`. kix's inverse dependency detection finds the
   binding (it references a resource that's in the closure), and the binding
   pulls in the ClusterRole transitively. See Package Guide section 7.

3. **Inner `let`** — role sets are defined inside `self:` in a `let` block so
   they can reference `self` for the subjects. They don't need to be (and
   shouldn't be) listed in `main` or `requires`.

---

## Concepts

### Refs — pointing at a K8s resource type

A **Ref** is a pointer to a Kubernetes resource type within an API group:

```nix
# group creates a Ref factory with dot access + callable fallback
cm = group "cert-manager.io" [ "issuers" "clusterissuers" "certificates" ];

cm.issuers                      # dot access (pre-declared resources)
cm "certificaterequests/status" # callable fallback (arbitrary strings)
```

`core` is pre-populated with common core API resources:

```nix
core.secrets        core.events         core.pods
core.services       core.configmaps     core.namespaces
core.endpoints      core.nodes          core.serviceaccounts
core.persistentvolumes                  core.persistentvolumeclaims
core "custom-thing" # callable fallback for anything not pre-declared
```

### Ref modifiers

`sub suffix` accesses a sub-resource. Useful with `map` for lists:

```nix
core.pods |> sub "status"                    # single ref: pods/status
map (sub "finalizers") actionResources       # list: [res1/finalizers, res2/finalizers, ...]
```

`restrictTo names` scopes to specific resourceNames:

```nix
core.serviceaccounts |> restrictTo [ "${self.sa}" ] |> allow [ "create" ]
```

### Intents — what a controller does with a resource

An **intent** is a function `Ref | [Ref] -> [Rule]` that describes a permission
pattern. Accepts a single Ref or a list of Refs. Use with the pipe operator:

```nix
cm.issuers |> reconcile                           # single ref
core.events |> emit                               # single ref
[core.pods core.services] |> watch                # list — rules merged by grant
map (sub "status") actionResources |> allow [...]  # list of sub-resources
```

| Intent | Verbs | Subresources |
|---|---|---|
| `watch` | get, list, watch | — |
| `reconcile` | get, list, watch | + update, patch on `/status` |
| `finalize` | — | update on `/finalizers` |
| `own` | get, list, watch, create, delete | — |
| `readWrite` | get, list, watch, create, update, delete | — |
| `full` | get, list, watch, create, update, delete, patch | — |
| `emit` | create, patch | — |
| `watchAndFinalize` | get, list, watch | + update on `/finalizers` |
| `allow verbs` | *(explicit list)* | — |

**`reconcile` vs `finalize`** — `reconcile` adds `/status` rules only. Not all
controllers use finalizers (cert-manager issuers don't). Add `finalize`
separately when needed:

```nix
(cm.certificates |> reconcile)   # watch + update/patch status
(cm.certificates |> finalize)    # update finalizers
```

**`allow`** is the escape hatch for non-standard verb combinations:

```nix
(core.events |> allow [ "get" "create" "update" "patch" ])
```

### Modifiers — refining a ref before applying an intent

**`restrictTo`** adds a `resourceNames` constraint. Chain it before an intent:

```nix
cm.signers
  |> restrictTo [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]
  |> allow [ "approve" ]
```

### grant — combining intents into one rule list

`grant` flattens a list of intent results into a single `[Rule]`:

```nix
"${name}-controller-issuers" = grant [
  (cm.issuers   |> reconcile)    # → 2 rules (watch + status)
  (core.secrets |> readWrite)    # → 1 rule
  (core.events  |> emit)         # → 1 rule
];
# result: 4 rules total
```

---

## Building Role Sets

### `mkClusterRoleSet` — cluster-scoped roles

Creates a ClusterRole + ClusterRoleBinding for each entry in `roles`. All
roles in the set share the same `subjects` and `labels`.

```nix
controllerClusterRoles = mkClusterRoleSet scope {
  subjects = [{ kind = "ServiceAccount"; name = "${self.sa}"; namespace = ns; }];
  labels = myLabels;
  roles = {
    "${name}-reader" = grant [
      (core.configmaps |> watch)
      (core.secrets    |> watch)
    ];
    "${name}-writer" = grant [
      (core.configmaps |> readWrite)
    ];
  };
};
```

This generates 4 resources: 2 ClusterRoles + 2 ClusterRoleBindings.

### `mkRoleSet` — namespace-scoped roles

Identical interface, but creates Role + RoleBinding (namespace-scoped):

```nix
leaderElection = mkRoleSet scope {
  subjects = [{ kind = "ServiceAccount"; name = "${self.sa}"; namespace = ns; }];
  labels = myLabels;
  roles = {
    "${name}:leaderelection" = grant [
      (coord.leases |> restrictTo [ "my-controller" ] |> allow [ "get" "update" "patch" ])
      (coord.leases |> allow [ "create" ])
    ];
  };
};
```

### Return value

Both functions return a **flat attrset** of kix resources:

```nix
{
  "${name}-reader"         = <ClusterRole resource>;
  "${name}-reader-binding" = <ClusterRoleBinding resource>;
  "${name}-writer"         = <ClusterRole resource>;
  "${name}-writer-binding" = <ClusterRoleBinding resource>;
}
```

Merge onto `self` with `//`:

```nix
} // controllerClusterRoles // leaderElection
```

---

## Why `//` and Not `requires`

The bindings generated by `mkClusterRoleSet` reference your ServiceAccount
via `"${self.serviceAccount}"`. This creates a store-path dependency.

kix's inverse dependency detection (Package Guide section 7) sees that the
binding references a resource already in the closure and pulls it in. The
binding's `"${role}"` reference to the ClusterRole then pulls that in
transitively.

The `//` is needed because kix discovers resources by scanning top-level
`self` attributes. Resources that only exist in a `let` binding (not on `self`)
are invisible to kix's resource registry.

So the `//` serves one purpose: **making the resources visible to kix**. The
closure inclusion happens automatically via inverse deps.

---

## Standalone Roles (No Binding)

Some ClusterRoles use RBAC aggregation labels and have no bindings (e.g.,
`aggregate-to-view`, `aggregate-to-edit`). These can't use `mkClusterRoleSet`.
Write them as plain `scope.mkClusterResource` calls but still use `grant` for
the rules:

```nix
viewRole = scope.mkClusterResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRole";
  name = "${name}-view";
  labels = myLabels // {
    "rbac.authorization.k8s.io/aggregate-to-view" = "true";
  };
  extra.rules = grant [
    (cm.certificates |> watch)
    (cm.issuers      |> watch)
  ];
};
```

These DO need to go in `requires` since nothing references them — they have
no binding and no store-path connection to the closure:

```nix
main = {
  resource = self.service;
  requires = [ self.viewRole self.editRole ];
};
```

---

## Full Pattern

Putting it all together — the structure for a package with complex RBAC:

```nix
{ scope, config, lib }:

let
  name = scope.instanceName;
  ns = scope.namespaceName;

  # Import DSL
  inherit (scope.rbac)
    group core grant
    watch reconcile finalize own readWrite full emit watchAndFinalize
    allow restrictTo
    mkClusterRoleSet mkRoleSet;

  # Declare API groups and the resources you touch
  myApi = group "myapp.example.com" [ "widgets" "gadgets" ];
  coord = group "coordination.k8s.io" [ "leases" ];

  # Labels, config, etc.
  labels = { "app.kubernetes.io/name" = "myapp"; };
in

self:
let

  # ── Cluster-scoped RBAC ──────────────────────────────────
  clusterRoles = mkClusterRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = "${self.serviceAccount}"; namespace = ns; }];
    labels = labels;
    roles = {
      "${name}-controller" = grant [
        (myApi.widgets |> reconcile)
        (myApi.widgets |> finalize)
        (myApi.gadgets |> own)
        (core.events   |> emit)
      ];
    };
  };

  # ── Namespace-scoped RBAC ────────────────────────────────
  leaderElection = mkRoleSet scope {
    subjects = [{ kind = "ServiceAccount"; name = "${self.serviceAccount}"; namespace = ns; }];
    labels = labels;
    roles = {
      "${name}:leaderelection" = grant [
        (coord.leases |> restrictTo [ "myapp-controller" ] |> allow [ "get" "update" "patch" ])
        (coord.leases |> allow [ "create" ])
      ];
    };
  };

in {

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = name;
    inherit labels;
  };

  deployment = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = name;
    inherit labels;
    spec.template.spec.serviceAccountName = "${self.serviceAccount}";
    # ...
  };

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = name;
    inherit labels;
    requires = [ self.deployment ];
    spec.selector = labels;
    spec.ports = [{ port = 80; }];
  };

  main = self.service;

} // clusterRoles // leaderElection
```

The dependency graph:

```
Service ──requires──→ Deployment ──${}──→ SA ←──${}── CRB ──${}──→ CR
  │                                       ↑
  main                              (inverse dep)
                                          │
                                    RoleBinding ──${}──→ Role
```

Everything deploys. No RBAC in `requires`. The `//` makes them visible; the
bindings' `${}` references handle the rest.

---

## Reference

All functions are available via `scope.rbac`:

```nix
inherit (scope.rbac)
  # Ref constructors
  group            # apiGroup -> [resourceNames] -> Group (dot-able + callable)
  core             # pre-populated "" group

  # Ref modifiers
  restrictTo       # [names] -> Ref -> Ref
  sub              # suffix -> Ref -> Ref (e.g., sub "status", sub "finalizers")

  # Intents: Ref | [Ref] -> [Rule]
  watch reconcile finalize own readWrite full emit watchAndFinalize
  allow            # [verbs] -> Ref | [Ref] -> [Rule]

  # Flatten
  grant            # [[Rule]] -> [Rule]

  # Role set builders
  mkClusterRoleSet # scope -> { subjects, labels?, roles } -> flat attrset
  mkRoleSet        # scope -> { subjects, labels?, roles } -> flat attrset
  ;
```
