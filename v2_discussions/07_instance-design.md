# cncf-nix: Instances Design Document

## Executive Summary

This document describes the developer experience for `cncf-nix`, a Nix-based Kubernetes resource manager. The central abstraction is the **instance** — a configured deployment of a package into a namespace. Users declare instances, point them at each other, and the system produces a fully-tracked, topo-sorted resource DAG with correct cross-namespace dependencies.

The design has three layers:

1. **Packages** — reusable K8s application definitions, maintained by the community or internal teams. Analogous to nixpkgs derivations.
2. **Instances** — a package deployed with specific config into a specific namespace. Analogous to a NixOS service module like `services.nginx.enable = true`.
3. **Clusters** — a set of instances and namespaces that constitute a deployable unit. Analogous to a NixOS system configuration.

The user operates almost entirely at the instance layer. They never call `mkResource` directly, never wire namespaces manually, and never think about dependency tracking.

---

## Part 1: The Instance DX

### What the user writes

```nix
# clusters/production.nix
{ cncf }:

cncf.buildCluster {

  namespaces = {
    kube-system = {};
    production = {
      resourceQuota.hard = {
        "requests.cpu" = "20";
        "limits.memory" = "64Gi";
      };
    };
    data = {
      resourceQuota.hard = {
        "requests.storage" = "500Gi";
      };
    };
  };

  instances = { config, ... }: {

    coredns = {
      package = cncf.packages.coredns;
      namespace = "kube-system";
    };

    postgres = {
      package = cncf.packages.postgresql;
      namespace = "data";
      config = {
        storage = "100Gi";
        replicas = 3;
      };
    };

    api = {
      package = cncf.packages.myApp;
      namespace = "production";
      config = {
        image = "myregistry.io/api:v2.1.0";
        replicas = 5;
        database = config.instances.postgres;
        dns = config.instances.coredns;
      };
    };
  };
}
```

That's the entire user-facing API. Everything else — namespace resources, dependency tracking, cross-namespace FQDN resolution, deploy ordering — is derived.

### Core design principles

**1. Instances are the unit of deployment, not resources.**

Users don't think in individual ConfigMaps and ServiceAccounts. They think "I need a postgres" and "I need my app talking to that postgres." The instance is the atom from the user's perspective. Resources are implementation details inside packages.

**2. Cross-references are between instances, not resources.**

When the user writes `config.instances.postgres`, they get the fully-evaluated postgres instance — its `main` resource's `ref`, `out`, `fqdn`, and the entire transitive closure. The package author uses these to build connection strings, env vars, etc. The user never needs to know which specific resource inside postgres is the "right one" to reference.

**3. Namespaces are declared, not constructed.**

The user writes `namespace = "production"` as a string. The system resolves it to the namespace resource declared in `namespaces = { ... }`, attaches policies, and injects it into every resource the instance creates. If the string doesn't match a declared namespace, evaluation fails with a clear error.

**4. Config is freeform but scoped.**

Each package defines what it expects in `config`. There's no global `values.yaml` — each instance has its own `config` attrset that only that package sees. Cross-instance references live in config too, as `config.instances.other`.

### The `instances` function

The `instances` attribute is a function, not an attrset. It receives `{ config, ... }` where `config.instances` is the final fixpoint of all evaluated instances. This is what enables cross-references:

```nix
instances = { config, ... }: {
  postgres = { ... };
  api = {
    config = {
      # This refers to the FINAL evaluated postgres, including
      # its .ref, .out, .fqdn, .closure — everything.
      database = config.instances.postgres;
    };
  };
};
```

The fixpoint evaluation order:

1. All instance definitions are collected.
2. For each instance, a `scope` is created from its namespace.
3. Each package function is called with `{ scope, config }` and wrapped in `lib.fix` to form the inner fixpoint (the package's self-referential parts).
4. The outer fixpoint ties all instances together so `config.instances.x` resolves to the final value of instance `x`.
5. Lazy evaluation means cycles are caught, and only referenced instances are forced.

### Instance-level overrides

For the common case where the user needs to tweak one resource inside a package:

```nix
instances = { config, ... }: {
  coredns = {
    package = cncf.packages.coredns;
    namespace = "kube-system";

    # Override individual parts — like overrideAttrs
    parts = self: super: {
      workload = self.scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${self.scope.instanceName}-coredns";
        spec = {
          replicas = 3;
          serviceName = self.service.ref;
          selector.matchLabels = super.workload.spec.selector.matchLabels;
          template = super.workload.spec.template // {
            # keep the same pod spec, just change the wrapping workload kind
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
    };
  };
};
```

The `parts` key is optional. When present, it's applied as an overlay on the package's inner fixpoint. `super` gives you the original parts, `self` gives you the final (overridden) parts.

### What the user gets back

```nix
cluster = import ./clusters/production.nix { inherit cncf; };

# Per-instance operations
cluster.instances.api.closure       # all resources needed, topo-sorted
cluster.instances.api.manifests     # YAML-ready attrsets for kubectl
cluster.instances.api.main          # the "public" resource (Service)
cluster.instances.api.ref           # shortcut to main.ref
cluster.instances.api.fqdn          # "api.production.svc.cluster.local"
cluster.instances.api.out           # main's outputs (e.g. { port = 8080; })

# Drill into parts
cluster.instances.api.deployment    # the Deployment resource
cluster.instances.api.configmap     # the ConfigMap resource

# Cluster-wide operations
cluster.closure                     # every resource in the cluster
cluster.manifests                   # everything, ready for kubectl apply
cluster.namespaces                  # all namespace resources

# Targeted deploy
cluster.deploy.api                  # just api + its deps (incl. postgres, coredns, namespaces)
cluster.deploy.postgres             # just postgres + its deps

# DAG queries
cluster.dag.closureOf "api"         # what does api need?
cluster.dag.dependentsOf "postgres" # what breaks if postgres changes?
cluster.dag.diff oldCluster         # what changed between two evaluations?
```

### Error messages

The system should produce clear errors at evaluation time, not deploy time:

```
error: namespace 'produktion' referenced by instance 'api' is not declared.
       Did you mean 'production'?
       Declared namespaces: data, kube-system, production, staging

error: instance 'api' references instance 'redis' via config.instances.redis,
       but no instance named 'redis' exists.
       Declared instances: api, coredns, postgres

error: package 'myApp' does not define a 'main' resource.
       Every package must set 'main' to indicate its primary interface.

error: cycle detected in instance dependencies:
       api → postgres → api
       Instance cross-references must form a DAG.
```

---

## Part 2: How `cncf.packages` Is Populated

### The package registry

`cncf.packages` is an attrset of package functions, built from a directory of package definitions. This is identical to how nixpkgs builds its top-level package set from `pkgs/` directories.

```
cncf-nix/
├── flake.nix
├── lib/
│   ├── k8s.nix          # core resource/ref/closure machinery
│   ├── eval.nix          # buildCluster, scope, instance evaluation
│   └── package.nix       # mkCncfPackage helper
├── packages/
│   ├── coredns/
│   │   ├── default.nix   # the package definition
│   │   └── README.md     # docs, example configs
│   ├── postgresql/
│   │   └── default.nix
│   ├── cert-manager/
│   │   └── default.nix
│   ├── nginx-ingress/
│   │   └── default.nix
│   └── ...
└── default.nix           # collects all packages
```

### The top-level collector

```nix
# default.nix / flake.nix output
{
  packages = let
    packageDirs = builtins.readDir ./packages;
    packageNames = builtins.attrNames
      (lib.filterAttrs (_: type: type == "directory") packageDirs);
  in lib.genAttrs packageNames (name:
    import ./packages/${name} { inherit lib k8s; }
  );
}
```

This produces `cncf.packages.coredns`, `cncf.packages.postgresql`, etc.

### Anatomy of a package: CoreDNS

```nix
# packages/coredns/default.nix
{ lib, k8s }:

# A package is a function: { scope, config } -> (self -> attrset)
#
# It does NOT know:
#   - what namespace it's in (scope handles that)
#   - what instance name it has (scope handles that)
#   - who references it (the DAG handles that)
#
# It DOES know:
#   - what resources it needs to create
#   - what config options it accepts
#   - what its public interface is (main + outputs)

{ scope, config }:

let
  cfg = {
    image = config.image
      or "registry.k8s.io/coredns/coredns:v1.11.1";
    replicas = config.replicas or 2;
    corefile = config.corefile or ''
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
    forwardTo = config.forwardTo or "/etc/resolv.conf";
    clusterDomain = config.clusterDomain or "cluster.local";
  };

  # Common labels for all resources in this package
  instanceLabels = {
    "app.kubernetes.io/name" = "coredns";
    "app.kubernetes.io/instance" = scope.instanceName;
    "app.kubernetes.io/managed-by" = "cncf-nix";
  };

  # Selector labels (subset used for pod selection)
  selectorLabels = {
    "k8s-app" = "kube-dns";
    "app.kubernetes.io/instance" = scope.instanceName;
  };

# The inner fixpoint — self-referential resource set
in self: {

  # ── Configuration Resources ──────────────────────────────────

  configmap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    data.Corefile = cfg.corefile;
  };

  # ── RBAC ─────────────────────────────────────────────────────
  #
  # ClusterRole and ClusterRoleBinding are cluster-scoped.
  # ServiceAccount is namespaced.
  # The SA requires its binding (inverted ref).

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
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

  clusterRoleBinding = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    spec = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = self.clusterRole.ref;
      };
      subjects = [{
        kind = "ServiceAccount";
        name = self.serviceAccount.ref;
        namespace = self.serviceAccount.namespace;
      }];
    };
  };

  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    requires = [ self.clusterRoleBinding ];
  };

  # ── Workload ─────────────────────────────────────────────────

  pdb = scope.mkResource {
    apiVersion = "policy/v1";
    kind = "PodDisruptionBudget";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    spec = {
      maxUnavailable = 1;
      selector.matchLabels = selectorLabels;
    };
  };

  workload = scope.mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    requires = [ self.pdb ];
    spec = {
      replicas = cfg.replicas;
      selector.matchLabels = selectorLabels;
      template = {
        metadata.labels = instanceLabels // selectorLabels;
        spec = {
          serviceAccountName = self.serviceAccount.ref;
          tolerations = [{
            key = "CriticalAddonsOnly";
            operator = "Exists";
          }];
          containers = [{
            name = "coredns";
            image = cfg.image;
            args = [ "-conf" "/etc/coredns/Corefile" ];
            resources = {
              requests = { cpu = "100m"; memory = "70Mi"; };
              limits = { memory = "170Mi"; };
            };
            ports = [
              { containerPort = 53; protocol = "UDP"; name = "dns"; }
              { containerPort = 53; protocol = "TCP"; name = "dns-tcp"; }
              { containerPort = 9153; protocol = "TCP"; name = "metrics"; }
            ];
            livenessProbe = {
              httpGet = { path = "/health"; port = 8080; };
              initialDelaySeconds = 60;
              timeoutSeconds = 5;
            };
            readinessProbe = {
              httpGet = { path = "/ready"; port = 8181; };
            };
            volumeMounts = [{
              name = "config-volume";
              mountPath = "/etc/coredns";
              readOnly = true;
            }];
          }];
          volumes = [{
            name = "config-volume";
            configMap = {
              name = self.configmap.ref;
              items = [{ key = "Corefile"; path = "Corefile"; }];
            };
          }];
        };
      };
    };
  };

  # ── Service ──────────────────────────────────────────────────

  service = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = "${scope.instanceName}-coredns";
    labels = instanceLabels;
    outputs = {
      port = 53;
      metricsPort = 9153;
    };
    spec = {
      selector = selectorLabels;
      clusterIP = config.clusterIP or null;
      ports = [
        { name = "dns"; port = 53; protocol = "UDP"; }
        { name = "dns-tcp"; port = 53; protocol = "TCP"; }
        { name = "metrics"; port = 9153; protocol = "TCP"; }
      ];
    };
  };

  # ── Public Interface ─────────────────────────────────────────

  main = self.service // {
    requires = [ self.workload ];
  };
};
```

### What makes a good package

A well-structured cncf-nix package follows these conventions:

**Uses `scope.instanceName` for all resource names.** This prevents collisions when two instances of the same package exist (e.g., `coredns` in `kube-system` and a second `coredns-custom` in `monitoring`).

**Accepts config through `config`, not hardcoded values.** Every tunable should have a default in `cfg`, overridable through the instance's `config` attrset.

**Uses `scope.mkResource` for namespaced resources and `scope.mkClusterResource` for cluster-scoped ones.** Never sets `namespace` manually.

**Declares `main` as the resource other instances interact with.** Typically a Service. The `main` resource `requires` the workload so that pulling on `main` gets everything.

**Annotates inverted dependencies with `requires`.** SA → binding, workload → PDB, workload → HPA.

**Does not reference other instances directly.** Cross-instance references come through `config` at the user level, not inside the package. A package that needs a database accepts `config.database` (an instance), not `config.databaseHost` (a string).

---

## Part 3: External Package Registries

### The problem

`cncf.packages` covers community-maintained, open-source K8s applications. But teams also need:

- **Internal packages** — proprietary microservices, internal tooling.
- **Vendor packages** — from a SaaS provider, partner, or internal platform team.
- **Forked packages** — a community package with local patches.

### Package registries as flake inputs

A package registry is just a flake that exports a `packages` attrset. Any flake can be a registry.

```nix
# The cncf-nix flake — the community registry
{
  description = "Community CNCF packages for cncf-nix";

  outputs = { self, nixpkgs }: let
    lib = nixpkgs.lib;
    k8s = import ./lib/k8s.nix { inherit lib; };
  in {
    # The package registry
    packages = import ./packages { inherit lib k8s; };

    # The evaluation machinery
    lib = import ./lib { inherit lib k8s; };
  };
}
```

```nix
# An internal registry — same shape, different packages
# git+ssh://git.internal.company.com/platform/k8s-packages
{
  description = "Internal K8s packages for Acme Corp";

  inputs.cncf-nix.url = "github:cncf-nix/cncf-nix";

  outputs = { self, cncf-nix, nixpkgs }: let
    inherit (cncf-nix) lib k8s;
  in {
    packages = {
      acme-api = import ./packages/acme-api { inherit lib k8s; };
      acme-worker = import ./packages/acme-worker { inherit lib k8s; };
      acme-gateway = import ./packages/acme-gateway { inherit lib k8s; };
      
      # An internal fork of a community package with custom patches
      postgresql = import ./packages/postgresql-acme { inherit lib k8s; };
    };
  };
}
```

### Consuming multiple registries

```nix
# flake.nix for a team's cluster
{
  inputs = {
    cncf-nix.url = "github:cncf-nix/cncf-nix";
    internal.url = "git+ssh://git.internal/platform/k8s-packages";
    ml-team.url = "git+ssh://git.internal/ml/k8s-packages";
  };

  outputs = { self, cncf-nix, internal, ml-team }: {
    cluster = import ./cluster.nix {
      cncf = cncf-nix;
      packages = {
        # Community packages
        inherit (cncf-nix.packages) coredns cert-manager nginx-ingress;

        # Internal packages
        inherit (internal.packages) acme-api acme-worker acme-gateway;

        # Use the internal fork of postgresql instead of community
        inherit (internal.packages) postgresql;

        # ML team's packages
        inherit (ml-team.packages) jupyter mlflow;
      };
    };
  };
}
```

```nix
# cluster.nix
{ cncf, packages }:

cncf.lib.buildCluster {
  namespaces = { ... };

  instances = { config, ... }: {
    coredns = {
      package = packages.coredns;           # from cncf-nix
      namespace = "kube-system";
    };

    postgres = {
      package = packages.postgresql;        # from internal (forked)
      namespace = "data";
      config.storage = "200Gi";
    };

    api = {
      package = packages.acme-api;          # from internal
      namespace = "production";
      config.database = config.instances.postgres;
    };

    jupyter = {
      package = packages.jupyter;           # from ml-team
      namespace = "ml";
      config.gpu = true;
    };
  };
}
```

### Registry composition helpers

For the common case where you want all packages from a registry plus selective overrides:

```nix
# In flake.nix
packages = cncf-nix.lib.mergeRegistries [
  cncf-nix.packages                        # base: all community packages
  internal.packages                         # override: internal packages win
  { postgresql = internal.packages.postgresql; }  # explicit cherry-pick
];
```

```nix
# lib/registry.nix
mergeRegistries = registries:
  lib.foldl' (acc: reg: acc // reg) {} registries;

# With conflict detection
mergeRegistriesStrict = registries:
  let
    merged = lib.foldl' (acc: reg:
      let conflicts = lib.intersectAttrs acc reg;
      in if conflicts != {}
         then throw "Package registry conflict: ${toString (builtins.attrNames conflicts)} exist in multiple registries. Use explicit selection."
         else acc // reg
    ) {} registries;
  in merged;
```

### Package versioning

Since registries are flake inputs, versioning is handled by the flake lock:

```nix
inputs = {
  # Pin to a specific release
  cncf-nix.url = "github:cncf-nix/cncf-nix/v0.3.0";

  # Pin to a commit
  internal.url = "git+ssh://git.internal/platform/k8s-packages?rev=abc123";

  # Follow main (updated with nix flake update)
  ml-team.url = "git+ssh://git.internal/ml/k8s-packages";
};
```

`nix flake update internal` bumps the internal packages. `nix flake lock --update-input cncf-nix` updates just the community packages. The lock file records exact commits, so builds are reproducible.

---

## Part 4: Multi-Team Collaboration and Cluster Merging

### The problem

In practice, a cluster isn't owned by one team. Platform engineering owns the infrastructure (ingress, DNS, monitoring, cert-manager). Application teams own their services. ML teams own their workloads. Everyone deploys to the same cluster but manages different pieces.

We need a model where:

- Teams work on their instances independently.
- The platform team controls namespaces, policies, and shared infrastructure.
- Changes to shared infrastructure are visible to consuming teams.
- The final cluster configuration is the merge of all teams' contributions.
- Conflicts are detected at evaluation time, not deploy time.

### Cluster fragments

Each team produces a **cluster fragment** — a partial cluster definition that declares its namespaces and instances. The platform team (or CI) merges fragments into the final cluster.

```nix
# teams/platform/fragment.nix
# Owned by: platform engineering
{ packages }:

{
  # Platform owns namespace definitions
  namespaces = {
    kube-system = {};
    ingress = {
      resourceQuota.hard."requests.cpu" = "4";
    };
    monitoring = {};
    cert-manager = {};
  };

  # Platform owns infrastructure instances
  instances = { config, ... }: {
    coredns = {
      package = packages.coredns;
      namespace = "kube-system";
    };

    nginx-ingress = {
      package = packages.nginx-ingress;
      namespace = "ingress";
    };

    cert-manager = {
      package = packages.cert-manager;
      namespace = "cert-manager";
      config.email = "platform@acme.com";
    };

    prometheus = {
      package = packages.prometheus;
      namespace = "monitoring";
    };
  };
}
```

```nix
# teams/backend/fragment.nix
# Owned by: backend team
{ packages, config }:

{
  # Backend team requests these namespaces.
  # They can set labels/annotations but NOT policies.
  # Policies come from the platform fragment (see merge rules below).
  namespaces = {
    production = {
      labels."team" = "backend";
    };
    staging = {
      labels."team" = "backend";
    };
  };

  instances = { config, ... }: {
    postgres = {
      package = packages.postgresql;
      namespace = "data";
      config = {
        storage = "100Gi";
        replicas = 3;
      };
    };

    api = {
      package = packages.acme-api;
      namespace = "production";
      config = {
        replicas = 5;
        image = "api:v2.1.0";
        database = config.instances.postgres;
        ingress = config.instances.nginx-ingress;
      };
    };

    api-staging = {
      package = packages.acme-api;
      namespace = "staging";
      config = {
        replicas = 1;
        image = "api:staging-latest";
        database = config.instances.postgres;
        ingress = config.instances.nginx-ingress;
      };
    };
  };
}
```

```nix
# teams/ml/fragment.nix
# Owned by: ML team
{ packages, config }:

{
  namespaces = {
    ml = {
      labels."team" = "ml";
    };
  };

  instances = { config, ... }: {
    jupyter = {
      package = packages.jupyter;
      namespace = "ml";
      config = {
        gpu = true;
        storage = "50Gi";
      };
    };

    mlflow = {
      package = packages.mlflow;
      namespace = "ml";
      config = {
        database = config.instances.postgres;   # shared postgres from backend team
      };
    };
  };
}
```

### The merge function

```nix
# lib/merge.nix

mergeFragments = { fragments, namespacePolicies ? {} }:
  let
    # ── 1. Merge namespaces ──────────────────────────────
    #
    # Multiple fragments can reference the same namespace.
    # Labels and annotations are merged (last wins for conflicts).
    # Policies (quotas, limits, netpols) come from namespacePolicies
    # or the fragment that has the deepest definition.
    
    allNamespaces = lib.foldl' (acc: fragment:
      lib.recursiveUpdate acc (fragment.namespaces or {})
    ) {} fragments;

    # Platform-defined policies override fragment-level ones
    namespacesWithPolicies = lib.mapAttrs (name: nsCfg:
      nsCfg // (namespacePolicies.${name} or {})
    ) allNamespaces;

    # ── 2. Check for instance name conflicts ─────────────

    allInstanceNames = lib.concatMap (fragment:
      let
        # Force the function to get the attrnames
        # (instances is a function, we need a dummy config to inspect names)
        dummyInstances = fragment.instances {
          config = {
            instances = {};  # placeholder — only used for name collection
          };
        };
      in builtins.attrNames dummyInstances
    ) fragments;

    duplicates = let
      counts = lib.foldl' (acc: name:
        acc // { ${name} = (acc.${name} or 0) + 1; }
      ) {} allInstanceNames;
    in lib.filterAttrs (_: count: count > 1) counts;

    # ── 3. Merge instance functions ──────────────────────

    mergedInstances = { config, ... }:
      let
        fragmentInstances = map (fragment:
          fragment.instances { inherit config; }
        ) fragments;
      in lib.foldl' (acc: instances: acc // instances) {} fragmentInstances;

  in
    assert duplicates == {} ||
      throw "Instance name conflicts across fragments: ${toString (builtins.attrNames duplicates)}. Use team prefixes or rename.";
    {
      namespaces = namespacesWithPolicies;
      instances = mergedInstances;
    };
```

### The flake that ties it together

```nix
# flake.nix — the cluster repo, owned by platform / SRE
{
  inputs = {
    cncf-nix.url = "github:cncf-nix/cncf-nix";
    internal.url = "git+ssh://git.internal/platform/k8s-packages";
    ml-pkgs.url = "git+ssh://git.internal/ml/k8s-packages";

    # Team fragments as separate flake inputs
    # Each team owns their fragment in their own repo
    team-platform.url = "git+ssh://git.internal/teams/platform/k8s-fragment";
    team-backend.url = "git+ssh://git.internal/teams/backend/k8s-fragment";
    team-ml.url = "git+ssh://git.internal/teams/ml/k8s-fragment";
  };

  outputs = { self, cncf-nix, internal, ml-pkgs,
              team-platform, team-backend, team-ml }:
    let
      packages = cncf-nix.lib.mergeRegistries [
        cncf-nix.packages
        internal.packages
        ml-pkgs.packages
      ];

      fragments = [
        (team-platform.fragment { inherit packages; })
        (team-backend.fragment { inherit packages; })
        (team-ml.fragment { inherit packages; })
      ];

      # Platform team controls policies for all namespaces
      namespacePolicies = {
        production = {
          resourceQuota.hard = {
            "requests.cpu" = "20";
            "limits.memory" = "64Gi";
          };
          networkPolicies = [{ /* ... */ }];
        };
        data = {
          resourceQuota.hard."requests.storage" = "500Gi";
        };
      };

      clusterConfig = cncf-nix.lib.mergeFragments {
        inherit fragments namespacePolicies;
      };

    in {
      # ── The cluster ────────────────────────────────────
      cluster = cncf-nix.lib.buildCluster clusterConfig;

      # ── CI/CD outputs ──────────────────────────────────

      # Full cluster manifests
      manifests = self.cluster.manifests;

      # Per-team deploy targets
      deploy = {
        platform = self.cluster.deployGroup [
          "coredns" "nginx-ingress" "cert-manager" "prometheus"
        ];
        backend = self.cluster.deployGroup [
          "postgres" "api" "api-staging"
        ];
        ml = self.cluster.deployGroup [
          "jupyter" "mlflow"
        ];
      };

      # Diff against the running cluster
      # nix run .#diff
      apps.diff = cncf-nix.lib.mkDiffApp self.cluster;

      # Validation
      # nix run .#validate
      apps.validate = cncf-nix.lib.mkValidateApp self.cluster;
    };
}
```

### What a team's fragment flake looks like

```nix
# git+ssh://git.internal/teams/backend/k8s-fragment/flake.nix
{
  description = "Backend team's K8s fragment";

  # No inputs needed — packages come from the caller
  outputs = { self }: {
    # The fragment is a function that takes { packages }
    fragment = { packages }: import ./fragment.nix { inherit packages; };
  };
}
```

This is intentionally minimal. The team's repo contains `fragment.nix` and nothing else K8s-related. They don't need `cncf-nix` as an input — the platform flake provides everything. This keeps team repos lightweight and decoupled.

### The alternative: monorepo layout

Not every org uses separate repos per team. For a monorepo:

```
cluster-repo/
├── flake.nix
├── packages/            # internal packages
│   ├── acme-api/
│   └── acme-worker/
├── teams/
│   ├── platform/
│   │   └── fragment.nix
│   ├── backend/
│   │   └── fragment.nix
│   └── ml/
│       └── fragment.nix
├── policies/
│   └── namespaces.nix   # platform-owned namespace policies
└── clusters/
    ├── production.nix   # production cluster assembly
    └── staging.nix      # staging cluster assembly
```

```nix
# clusters/production.nix
{ cncf, packages }:

let
  fragments = [
    (import ../teams/platform/fragment.nix { inherit packages; })
    (import ../teams/backend/fragment.nix { inherit packages; })
    (import ../teams/ml/fragment.nix { inherit packages; })
  ];

  namespacePolicies = import ../policies/namespaces.nix;

in cncf.lib.buildCluster (
  cncf.lib.mergeFragments { inherit fragments namespacePolicies; }
);
```

CODEOWNERS enforces team boundaries:

```
# CODEOWNERS
/teams/platform/     @platform-team
/teams/backend/      @backend-team
/teams/ml/           @ml-team
/policies/           @platform-team    # only platform can change policies
/clusters/           @platform-team    # only platform can change assembly
/packages/acme-api/  @backend-team
```

### Merge rules and conflict resolution

The merge follows these rules, ordered by priority:

**Namespaces:**
- Multiple fragments can declare the same namespace.
- Labels and annotations are merged with `lib.recursiveUpdate` (last fragment wins on key conflicts).
- Policies from `namespacePolicies` (platform-owned) always override fragment-level policy declarations. This ensures the platform team controls security and resource boundaries even if a team declares a namespace with different quotas.

**Instances:**
- Instance names must be unique across all fragments. A conflict is an evaluation error.
- Convention: prefix with team name if ambiguity is likely (`backend-postgres` vs `ml-postgres`).
- Cross-fragment instance references work through `config.instances.*` — the fixpoint spans all fragments.

**Packages:**
- No merging at the package level — the consuming flake explicitly selects which registry each package comes from. Conflicts are resolved by the person assembling the registries.

### CI/CD integration

The flake outputs are designed for CI pipelines:

```yaml
# .github/workflows/deploy.yaml
# Triggered by changes to a team's fragment

jobs:
  validate:
    steps:
      - run: nix run .#validate
        # Checks: all refs resolve, no cycles, no namespace conflicts,
        # all packages define main, all namespaces are declared

  diff:
    steps:
      - run: nix run .#diff
        # Shows: which resources changed, which instances are affected,
        # the topo-sorted deploy order

  deploy-backend:
    needs: [validate, diff]
    if: contains(github.event.paths, 'teams/backend/')
    steps:
      - run: nix eval .#deploy.backend.manifests | kubectl apply -f -
        # Only deploys backend instances + their transitive deps.
        # If postgres changed, it's included. If coredns didn't, it's not.
```

### The `deployGroup` helper

```nix
# lib/eval.nix — addition to buildCluster

deployGroup = instanceNames:
  let
    instances = map (name:
      evaluatedInstances.${name}
        or (throw "deployGroup: instance '${name}' not found")
    ) instanceNames;

    # Merge all closures, deduplicate
    allResources = lib.unique (
      lib.concatMap (inst: inst.closure) instances
    );

    # Topo-sort the merged closure
    sorted = topoSort allResources;

  in {
    resources = sorted;
    manifests = map (r: r.manifest) sorted;
    instances = instanceNames;

    # What's in this deploy group's closure that ISN'T
    # in the instance list? (transitive deps from other teams)
    externalDeps = lib.filter (r:
      !(builtins.any (name:
        builtins.any (ir: ir.name == r.name && ir.namespace == r.namespace)
          evaluatedInstances.${name}.closure
      ) instanceNames)
    ) sorted;
  };
```

This lets a team see exactly what their deploy touches, including resources owned by other teams that they transitively depend on.

---

## Part 5: Complete API Reference

### `buildCluster`

```nix
buildCluster {
  namespaces = { <name> = { <namespace-config> }; ... };
  instances = { config, ... }: { <name> = { <instance-config> }; ... };
}
```

Returns:

| Attribute | Type | Description |
|---|---|---|
| `instances.<name>` | Instance | Fully evaluated instance with all parts accessible |
| `instances.<name>.main` | Resource | The public-facing resource |
| `instances.<name>.ref` | Ref | Shortcut to `main.ref` |
| `instances.<name>.out` | AttrSet of Refs | Shortcut to `main.out` |
| `instances.<name>.fqdn` | Ref | Cross-namespace DNS name |
| `instances.<name>.closure` | [Resource] | All resources needed, topo-sorted |
| `instances.<name>.manifests` | [AttrSet] | YAML-ready manifests for closure |
| `instances.<name>.<part>` | Resource | Direct access to any package part |
| `namespaces.<name>` | Namespace Resource | The namespace with policies |
| `closure` | [Resource] | Every resource in the cluster, topo-sorted |
| `manifests` | [AttrSet] | All manifests |
| `deploy.<name>` | Deploy Target | Per-instance deploy with closure |
| `deployGroup [names]` | Deploy Target | Multi-instance deploy with merged closure |
| `dag.closureOf name` | [Resource] | Closure of a specific instance |
| `dag.dependentsOf name` | { instances } | Instances affected by changes to `name` |

### Instance config

```nix
{
  package = <package function>;     # required
  namespace = "<namespace name>";   # required, must be in namespaces
  config = { ... };                 # optional, freeform, passed to package
  parts = self: super: { ... };     # optional, override individual resources
}
```

### Namespace config

```nix
{
  labels = { ... };                 # optional
  annotations = { ... };            # optional
  resourceQuota = { hard = { ... }; };  # optional
  limitRange = { limits = [{ ... }]; }; # optional
  networkPolicies = [{ ... }];      # optional
}
```

### Package signature

```nix
# Every package is:
{ scope, config }:    # arguments injected by buildCluster
  self:               # inner fixpoint
    {
      <part-name> = scope.mkResource { ... };   # one or more resources
      main = self.<some-part>;                   # required: public interface
    }
```

### Scope API

| Attribute | Description |
|---|---|
| `scope.instanceName` | The unique instance name from the cluster config |
| `scope.namespace` | The namespace resource (auto-injected into mkResource) |
| `scope.mkResource { ... }` | Create a namespaced resource |
| `scope.mkClusterResource { ... }` | Create a cluster-scoped resource |
| `scope.str [ parts ]` | Build a tracked string with dependency tracking |
| `scope.clusterScoped` | The cluster-scope sentinel |
