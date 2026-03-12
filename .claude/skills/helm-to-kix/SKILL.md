---
name: helm-to-kix
description: |
  Migrate a Helm chart to a kix fixpoint package. Use when asked to:
  - migrate/convert a Helm chart
  - create a new kix package
  - add a new chart to kixpkgs
  - port a Kubernetes deployment to Nix
---

# Helm-to-Kix Migration (Fixpoint Pattern)

Packages live in `pkgs-fp/<name>/default.nix`. Each is a self-referential resource set built with `k8s.mkPackage` (inner fixpoint) where resources reference each other via `self.*`.

## Architecture: Three Levels

```
Level 3: k8s.mkPackage (self-referential package), k8s.mkCluster (package composition)
Level 2: k8s.mkResource (resource with ref tracking + closure), k8s.withRequires
Level 1: k8s.mkRef, k8s.str, k8s.resolve, k8s.computeClosure (primitives)
```

## Package Structure

Every package file has this shape:

```nix
{ k8s, lib }:          # only two args

k8s.mkPackage
  (
    {
      # Package arguments with defaults (replaces Helm values.yaml)
      namespace ? "default",
      image ? { repository = "..."; tag = "..."; pullPolicy = "IfNotPresent"; },
      replicaCount ? 1,
      # ... all configurable values as ? defaulted args ...
      clusterLabels ? {},
      instance ? "release-name",
    }:
    self:              # the fixpoint — ALL resources visible here
    let
      # Derived values, labels, helpers
    in
    {
      # Resource definitions using k8s.mkResource
      configmap = k8s.mkResource { ... };
      workload = k8s.mkResource { ... };
      service = k8s.mkResource { ... };

      # main = the public interface (what consumers see)
      main = k8s.withRequires [ self.workload ] self.service;
    }
  )
  {
    # Default arguments (subset — typically just namespace)
    namespace = "default";
  }
```

## k8s.mkResource API

See [references/api.md](references/api.md) for complete field reference.

Key fields: `apiVersion`, `kind`, `name`, `namespace`, `labels`, `annotations`, `spec`, `data`, `stringData`, `rules`, `subjects`, `roleRef`, `webhooks`, `outputs`, `requires`, `extraDeps`, `extra`.

Each resource gets: `.ref` (name ref), `.out.<key>` (output refs), `.deps` (auto-tracked), `.closure` (transitive), `.manifest` (resolved attrset).

## Dependency Tracking

**Two directions:**

1. **deps (automatic)** — When resource A uses `self.configmap.ref` in its spec, the tree walker records configmap as a dep of A. No manual tracking needed.

2. **requires (manual, inverted)** — When resource A needs resource B, but B references A (not the other way around). Classic example: ServiceAccount requires its ClusterRoleBinding (the binding refs the SA, not vice versa).

```nix
# Automatic: workload.spec mentions configmap.ref -> dep tracked
workload = k8s.mkResource {
  spec.template.spec.volumes = [{
    configMap.name = self.configmap.ref;  # auto-tracked dep
  }];
};

# Inverted: SA needs binding, but binding refs SA
serviceAccount = k8s.mkResource {
  kind = "ServiceAccount";
  requires = [ self.clusterRoleBinding ];  # manual inverted dep
};
```

**The `main` resource** uses `k8s.withRequires` (NOT `//`) to add requires and recompute closure:

```nix
main = k8s.withRequires (
  [ self.workload ]
  # Conditional resources gated by args
  ++ lib.optional metricsEnabled self.metricsService
) self.service;
```

## Tracked Strings

When building values that reference multiple resources, use `k8s.str` instead of `${}` interpolation. Native interpolation calls `__toString` and loses ref tracking.

```nix
# BAD: loses dep tracking
value = "postgresql://${db.out.host}:${toString db.out.port}/mydb"

# GOOD: preserves dep tracking
value = k8s.str [ "postgresql://" db.out.host ":" db.out.port "/mydb" ]
```

## Label Convention

Every package follows the same label structure:

```nix
selectorLabels = {
  "app.kubernetes.io/instance" = instance;
  "app.kubernetes.io/name" = "<chart-name>";
};

allLabels = clusterLabels // selectorLabels // {
  "app.kubernetes.io/managed-by" = "kix";  # REQUIRED on every resource
};
```

For multi-component packages, use a `withComponent` helper:
```nix
withComponent = component: selectorLabels // { "app.kubernetes.io/component" = component; };
allLabelsWithComponent = component: allLabels // { "app.kubernetes.io/component" = component; };
```

**The `managed-by = "kix"` label is validated by cross-resource checks. Every resource must have it.**

## RBAC Pattern

RBAC follows the same pattern in every package:

```nix
clusterRole = k8s.mkResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRole";
  name = "<name>";
  namespace = null;  # cluster-scoped
  labels = allLabels;
  rules = [ ... ];
};

clusterRoleBinding = k8s.mkResource {
  apiVersion = "rbac.authorization.k8s.io/v1";
  kind = "ClusterRoleBinding";
  name = "<name>";
  namespace = null;  # cluster-scoped
  labels = allLabels;
  roleRef = {
    apiGroup = "rbac.authorization.k8s.io";
    kind = "ClusterRole";
    name = self.clusterRole.ref;  # auto-tracked
  };
  subjects = [{
    kind = "ServiceAccount";
    name = saName;             # self.serviceAccount.ref or "default"
    inherit namespace;
  }];
};

serviceAccount = k8s.mkResource {
  apiVersion = "v1";
  kind = "ServiceAccount";
  name = "<name>";
  inherit namespace;
  labels = allLabels;
  requires = [ self.clusterRoleBinding ];  # inverted dep
};
```

When `serviceAccount.create` is a configurable option:
```nix
saName = if serviceAccount.create then self.serviceAccount.ref else "default";
# Workload must explicitly require the binding when using "default" SA
# (since "default" is a plain string, no auto-tracking)
workload = k8s.mkResource {
  requires = [ self.clusterRoleBinding ]
    ++ lib.optional serviceAccount.create self.serviceAccount;
  ...
};
```

## Conditional Resources

Resources always exist in the fixpoint (no `mkIf`). Gate them via `requires`/`withRequires`:

```nix
# Resource is always defined, but only included in closure when referenced
pdb = k8s.mkResource { ... };
hpa = k8s.mkResource { ... };

# Gate inclusion via main's requires
main = k8s.withRequires (
  [ self.workload ]
  ++ lib.optional pdbEnabled self.pdb
  ++ lib.optional hpa.enabled self.hpa
) self.service;
```

## The `extra` Field

For top-level manifest fields that aren't part of the standard `spec`/`data`/`rules`/etc. Uses `lib.recursiveUpdate` (deep merge, won't clobber spec).

```nix
# StatefulSet volumeClaimTemplates (under spec but alongside resolved spec)
extra = { spec.volumeClaimTemplates = [ ... ]; };

# ServiceAccount automountServiceAccountToken (top-level field)
extra.automountServiceAccountToken = false;

# Conditional extra fields
extra = lib.optionalAttrs serviceAccount.automountServiceAccountToken {
  automountServiceAccountToken = true;
};
```

## Shell Scripts Pattern (Valkey-style)

Store scripts in `pkgs-fp/<name>/scripts/`. Two approaches:

```nix
# Direct read (no templating needed)
data."start-primary.sh" = builtins.readFile ./scripts/start-primary.sh;

# Templated with @PLACEHOLDER@ substitution
readScript = file:
  builtins.replaceStrings
    [ "@HEADLESS_SERVICE_FQDN@" "@FULLNAME@" ]
    [ headlessSvcFqdn fullname ]
    (builtins.readFile (./scripts + "/${file}"));

data."start-replica.sh" = readScript "start-replica.sh";
```

Use `@PLACEHOLDER@` tokens to avoid bash `${VAR}` escaping hell in Nix multiline strings.

## `outputs` Field

Expose named values as trackable refs for other resources:

```nix
service = k8s.mkResource {
  kind = "Service";
  outputs = { dnsPort = 53; metricsPort = 9153; };
  ...
};
# Other resources: self.service.out.dnsPort (tracked ref resolving to 53)
```

## Wiring Into the Flake

See [references/flake-wiring.md](references/flake-wiring.md) for step-by-step instructions.

## Migration Checklist

1. **Render Helm output**: `helm template <release> <chart> > reference.yaml` with various value combinations
2. **Create `pkgs-fp/<name>/default.nix`** with the package structure above
3. **Map values.yaml** to package arguments with `?` defaults
4. **Translate each template** to a `k8s.mkResource` call. Group related resources with comments
5. **Wire RBAC** using the standard pattern. Remember: SA requires binding, binding refs role
6. **Handle conditionals** via `requires` gating (not mkIf)
7. **Extract helpers** to `helpers.nix` if there's domain-specific logic (like CoreDNS Corefile builder)
8. **Define `main`** as `k8s.withRequires [...] self.<primary-service>`
9. **Add to flake.nix**: import, chartVariants entries (base + feature variants), cluster test assertions
10. **Validate**: `nix build .#<name>`, `nix flake check`, inspect YAML output

## Gotchas

- **`k8s.withRequires` not `//`**: Using `//` to add requires does NOT recompute the closure. Always use `k8s.withRequires`.
- **cluster-scoped resources**: Set `namespace = null` for ClusterRole, ClusterRoleBinding, etc.
- **`extra` for deep fields**: `spec.volumeClaimTemplates` goes in `extra`, not `spec`, because `extra` uses `recursiveUpdate` instead of shallow `//`.
- **Attribute override completeness**: `.override` replaces the ENTIRE argument, not merging. If overriding `sentinel`, provide ALL sentinel fields, not just the changed ones.
- **`builtins.readFile` paths**: Use `./scripts/foo.sh` (relative to package dir) or `(./scripts + "/${file}")` for dynamic names.
- **ConfigMap defaultMode**: Use decimal (493 = 0o755), not octal literals.
- **Webhook configs**: Use the `webhooks` field on mkResource (top-level, not under spec). apiVersion is `admissionregistration.k8s.io/v1`.
