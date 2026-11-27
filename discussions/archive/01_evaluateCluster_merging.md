# `evaluateCluster`: Merging Multiple Cluster Definitions

## Working Document -- March 2026

**Status:** Design exploration (not yet implemented)
**Context:** v2 architecture -- raw Nix, no module system, dual fixpoints

---

## 1. The Problem

The v1 design has a single `mkCluster` call that takes one monolithic cluster definition. In practice, multiple teams contribute to a cluster:

- **Platform team**: namespaces, network policies, cert-manager, ingress-nginx, monitoring stack
- **Backend team**: API services, databases, caches
- **Frontend team**: web apps, CDN config, BFF services
- **Data team**: analytics pipelines, data stores

Today these teams would all edit the same file, or use `//` to manually merge their configs. Neither scales. We need `evaluateCluster` to accept multiple independent cluster definitions and merge them before the outer fixpoint runs.

The key constraint: merging must happen **before** `lib.fix`, because the fixpoint needs a complete picture of all instances to do dependency injection (doc 04) and auto-install (doc 05). You cannot run separate fixpoints per team and merge after -- cross-team dependencies would break.

---

## 2. What a ClusterDefinition Contains

From the existing design (docs 02, 04, 06), a cluster definition produces:

```nix
{
  namespaces = {
    data = { resourceQuota = ...; networkPolicies = [...]; };
    backend = {};
  };

  instances = {
    postgres = { package = "postgres"; namespace = "data"; storage = "100Gi"; };
    api      = { package = "api";      namespace = "backend"; image = "api:v1"; };
  };

  # Optional
  overlays = [ (self: super: { ... }) ];
  defaults = { replicas = 1; };
  cluster  = { labels = { "team" = "platform"; }; autoInstall = false; };
}
```

The question is: what form does each team's contribution take, and how do they combine?

---

## 3. Three Architectural Approaches

### Approach A: Plain Attrsets with Merge Rules

Each team provides a plain attrset. `evaluateCluster` merges them with well-defined rules.

#### Team Files

```nix
# teams/platform.nix
{
  namespaces.platform = {
    networkPolicies = [{ /* ... */ }];
  };
  namespaces.monitoring = {};

  instances.cert-manager = { namespace = "platform"; };
  instances.ingress-nginx = { namespace = "platform"; };
  instances.prometheus = { namespace = "monitoring"; };
  instances.grafana = { namespace = "monitoring"; };

  cluster.labels."managed-by" = "kixpkgs";
}
```

```nix
# teams/backend.nix
{
  namespaces.backend = {};
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };

  instances.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    replicas = 3;
  };
  instances.postgres = {
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };
  instances.backend-cache = {
    package = "valkey";
    namespace = "backend";
  };
}
```

```nix
# teams/frontend.nix
{
  namespaces.frontend = {};

  instances.web-app = {
    namespace = "frontend";
    image = "webapp:v2.1.0";
    replicas = 3;
  };
}
```

#### evaluateCluster

```nix
evaluateCluster = clusterDefinitions:
  let
    merged = mergeClusterDefinitions clusterDefinitions;
    # merged is now a single { namespaces, instances, overlays, defaults, cluster }
  in buildCluster merged;
```

#### Merge Rules

```nix
mergeClusterDefinitions = definitions:
  let
    # Instances: error on collision (two teams define same instance name)
    allInstances = foldl' (acc: def:
      let
        collisions = intersectAttrs acc (def.instances or {});
      in
        if collisions != {} then
          throw "Instance name collision: ${toString (attrNames collisions)} defined in multiple cluster definitions"
        else acc // (def.instances or {})
    ) {} definitions;

    # Namespaces: deep merge (two teams can contribute to the same namespace)
    allNamespaces = foldl' (acc: def:
      lib.recursiveUpdate acc (def.namespaces or {})
    ) {} definitions;

    # Overlays: concatenate (order = definition order)
    allOverlays = concatMap (def: def.overlays or []) definitions;

    # Cluster-level config: deep merge
    clusterConfig = foldl' (acc: def:
      lib.recursiveUpdate acc (def.cluster or {})
    ) {} definitions;

    # Defaults: deep merge (later wins)
    allDefaults = foldl' (acc: def:
      lib.recursiveUpdate acc (def.defaults or {})
    ) {} definitions;

  in {
    namespaces = allNamespaces;
    instances = allInstances;
    overlays = allOverlays;
    cluster = clusterConfig;
    defaults = allDefaults;
  };
```

#### Usage

```nix
# cluster.nix
let
  kix = import ./kixpkgs;
in
  kix.evaluateCluster [
    (import ./teams/platform.nix)
    (import ./teams/backend.nix)
    (import ./teams/frontend.nix)
  ]
```

#### Tradeoffs

**Pros:**
- Dead simple mental model: each team writes a plain attrset, no functions, no `self`/`super`
- Instance collisions are hard errors -- no silent overrides
- Namespace merging is intuitive (platform team sets policies, app teams add services to the same namespace)
- Team files are completely independent -- team A doesn't import or reference team B
- Easy to test in isolation: each team's attrset is just data

**Cons:**
- No way for one team to intentionally modify another team's instance (e.g., "I want to add a sidecar to the api deployment")
- Namespace deep merge has edge cases: what if platform sets `networkPolicies = [policyA]` and backend sets `networkPolicies = [policyB]`? `recursiveUpdate` replaces lists, so backend wins. Need list-specific merge logic.
- No ordering semantics -- if two teams set the same cluster label to different values, the "winner" depends on merge function implementation
- Overlays are the only escape hatch for cross-team modifications, and their ordering is tied to the definition list order

**The list merge problem is critical.** `lib.recursiveUpdate` replaces lists wholesale. For network policies, resource quotas, and similar list/set-valued fields, we need smarter merging:

```nix
# Option 1: Use attrsets instead of lists for merge-friendly data
namespaces.data.networkPolicies.backend-ingress = { /* ... */ };
namespaces.data.networkPolicies.monitoring-ingress = { /* ... */ };
# Now two teams can contribute policies without collision

# Option 2: Custom merge that concatenates lists
mergeNamespaces = a: b:
  lib.recursiveUpdate a b // {
    networkPolicies = (a.networkPolicies or []) ++ (b.networkPolicies or []);
    # similar for other list-valued fields
  };
```

Option 1 (named attrsets instead of lists) is better because it makes individual policies addressable and overridable. This is the same insight that drove NixOS away from list-typed options toward attrset-typed ones.

---

### Approach B: Overlay-Style Functions (self: super:)

Each team's cluster definition is a function that receives the accumulated state and can extend or override it. Identical to nixpkgs overlays.

#### Team Files

```nix
# teams/platform.nix
# An overlay-style cluster definition
self: super: {
  namespaces = (super.namespaces or {}) // {
    platform = { networkPolicies.default = { /* ... */ }; };
    monitoring = {};
  };

  instances = (super.instances or {}) // {
    cert-manager = { namespace = "platform"; };
    ingress-nginx = { namespace = "platform"; };
    prometheus = { namespace = "monitoring"; };
  };
}
```

```nix
# teams/backend.nix
self: super: {
  namespaces = (super.namespaces or {}) // {
    backend = {};
    data = (super.namespaces.data or {}) // {
      resourceQuota.hard."requests.storage" = "500Gi";
    };
  };

  instances = (super.instances or {}) // {
    api = { namespace = "backend"; image = "api:v1.5.0"; };
    postgres = { namespace = "data"; storage = "100Gi"; };
  };
}
```

```nix
# teams/frontend.nix -- can reference other teams' instances via self
self: super: {
  namespaces = (super.namespaces or {}) // {
    frontend = {};
  };

  instances = (super.instances or {}) // {
    web-app = {
      namespace = "frontend";
      image = "webapp:v2.1.0";
      replicas = 3;
    };
  };
}
```

#### evaluateCluster

```nix
evaluateCluster = clusterDefinitions:
  let
    # Apply overlays left-to-right, just like nixpkgs
    composed = lib.foldl' lib.composeExtensions
      (_: _: {})  # empty base
      clusterDefinitions;

    # The cluster-level fixpoint resolves self-references
    clusterSpec = lib.fix composed;
  in buildCluster clusterSpec;
```

Wait -- this introduces a **third fixpoint** (cluster-spec level), in addition to the inner (package) and outer (instances) fixpoints. Let me think about whether this is necessary or if it conflates concerns.

Actually, the `self` here is the merged cluster spec, not the instance fixpoint. This is a composition-time fixpoint that resolves during merging, before the outer fixpoint (instance-level `lib.fix`) runs. The purpose of `self` here is to let one overlay reference the final merged state -- e.g., a monitoring overlay that needs to enumerate all instances.

#### Tradeoffs

**Pros:**
- Familiar pattern for anyone who knows nixpkgs overlays
- One team CAN intentionally modify another team's instances (the "add a sidecar" case)
- `super` gives you explicit access to what came before, so overrides are intentional
- Ordering is explicit: list position = priority
- `self` allows forward references: a monitoring overlay can reference `self.instances` to discover all services

**Cons:**
- Teams are NOT independent -- they must know about the overlay pattern, handle `super.namespaces or {}` defensively, and understand composition order
- Introduces a third fixpoint, adding conceptual complexity
- The `self` in overlay-style composition is the cluster SPEC (namespaces + instances config), not the evaluated instances. Cross-team dependency wiring still happens in the outer fixpoint. This means `self.instances.postgres` gives you the CONFIG attrset, not the evaluated package with `.ref` and `.fqdn`. This is a footgun.
- Silent overrides: if backend team does `instances = super.instances // { postgres = ... }` and data team also defines postgres, the later overlay wins silently. The collision detection from Approach A is lost.
- Every team file becomes a function, not plain data. Harder to lint, validate, or generate.

**The third-fixpoint concern** deserves elaboration. The system already has:
1. Inner fixpoint: resources within a package (`lib.fix (self: { deployment = ...; service = ...; })`)
2. Outer fixpoint: evaluated packages within a cluster (`lib.fix (self: { postgres = ...; api = ...; })`)

Adding:
3. Spec fixpoint: cluster definitions merging (`lib.fix (composed-overlays)`)

This spec fixpoint produces the input to the outer fixpoint. The chain is: spec fixpoint -> buildCluster -> outer fixpoint -> (for each package) inner fixpoint. Three layers of `lib.fix`. Each is conceptually clean, but the mental model cost is real.

---

### Approach C: Hybrid -- Plain Attrsets + Separate Overlays

Each team provides a plain attrset (like Approach A). Cross-team modifications are handled by a separate list of overlays that run AFTER merging but BEFORE the outer fixpoint.

#### Team Files

Same as Approach A -- plain attrsets.

#### evaluateCluster

```nix
evaluateCluster = {
  # Plain attrsets from teams -- merged with collision detection
  clusterDefinitions,
  # Overlays for cross-team modifications -- explicit and ordered
  overlays ? [],
}:
  let
    # Step 1: Merge plain definitions (error on instance collision)
    base = mergeClusterDefinitions clusterDefinitions;

    # Step 2: Apply overlays to the merged base
    # These overlays operate on the merged cluster spec.
    # They CAN modify other teams' instances.
    withOverlays = foldl' (acc: overlay: overlay acc) base overlays;

    # Step 3: Feed into the outer fixpoint
  in buildCluster withOverlays;
```

#### Overlays Are Separate and Explicit

```nix
# overlays/prod-hardening.nix
# This is NOT a team definition -- it's a cross-cutting overlay.
base: base // {
  instances = base.instances // {
    postgres = base.instances.postgres // {
      storage = "500Gi";
      backup.enabled = true;
    };
  };
  namespaces = lib.recursiveUpdate base.namespaces {
    data.networkPolicies.strict-ingress = { /* ... */ };
  };
}
```

#### Usage

```nix
kix.evaluateCluster {
  clusterDefinitions = [
    (import ./teams/platform.nix)
    (import ./teams/backend.nix)
    (import ./teams/frontend.nix)
  ];
  overlays = [
    (import ./overlays/prod-hardening.nix)
    (import ./overlays/add-monitoring-sidecars.nix)
  ];
}
```

#### Tradeoffs

**Pros:**
- Team definitions stay simple (plain data, collision-safe)
- Cross-team modifications are explicit and separate -- you can see all "things that modify other teams' stuff" in the overlays list
- Clear separation of concerns: teams declare, overlays modify
- Overlays here are simple functions (`base -> base'`), not fixpoint overlays (`self: super:`). No third fixpoint needed.
- Easy to audit: "what overlays touch team X's instances?" is answerable by reading the overlays directory

**Cons:**
- Two concepts: definitions and overlays. Users must understand when to use which.
- Overlays here are `base -> base'` (simple transforms), not `self: super:` (fixpoint overlays). This means an overlay can't reference the final state -- only what it receives. If overlay A adds an instance and overlay B wants to reference it, B must come after A in the list, and B sees A's output as its input. This is simpler than fixpoint overlays but less powerful.
- The overlays operate on the cluster spec (config data), not on evaluated instances. Same limitation as Approach B's `self`.

---

## 4. Detailed Merge Semantics

Regardless of which approach we choose, the merge rules need to be precise. Here's a complete specification:

### 4.1 Instance Merging

**Default: collision is an error.**

```
Team A: instances.postgres = { namespace = "data"; storage = "100Gi"; };
Team B: instances.postgres = { namespace = "data"; storage = "50Gi"; };
                                                              ^^^^^
Result: ERROR -- "Instance 'postgres' defined by both Team A and Team B"
```

This is the safe default. Two teams defining the same instance name probably means a coordination failure, not an intentional merge.

**Escape hatch: shared instances.**

Sometimes teams DO need to co-configure an instance. For example, a shared postgres where one team controls storage and another controls backup. This requires explicit opt-in:

```nix
# Team A
instances.postgres = {
  _shared = true;  # allow merging from other definitions
  namespace = "data";
  storage = "100Gi";
};

# Team B
instances.postgres = {
  _shared = true;
  backup.enabled = true;
  backup.schedule = "0 */6 * * *";
};

# Result after merge:
instances.postgres = {
  namespace = "data";
  storage = "100Gi";
  backup.enabled = true;
  backup.schedule = "0 */6 * * *";
};
```

If the same field is set by both teams (both set `storage`), that is still an error:

```
ERROR: Instance 'postgres' field 'storage' set by both Team A (100Gi) and Team B (50Gi).
       Use an overlay to resolve the conflict.
```

This gives us the safety of collision detection with an escape hatch for legitimate shared ownership.

**Alternative considered: ownership model.** Each instance has exactly one owner team, and only that team can define it. Other teams reference it but cannot modify it. This is cleaner but too rigid -- real infrastructure has shared ownership (platform team manages the postgres operator, app team configures the database).

### 4.2 Namespace Merging

**Default: deep merge with named sub-resources.**

Namespaces are naturally shared -- the platform team sets network policies, the app team sets resource quotas. Deep merge is the right default.

```nix
# Team A (platform)
namespaces.data = {
  networkPolicies.default-deny = { /* ... */ };
  labels."managed-by" = "platform";
};

# Team B (backend)
namespaces.data = {
  resourceQuota.hard."requests.storage" = "500Gi";
  labels."team" = "backend";
};

# Result:
namespaces.data = {
  networkPolicies.default-deny = { /* ... */ };
  resourceQuota.hard."requests.storage" = "500Gi";
  labels."managed-by" = "platform";
  labels."team" = "backend";
};
```

**Conflict on same leaf field is an error:**

```
Team A: namespaces.data.labels."team" = "platform";
Team B: namespaces.data.labels."team" = "backend";

Result: ERROR -- "Namespace 'data' field 'labels.team' set by both Team A and Team B"
```

**Important design decision: lists become named attrsets.**

Network policies, resource quotas, limit ranges -- these are naturally list-valued in Kubernetes. But for mergeable cluster definitions, they should be attrset-valued with user-chosen keys:

```nix
# Instead of:
networkPolicies = [ { name = "deny-all"; ... } ];

# Use:
networkPolicies.deny-all = { ... };
networkPolicies.allow-monitoring = { ... };
```

This makes policies individually addressable (an overlay can modify `networkPolicies.deny-all` without knowing about `allow-monitoring`) and naturally mergeable (two teams add different policies without collision).

### 4.3 Cluster-Level Config

Deep merge with leaf-conflict errors (same as namespaces).

### 4.4 Defaults

Deep merge. Later definitions override earlier ones for defaults specifically, because defaults are inherently about precedence -- a prod overlay's `defaults.replicas = 3` should override the base `defaults.replicas = 1`.

Actually, this is tricky. If definitions are unordered (as in Approach A), "later" is ambiguous. Options:
1. **Ordered list**: definitions list order determines precedence for defaults
2. **Conflict error**: same as instances -- two teams setting the same default is an error
3. **Separate from definitions**: defaults are not part of team definitions at all, they're a cluster-level concern

Option 3 is cleanest:

```nix
kix.evaluateCluster {
  clusterDefinitions = [ ... ];
  defaults = { replicas = 1; };  # cluster-wide, not per-team
}
```

Teams should not set cluster-wide defaults -- that is the cluster operator's job.

### 4.5 Overlays

Concatenated in definition order. Overlays from team definitions run before overlays from the `evaluateCluster` call.

---

## 5. Relation to the Outer Fixpoint

The merged cluster spec feeds into `buildCluster`, which runs the outer fixpoint. Here is the complete evaluation chain:

```
clusterDefinitions (list of attrsets)
        |
        v
  mergeClusterDefinitions
        |
        v
  merged spec { namespaces, instances, overlays, defaults, cluster }
        |
        v
  apply overlays (simple transforms, not fixpoint)
        |
        v
  final spec
        |
        v
  buildCluster:
    1. Build namespace resources
    2. lib.fix (outer fixpoint):
       - For each instance config, kixCallPackage with dependency injection
       - Each package internally uses lib.fix (inner fixpoint)
    3. Apply cross-cutting modules
    4. Produce manifests
```

**The crucial insight: merging is NOT a fixpoint.** It is a simple fold over attrsets. The outer fixpoint runs on the RESULT of merging. This means:

- Team definitions cannot reference each other's evaluated packages (no `self.postgres.fqdn` in a team definition)
- Team definitions only produce CONFIG DATA (strings, numbers, attrsets), not evaluated resources
- All cross-package references happen in the outer fixpoint, which sees the complete merged picture
- This is exactly right: teams declare WHAT they want, the fixpoint resolves HOW it connects

If we used Approach B (overlay-style with `self`), the `self` would give access to the merged config, not to evaluated packages. This is confusing because users might expect `self.instances.postgres` to be the evaluated package. Making merging a plain fold avoids this confusion entirely.

---

## 6. Team Isolation

### What teams CAN do independently:
- Define instances in their own namespaces
- Configure namespace properties (policies, quotas) for namespaces they own
- Declare dependencies via package function arguments (resolved by the outer fixpoint)
- Add aliases to their instances for discoverability

### What teams CANNOT do without coordination:
- Define the same instance name (error)
- Set the same namespace leaf field (error)
- Modify another team's instances (requires an overlay, which lives outside team definitions)
- Control dependency resolution for other teams' packages

### The coordination boundary:

```
              TEAM-LOCAL                    REQUIRES COORDINATION
    +--------------------------+    +--------------------------------+
    | - Own instances           |    | - Shared instance names        |
    | - Own namespace config    |    | - Cross-team instance mods     |
    | - Own overlays (applied   |    | - Cluster-wide defaults        |
    |   to own instances only)  |    | - Global overlays              |
    +--------------------------+    +--------------------------------+
```

This boundary is enforced by the merge rules: collisions error, cross-team modifications require explicit overlays.

---

## 7. Full Worked Example

### Directory Structure

```
clusters/
  production.nix          # evaluateCluster call
  teams/
    platform.nix          # platform team's definitions
    backend.nix           # backend team's definitions
    frontend.nix          # frontend team's definitions
  overlays/
    prod-hardening.nix    # production-specific overrides
    monitoring.nix        # add monitoring to everything
```

### teams/platform.nix

```nix
{
  namespaces.platform = {
    networkPolicies.default-deny = {
      podSelector = {};
      policyTypes = [ "Ingress" "Egress" ];
      ingress = [];
      egress = [{ to = [{ namespaceSelector = {}; }]; }];
    };
    networkPolicies.allow-dns = {
      podSelector = {};
      policyTypes = [ "Egress" ];
      egress = [{ ports = [{ protocol = "UDP"; port = 53; }]; }];
    };
  };

  namespaces.monitoring = {};

  instances.cert-manager = { namespace = "platform"; };
  instances.ingress-nginx = { namespace = "platform"; };
  instances.prometheus = { namespace = "monitoring"; };
  instances.grafana = { namespace = "monitoring"; };

  cluster.labels."managed-by" = "kixpkgs";
}
```

### teams/backend.nix

```nix
{
  namespaces.backend = {};
  namespaces.data = {
    resourceQuota.hard."requests.storage" = "500Gi";
  };

  instances.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    replicas = 3;
  };

  instances.postgres = {
    namespace = "data";
    storage = "100Gi";
    version = "16";
  };

  instances.backend-cache = {
    package = "valkey";
    namespace = "backend";
    persistence = false;
  };

  instances.session-store = {
    package = "valkey";
    namespace = "data";
    aliases = [ "sessionStore" ];
    sentinel.enabled = true;
  };
}
```

### teams/frontend.nix

```nix
{
  namespaces.frontend = {};

  instances.web-app = {
    namespace = "frontend";
    image = "webapp:v2.1.0";
    replicas = 3;
  };
}
```

### overlays/prod-hardening.nix

```nix
# A simple transform: base -> modified base
base: base // {
  instances = base.instances // {
    postgres = base.instances.postgres // {
      storage = "500Gi";
      backup.enabled = true;
      backup.schedule = "0 */6 * * *";
    };
    api = base.instances.api // {
      replicas = 5;
    };
    web-app = base.instances.web-app // {
      replicas = 5;
    };
  };

  namespaces = lib.recursiveUpdate base.namespaces {
    data.networkPolicies.allow-backend = {
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."env/ns" = "backend"; }];
      }];
    };
    frontend.networkPolicies.allow-ingress = {
      podSelector = {};
      policyTypes = [ "Ingress" ];
      ingress = [{
        from = [{ namespaceSelector.matchLabels."app" = "ingress"; }];
      }];
    };
  };
}
```

### clusters/production.nix

```nix
let
  kix = import ../kixpkgs;
in
  kix.evaluateCluster {
    clusterDefinitions = [
      (import ./teams/platform.nix)
      (import ./teams/backend.nix)
      (import ./teams/frontend.nix)
    ];
    overlays = [
      (import ./overlays/prod-hardening.nix)
    ];
    defaults = {
      # cluster-wide defaults, not owned by any team
    };
    cluster = {
      labels."env" = "production";
      autoInstall = false;
    };
  }
```

### clusters/dev.nix

```nix
let
  kix = import ../kixpkgs;
in
  kix.evaluateCluster {
    clusterDefinitions = [
      (import ./teams/platform.nix)
      (import ./teams/backend.nix)
      (import ./teams/frontend.nix)
    ];
    # No prod-hardening overlay
    defaults = {
      replicas = 1;
    };
    cluster = {
      labels."env" = "dev";
      autoInstall = true;  # auto-install missing deps in dev
    };
  }
```

---

## 8. Implementation Sketch

### mergeClusterDefinitions

```nix
mergeClusterDefinitions = definitions:
  let
    # Helper: merge two attrsets, erroring on leaf conflicts
    mergeNoConflict = path: a: b:
      lib.zipAttrsWith (name: values:
        let fullPath = path ++ [ name ];
        in if length values == 1 then head values
           else if all isAttrs values then mergeNoConflict fullPath (elemAt values 0) (elemAt values 1)
           else throw "Conflict at ${concatStringsSep "." fullPath}: defined in multiple cluster definitions"
      ) [ a b ];

    # Instances: error on name collision (check before merge)
    mergeInstances = defs:
      let
        allKeys = concatMap (d: attrNames (d.instances or {})) defs;
        dupes = filter (k: length (filter (x: x == k) allKeys) > 1) (unique allKeys);
      in
        if dupes != [] then
          throw "Instance name collision: ${concatStringsSep ", " dupes}"
        else foldl' (acc: d: acc // (d.instances or {})) {} defs;

    # Namespaces: deep merge with conflict detection on leaves
    mergeNamespaces = defs:
      foldl' (acc: d:
        mergeNoConflict [ "namespaces" ] acc (d.namespaces or {})
      ) {} defs;

    # Overlays: concatenate
    mergeOverlays = concatMap (d: d.overlays or []) definitions;

    # Cluster config: deep merge with conflict detection
    mergeCluster = defs:
      foldl' (acc: d:
        mergeNoConflict [ "cluster" ] acc (d.cluster or {})
      ) {} defs;

  in {
    instances = mergeInstances definitions;
    namespaces = mergeNamespaces definitions;
    overlays = mergeOverlays;
    cluster = mergeCluster definitions;
  };
```

### evaluateCluster

```nix
evaluateCluster = {
  clusterDefinitions,
  overlays ? [],
  defaults ? {},
  cluster ? {},
}:
  let
    # Step 1: Merge team definitions
    merged = mergeClusterDefinitions clusterDefinitions;

    # Step 2: Merge in top-level cluster config
    withCluster = merged // {
      cluster = mergeNoConflict [ "cluster" ] merged.cluster cluster;
      defaults = defaults;  # top-level defaults, not from team defs
    };

    # Step 3: Apply definition-level overlays (from team defs)
    afterDefOverlays = foldl' (acc: overlay: overlay acc) withCluster merged.overlays;

    # Step 4: Apply top-level overlays
    afterOverlays = foldl' (acc: overlay: overlay acc) afterDefOverlays overlays;

    # Step 5: Apply defaults to instances
    withDefaults = afterOverlays // {
      instances = mapAttrs (_: inst:
        afterOverlays.defaults // inst  # instance values override defaults
      ) afterOverlays.instances;
    };

    # Step 6: Build the cluster (outer fixpoint + inner fixpoints)
  in buildCluster withDefaults;
```

---

## 9. Open Questions and Decision Points

### 9.1 Should team definitions support per-team overlays?

A team might want to apply an overlay that only affects their own instances. Two options:

**Option A: Team overlays in the definition.**
```nix
# teams/backend.nix
{
  instances.api = { ... };
  overlays = [
    (base: base // {
      instances.api = base.instances.api // { extraAnnotation = "..."; };
    })
  ];
}
```
Problem: the overlay runs on the MERGED spec, so it can see and modify other teams' instances. No isolation.

**Option B: No team-level overlays.** Teams only provide plain instance configs. If a team needs to compute one instance based on another, they do it in Nix before producing the attrset:

```nix
# teams/backend.nix
let
  apiImage = "api:v1.5.0";
in {
  instances.api = { image = apiImage; };
  instances.api-worker = { image = apiImage; role = "worker"; };
}
```

Option B is simpler and preserves team isolation. Team-level overlays that can see the whole cluster are a governance concern, not a technical one.

**Recommendation: No team-level overlays in v2. Use top-level overlays for cross-team modifications.**

### 9.2 Should `_shared` instances use deep merge or explicit field ownership?

Deep merge with conflict detection on leaves (as described in 4.1) is the simplest. But an explicit ownership model is more auditable:

```nix
instances.postgres = {
  _owners = {
    storage = "backend-team";
    backup = "platform-team";
  };
  # Only the declared owner can set each field
};
```

This is probably over-engineering for v2. Start with `_shared` + leaf-conflict detection. Add ownership if the pain materializes.

**Recommendation: Start without `_shared` at all. If two teams need to configure the same instance, use an overlay. Revisit `_shared` when there's a concrete pattern of teams co-owning instances.**

### 9.3 How do environments (dev/prod) interact with multi-team definitions?

The current design has the evaluateCluster call site choose which overlays and defaults to apply. This means environment differentiation is at the CLUSTER level, not the team level. A team cannot say "in dev, my api gets 1 replica" -- that's the cluster operator's job.

Is this the right boundary? In practice, teams often want to express dev/prod differences for their own services. Two options:

**Option A: Environment config is cluster-level only (current design).**
Teams provide base configs. The cluster file chooses overlays per environment.

**Option B: Team definitions are functions of environment.**
```nix
# teams/backend.nix
{ env }:
{
  instances.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    replicas = if env == "prod" then 5 else 1;
  };
}
```

Option A is purer (teams provide data, not logic), but Option B is pragmatic (teams know their own scaling requirements).

A middle ground: teams provide base configs with comments about recommended production values, and environment overlays implement them:

```nix
# teams/backend.nix
{
  instances.api = {
    namespace = "backend";
    image = "api:v1.5.0";
    replicas = 1;  # prod: 5
  };
}

# overlays/prod-scaling.nix -- maintained by cluster operator, informed by team recommendations
base: base // {
  instances = base.instances // {
    api = base.instances.api // { replicas = 5; };
  };
}
```

**Recommendation: Start with Option A. If every overlay is just "set replicas for each service," consider parameterized definitions (Option B) as a convenience.**

### 9.4 Validation: what errors should merging produce?

At minimum:
1. Instance name collision (unless `_shared`)
2. Namespace leaf-field collision
3. Cluster config leaf-field collision
4. Instance references a namespace that no definition declares (warning, not error -- namespace auto-creation from doc 04 handles this)
5. Overlay references an instance that doesn't exist in the merged base (runtime error from `base.instances.nonexistent`, which is fine)

Nice to have:
6. Typo detection: instance name close to an existing one (Levenshtein distance)
7. Orphan detection: namespace declared but no instances use it
8. Package existence: instance references a package name that's not in the registry

### 9.5 How does this interact with auto-install (doc 05)?

Auto-install creates instances that aren't in any team's definition. These auto-installed instances should:
- Not conflict with team-defined instances (auto-install is shadowed by explicit instances)
- Be visible in the evaluation output ("these instances were auto-installed")
- Be promotable: `evaluateCluster` output includes suggested team definition snippets

The interaction is clean because auto-install operates in the outer fixpoint (step 6 in evaluateCluster), AFTER merging is complete. The merged spec is the "explicit truth," and auto-install fills gaps.

---

## 10. Recommendation

**Use Approach C (Hybrid): plain attrsets from teams + separate overlays.**

Rationale:
1. **Team isolation is the primary goal.** Teams should be able to write their cluster definitions without importing or knowing about other teams' definitions. Plain attrsets achieve this perfectly.
2. **Collision detection prevents silent bugs.** Two teams accidentally defining the same instance name is caught immediately, not silently merged with one winning.
3. **Cross-team modifications are explicit.** Overlays are a separate, auditable mechanism. You can review all cross-team modifications by reading the overlays directory.
4. **No third fixpoint.** Merging is a simple fold, not a fixpoint. The system stays at two fixpoints (inner + outer), which is already the conceptual maximum for most users.
5. **Incremental complexity.** Teams start by writing plain attrsets. Only the cluster operator needs to understand overlays. Most teams never write an overlay.

The overlay model (Approach B) is more powerful but violates team isolation and adds conceptual complexity. It should remain available as an advanced escape hatch but not be the primary composition mechanism.

Start without `_shared` instances. Start without team-level overlays. Start without parameterized definitions. Add each when there's demonstrated need.

---

## 11. Comparison Summary

| Concern | A: Plain Attrsets | B: Overlay Functions | C: Hybrid (Recommended) |
|---|---|---|---|
| Team isolation | Full | None (self/super) | Full for definitions, explicit for overlays |
| Collision detection | Yes | No (silent override) | Yes for definitions, intentional for overlays |
| Cross-team modification | Not possible | Natural | Via separate overlays |
| Mental model | Simple (just data) | Complex (fixpoint) | Medium (data + transforms) |
| Number of fixpoints | 2 (inner + outer) | 3 (spec + inner + outer) | 2 (inner + outer) |
| Team file complexity | Plain attrset | Function (self: super:) | Plain attrset |
| Expressiveness | Low | High | Medium (covers 95% of cases) |
| Auditability | High | Low (any overlay can change anything) | High (overlays are separate and reviewable) |
