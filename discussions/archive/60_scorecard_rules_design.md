# 60 — Scorecard Rules: Multi-Level Policy Evaluation

**Status:** Draft
**Related:** `25_package_meta_warnings.md` (existing diagnostic system), `37_di_derived_network_policies.md` (post-eval pass pattern), `business_discussions/11_idp_gap_analysis.md` (IDP gap analysis + Adam's practitioner feedback)

---

## Context

kix already has a diagnostic system (`meta.nix`): packages declare `assertions` and `warnings` as functions, the evaluator collects them, and failed assertions stop the build. Network policies (`netpol.nix`) demonstrate the post-eval pass pattern — a cluster-wide analysis that runs after the fixpoint and produces derived resources.

What's missing is a **structured policy framework** where rules are:
- Declaratively defined with configurable severity
- Selectively enforced by scope (namespace, team, environment)
- Evaluated at different levels of the compilation pipeline
- Reported in a structured format (for CI, compliance, and tooling)

Adam's feedback from the gap analysis is direct: "Policy selection is buried. Being able to say 'enforce resource limits on production namespaces but not dev' is table stakes." Spacelift treats policy attachment as core, not nice-to-have.

---

## Problem

Three gaps in the current system:

1. **No aggregate policy view.** Individual packages have assertions/warnings, but there's no "run 15 production readiness checks across all packages and give me a report." The VP Eng asks "are we meeting our standards?" and there's no answer.

2. **No selective enforcement.** A check is either a package assertion (hard error) or a warning (trace output). There's no "error in production, warning in dev" or "this policy applies to backend-team namespaces only."

3. **No standard policy library.** Each package reinvents its own checks. There's no shared "has resource limits" check that applies to all Deployments across the cluster.

---

## Design

### The rule

A rule is a named, typed check with metadata and a predicate function. Rules live in the cluster definition (platform-level) or in a shared library (reusable across clusters).

```nix
{
  # A single rule declaration
  rules.security.nonRoot = {
    description = "All containers must run as non-root";
    level = "manifest";  # when this rule evaluates (see Evaluation Levels)
    severity = "error";  # default severity — overridable per scope

    # The check function. Signature depends on `level`.
    # Returns a list of findings (empty = pass).
    check = { resource, ... }:
      let
        containers = resource.spec.template.spec.containers or [ ];
        failing = builtins.filter
          (c: !(c.securityContext.runAsNonRoot or false))
          containers;
      in
      map (c: {
        message = "container '${c.name}' does not set runAsNonRoot";
        # Optional: structured location for SARIF export
        container = c.name;
      }) failing;
  };
}
```

### Rule fields

| Field | Type | Required | Description |
|---|---|---|---|
| `description` | string | yes | Human-readable explanation. Shows in reports and SARIF. |
| `level` | enum | yes | When the rule evaluates: `"manifest"`, `"package"`, `"namespace"`, `"cluster"` |
| `severity` | enum | yes | Default severity: `"error"` (blocks build), `"warning"` (reported, non-blocking), `"info"` (audit only) |
| `check` | function | yes | Predicate function. Signature varies by level. Returns `[]` for pass, list of findings for fail. |
| `tags` | list of string | no | Categories for grouping: `["security"]`, `["reliability", "ha"]`. Used for filtering and reporting. |
| `appliesTo` | function or null | no | Filter predicate — which resources/packages this rule targets. `null` = applies to all. |

### Evaluation levels

This is the key design decision. Rules evaluate at four levels, each with increasing scope and a different function signature:

#### Level: `manifest`

**When:** During `mkResource` or immediately after resource construction.
**Scope:** Individual K8s resource.
**Signature:** `{ resource, instanceName, namespaceName, ... } -> [ findings ]`
**What it sees:** The raw manifest (all fields), the instance and namespace context.
**Examples:** Resource limits, security context, probes, image tags, labels.

```nix
rules.reliability.hasProbes = {
  description = "Workloads must have liveness and readiness probes";
  level = "manifest";
  severity = "warning";
  appliesTo = { resource, ... }: builtins.elem resource.kind [ "Deployment" "StatefulSet" "DaemonSet" ];
  check = { resource, ... }:
    let
      containers = resource.spec.template.spec.containers or [ ];
      missingLiveness = builtins.filter (c: !(c ? livenessProbe)) containers;
      missingReadiness = builtins.filter (c: !(c ? readinessProbe)) containers;
    in
    (map (c: { message = "container '${c.name}' has no livenessProbe"; container = c.name; }) missingLiveness)
    ++ (map (c: { message = "container '${c.name}' has no readinessProbe"; container = c.name; }) missingReadiness);
};
```

#### Level: `package`

**When:** After the package fixpoint resolves (all parts are built, deps are resolved).
**Scope:** One package instance — all its resources, its resolved deps, its config.
**Signature:** `{ resources, parts, config, deps, meta, instanceName, namespaceName, ... } -> [ findings ]`
**What it sees:** The full resource set for this package, the evaluated config, resolved dependencies.
**Examples:** "Deployment with replicas > 1 must have a PDB", "stateful packages must have a backup dep", "owner must be set."

```nix
rules.governance.hasOwner = {
  description = "Every package must declare an owner";
  level = "package";
  severity = "warning";
  check = { meta, instanceName, ... }:
    if (meta.owner or null) == null
    then [ { message = "package '${instanceName}' has no meta.owner"; } ]
    else [ ];
};

rules.reliability.hasPDB = {
  description = "Multi-replica deployments must have a PodDisruptionBudget";
  level = "package";
  severity = "warning";
  check = { resources, instanceName, ... }:
    let
      multiReplicaDeployments = builtins.filter
        (r: r.kind == "Deployment" && (r.spec.replicas or 1) > 1)
        resources;
      hasPDB = builtins.any (r: r.kind == "PodDisruptionBudget") resources;
    in
    if multiReplicaDeployments != [ ] && !hasPDB
    then [ { message = "'${instanceName}' has multi-replica Deployments but no PDB"; } ]
    else [ ];
};
```

#### Level: `namespace`

**When:** After all packages in a namespace are evaluated.
**Scope:** All resources and package instances in one namespace.
**Signature:** `{ instances, resources, namespaceName, ... } -> [ findings ]`
**What it sees:** Every instance and resource in the namespace. Cross-package analysis.
**Examples:** "Every namespace with workloads must have a NetworkPolicy", "total resource requests in namespace must not exceed quota."

```nix
rules.security.hasNetworkPolicy = {
  description = "Namespaces with workloads must have at least one NetworkPolicy";
  level = "namespace";
  severity = "warning";
  check = { resources, namespaceName, ... }:
    let
      hasWorkload = builtins.any (r: builtins.elem r.kind [ "Deployment" "StatefulSet" "DaemonSet" ]) resources;
      hasNetpol = builtins.any (r: builtins.elem r.kind [ "NetworkPolicy" "CiliumNetworkPolicy" ]) resources;
    in
    if hasWorkload && !hasNetpol
    then [ { message = "namespace '${namespaceName}' has workloads but no NetworkPolicy"; } ]
    else [ ];
};
```

#### Level: `cluster`

**When:** After all namespaces are evaluated, before the activation is built. This is the final pass.
**Scope:** The entire cluster — all instances, all resources, the full dependency graph.
**Signature:** `{ allInstances, allResources, dependencyGraph, clusterConfig, ... } -> [ findings ]`
**What it sees:** Everything. Cross-namespace, cross-package, full graph analysis.
**Examples:** "No orphaned CRDs", "all cluster-issuers have at least one cert consumer", "cross-namespace deps are explicitly approved."

```nix
rules.governance.noCrossNsWithoutApproval = {
  description = "Cross-namespace dependencies must be explicitly approved";
  level = "cluster";
  severity = "error";
  check = { allInstances, dependencyGraph, ... }:
    # ... walk the graph, find cross-namespace edges not in an approved list
    [];
};
```

### Selective enforcement (the Spacelift lesson)

Adam's feedback: selecting which policies to enforce is core. The cluster definition controls this via **scoped rule overrides**:

```nix
{
  # Import a rule library
  rules = import ./rules/production-readiness.nix;

  # Cluster-wide defaults
  ruleDefaults = {
    # Everything starts as "warning" unless the rule says otherwise
    severity = "warning";
  };

  # Scope-specific overrides
  ruleOverrides = {
    # Production namespaces: promote security rules to errors
    byNamespace."production-*" = {
      "security.*".severity = "error";
      "reliability.*".severity = "error";
    };

    # Dev namespaces: demote everything to info (audit only)
    byNamespace."dev-*" = {
      "*".severity = "info";
    };

    # Specific team: stricter governance
    byOwner."backend-team" = {
      "governance.hasOwner".severity = "error";
      "reliability.hasPDB".severity = "error";
    };

    # Disable a specific rule entirely
    byRule."security.imageDigest" = {
      enabled = false;  # skip this rule
    };
  };
}
```

**Override resolution order** (most specific wins):
1. Per-rule disable (`byRule.X.enabled = false`)
2. Per-owner override (`byOwner."team".X.severity = ...`)
3. Per-namespace override (`byNamespace."ns".X.severity = ...`)
4. Rule's own default severity
5. Cluster-wide `ruleDefaults.severity`

Glob patterns (`"security.*"`, `"production-*"`) are matched with `lib.match` or simple prefix matching. This is how Spacelift does OPA policy attachment — by stack/label/pattern — and it works.

### The NixOS module priority angle

There's a natural mapping to the NixOS module priority system that kix already uses:

```nix
# Platform team sets security rules as errors (high priority)
rules.security.nonRoot.severity = lib.mkDefault "error";

# App team can't downgrade — mkDefault is the floor, mkForce is the override
# If they try: rules.security.nonRoot.severity = "warning";
# ... the platform team's mkDefault wins unless they use mkForce
# ... and mkForce usage is itself auditable (a scorecard rule can flag it!)
```

This means the module system's existing priority hierarchy *is* the policy enforcement hierarchy. Platform team fragments set defaults; app team fragments can adjust within bounds; `mkForce` overrides are flagged as findings. No new mechanism needed.

### Rule library structure

Ship a standard library of rules in `lib/rules/`:

```
lib/rules/
  security.nix       # nonRoot, noPrivileged, readOnlyRootfs, imageDigest, noHostNetwork, ...
  reliability.nix    # hasProbes, hasResourceLimits, hasPDB, replicaCount, gracefulShutdown, ...
  governance.nix     # hasOwner, hasDescription, labelStandards, ...
  observability.nix  # hasServiceMonitor, hasMetricsPort, ...
  operations.nix     # ingressHasTLS, noLatestTag, ...
```

Each file exports an attrset of rules under its category namespace:

```nix
# lib/rules/security.nix
{ lib }:
{
  nonRoot = { ... };
  noPrivileged = { ... };
  readOnlyRootfs = { ... };
  imageDigest = { ... };
  noHostNetwork = { ... };
  rbacNotClusterAdmin = { ... };
  noSecretInEnvValue = { ... };
  automountDisabled = { ... };
}
```

Cluster definitions import what they want:

```nix
{
  # Import all standard rules
  rules = kix.rules;

  # Or selectively
  rules = {
    security = kix.rules.security;
    reliability = kix.rules.reliability;
    # skip governance, observability
  };

  # Or extend with custom rules
  rules = kix.rules // {
    custom.myCompanyCheck = { ... };
  };
}
```

---

## Evaluation pipeline

Where this fits in the existing eval flow (referencing `lib/eval/cluster.nix` and `lib/eval/instance.nix`):

### Manifest-level rules

Evaluated inside `mkResource` (in `lib/k8s.nix`) or as a post-processing step on each resource. Each resource is checked against all `level = "manifest"` rules where `appliesTo` matches. Findings are attached to the resource as `_findings` (internal field, stripped before manifest serialization).

**Trade-off:** Running rules inside `mkResource` catches issues earliest but couples the rule engine to resource construction. Running them as a post-step on `allPartResources` in `instance.nix` is cleaner — all resources exist, rules run once.

**Recommendation:** Post-step in `instance.nix`, after the fixpoint resolves `parts`. This matches the pattern of `_crossNsCheck` and diagnostics collection that already happens there.

### Package-level rules

Evaluated in `evaluateInstance` (in `instance.nix`), after `parts` is built and `forwardClosure` is computed. The rule receives the full resource set, config, deps, and meta.

This is a natural extension of the existing `evaluatePackageDiagnostics` call — the package diagnostic functions are effectively package-level rules defined inline. The scorecard system generalizes this to cluster-defined rules that apply to all packages.

### Namespace-level rules

Evaluated in `cluster.nix`, after the nested fixpoint (`clusterInstances` is resolved) but before the activation is built. Group instances and resources by namespace, run namespace-level rules.

This is the same position where network policy generation already runs (lines 224-253 of `cluster.nix`). It's a post-fixpoint, pre-activation pass.

### Cluster-level rules

Evaluated last, after namespace-level. Full access to `allInstancesList`, `allResources`, and the dependency graph (which can be computed from store-path context or the `kix.dev/depends-on` annotations).

### Collection and output

All findings are collected into a structured report:

```nix
{
  findings = [
    {
      rule = "security.nonRoot";
      severity = "error";       # effective severity after overrides
      level = "manifest";
      namespace = "production";
      instance = "immich";
      resource = "immich-deployment";  # null for package/ns/cluster level
      message = "container 'immich-server' does not set runAsNonRoot";
      tags = [ "security" ];
    }
    # ...
  ];
  summary = {
    total = 42;
    errors = 3;
    warnings = 28;
    info = 11;
    byCategory = { security = 12; reliability = 18; governance = 7; observability = 5; };
    byNamespace = { production = 15; staging = 27; };
    byOwner = { backend-team = 20; platform-team = 22; };
    score = 93;  # 100 - (errors * 10 + warnings * 1) / total_checks * 100
  };
}
```

This output is:
- Written as JSON alongside the cluster build output (for CI consumption)
- Exportable as SARIF (see `61_compliance_exports.md`)
- Displayable via `kix check` CLI command
- The foundation for any future web dashboard

---

## CLI: `kix check`

```
kix check <cluster> [--severity=error,warning] [--namespace=X] [--owner=X] [--tag=security] [--format=text|json|sarif]
```

**Text output (default):**
```
Cluster: nw1
Rules: 15 enabled (3 error, 8 warning, 4 info)

ERRORS (3)
  security.nonRoot          production/immich     container 'immich-server' does not set runAsNonRoot
  security.nonRoot          production/immich-ml  container 'ml-worker' does not set runAsNonRoot
  reliability.hasLimits     production/echo       container 'echo' has no resource limits

WARNINGS (8)
  governance.hasOwner       staging/echo          package 'echo' has no meta.owner
  reliability.hasPDB        production/immich     has multi-replica Deployments but no PDB
  ...

Score: 81/100 (3 errors, 8 warnings across 57 checks)
```

**JSON output:** The structured report above.
**SARIF output:** See `61_compliance_exports.md`.

---

## Relationship to existing diagnostics

The scorecard system does **not** replace the existing `assertions`/`warnings` in packages. Those are package-authored, inline diagnostics about the package's own correctness ("I need pgvecto.rs"). Scorecard rules are platform-authored, external policies about standards ("all containers must run as non-root").

| | Package diagnostics | Scorecard rules |
|---|---|---|
| **Who defines** | Package author | Platform team / cluster operator |
| **Where defined** | Inside the package (`assertions`, `warnings`) | Cluster definition or shared rule library |
| **Scope** | This package's own correctness | Cross-cutting standards across all packages |
| **Enforcement** | Always (part of the package contract) | Configurable per scope (ns/team/env) |
| **Severity** | Fixed (assertion = error, warning = warning) | Configurable (error/warning/info, overridable) |

Both produce findings that flow into the same structured report. A `kix check` output shows both package diagnostics and scorecard findings, distinguished by source.

---

## Built-in rule library (v1)

The initial set of rules to ship. ~15 rules covering the checks IDP buyers expect:

### Security (6 rules)

| Rule | Level | Default severity | What it checks |
|---|---|---|---|
| `security.nonRoot` | manifest | error | `securityContext.runAsNonRoot = true` on all pod specs |
| `security.noPrivileged` | manifest | error | No `securityContext.privileged = true` |
| `security.readOnlyRootfs` | manifest | warning | `securityContext.readOnlyRootFilesystem = true` |
| `security.noHostNetwork` | manifest | error | No `hostNetwork`, `hostPID`, `hostIPC` |
| `security.noLatestTag` | manifest | warning | Image refs don't end in `:latest` or have no tag |
| `security.hasNetworkPolicy` | namespace | warning | Namespaces with workloads have NetworkPolicy |

### Reliability (5 rules)

| Rule | Level | Default severity | What it checks |
|---|---|---|---|
| `reliability.hasResourceLimits` | manifest | warning | Every container has `resources.limits` |
| `reliability.hasResourceRequests` | manifest | warning | Every container has `resources.requests` |
| `reliability.hasProbes` | manifest | warning | Workload containers have liveness + readiness probes |
| `reliability.hasPDB` | package | warning | Multi-replica Deployments have a PDB in the same package |
| `reliability.gracefulShutdown` | manifest | info | `terminationGracePeriodSeconds` is set and > 0 |

### Governance (3 rules)

| Rule | Level | Default severity | What it checks |
|---|---|---|---|
| `governance.hasOwner` | package | warning | `meta.owner` is set |
| `governance.hasDescription` | package | info | `meta.description` is non-empty |
| `governance.labelStandards` | manifest | info | Required labels present (`app.kubernetes.io/name`, etc.) |

### Observability (1 rule)

| Rule | Level | Default severity | What it checks |
|---|---|---|---|
| `observability.hasServiceMonitor` | package | info | Packages with metrics ports have a ServiceMonitor when Prometheus is available |

---

## The Three-Tier Model: Prevention, Detection, Audit

The scorecard-as-linter design above is Tier 2. But a compiler shouldn't just detect that you wrote unsafe code — it should make writing unsafe code unnecessary. The full model is:

### Tier 1: Prevention — Safe Defaults in the DSL

The DSL primitives themselves produce safe output. The developer never sees the unsafe version. They'd have to actively `mkForce` to get root, and *that* is what the scorecard flags.

**Mechanism: kind-based default templates in `mkResource`.**

`mkResource` (and `scopeMkResource`/`mkWorkload` in `scope.nix`) receives a **default template list** from the cluster config. Each template matches on `kind` + `apiVersion` and provides a base manifest that gets recursively merged *under* the user's resource — so the user's values always win, but safe defaults fill in everything they didn't specify.

```nix
# In cluster definition or a shared security profile:
{
  resourceDefaults = [
    {
      # Applies to all Deployments, StatefulSets, DaemonSets
      match = { kinds = [ "Deployment" "StatefulSet" "DaemonSet" ]; };
      template = {
        spec.template.spec = {
          # Every pod runs as non-root unless explicitly overridden
          securityContext = {
            runAsNonRoot = true;
            seccompProfile.type = "RuntimeDefault";
          };
          # Every container gets safe defaults
          # (applied per-container, see Container Defaults below)
        };
      };
    }
    {
      # Applies to all Services
      match = { kinds = [ "Service" ]; };
      template = {
        # No unsafe defaults for Services currently, but the pattern is extensible
      };
    }
    {
      # Applies to all Ingress resources
      match = { kinds = [ "Ingress" ]; };
      template = {
        metadata.annotations = {
          # Force HTTPS redirect by default
          "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
        };
      };
    }
  ];

  # Per-container defaults (applied to every container in every workload)
  containerDefaults = {
    securityContext = {
      allowPrivilegeEscalation = false;
      readOnlyRootFilesystem = true;
      runAsNonRoot = true;
      capabilities.drop = [ "ALL" ];
    };
    # Default resource limits from cluster config
    resources.limits = {
      cpu = "500m";
      memory = "512Mi";
    };
    resources.requests = {
      cpu = "100m";
      memory = "128Mi";
    };
  };
}
```

#### How the merge works in `mkWorkload`

The injection point is `mkWorkload` in `scope.nix` (line 173), which already processes workload resources. The merge order ensures user values always win:

```nix
# Pseudo-code for the merge in mkWorkload:
mkWorkload = apiVersion: kind: attrs:
  let
    # 1. Find matching default templates
    matchingDefaults = builtins.filter
      (d: builtins.elem kind (d.match.kinds or []))
      clusterConfig.resourceDefaults;

    # 2. Start with defaults, merge user attrs ON TOP
    #    lib.recursiveUpdate is "last wins" — user values override defaults.
    baseSpec = builtins.foldl'
      (acc: d: lib.recursiveUpdate acc d.template)
      {}
      matchingDefaults;

    mergedAttrs = lib.recursiveUpdate baseSpec attrs;

    # 3. Apply per-container defaults to each container
    spec = mergedAttrs.spec or {};
    templateSpec = spec.template.spec or {};
    containers = map (c: lib.recursiveUpdate containerDefaults c)
      (templateSpec.containers or []);
    initContainers = map (c: lib.recursiveUpdate containerDefaults c)
      (templateSpec.initContainers or []);

    # 4. Proceed with existing mkWorkload logic (capability checks, selector wiring)
  in
    # ... existing mkWorkload body with mergedAttrs
```

**The key property:** `lib.recursiveUpdate base overlay` means the overlay (user values) wins on every leaf. So:

```nix
# Package author writes:
scope.mkDeployment {
  name = "my-app";
  spec.template.spec.containers = [{
    name = "app";
    image = "my-app:v1";
    # Does NOT specify securityContext or resources
  }];
};

# After merge, the manifest contains:
# spec.template.spec.containers[0] = {
#   name = "app";
#   image = "my-app:v1";
#   securityContext = {                    ← injected from containerDefaults
#     allowPrivilegeEscalation = false;
#     readOnlyRootFilesystem = true;
#     runAsNonRoot = true;
#     capabilities.drop = ["ALL"];
#   };
#   resources.limits = { cpu = "500m"; memory = "512Mi"; };  ← injected
#   resources.requests = { cpu = "100m"; memory = "128Mi"; }; ← injected
# };
```

And if the package explicitly needs root:

```nix
scope.mkDeployment {
  name = "system-tool";
  spec.template.spec.containers = [{
    name = "tool";
    image = "system-tool:v1";
    securityContext.runAsNonRoot = false;  # explicit override — this wins
  }];
};
```

The override works because `lib.recursiveUpdate` is leaf-wins. The user's `runAsNonRoot = false` replaces the default's `true`.

#### Container defaults: the list merge problem

K8s containers are lists, not attrsets. `lib.recursiveUpdate` handles attrsets but doesn't know how to merge into list items. The container defaults must be applied **per-item**, not as a whole-list merge:

```nix
# For each container in spec.template.spec.containers:
mergedContainers = map
  (container: lib.recursiveUpdate containerDefaults container)
  (userSpec.template.spec.containers or []);
```

This applies `containerDefaults` as a base for every container the user defines, then the user's per-container values win. A container that specifies `resources.limits.cpu = "2"` keeps its own value; a container that says nothing gets the cluster default.

#### Why this applies to Helm charts too

`wrapHelmResource` in `helm.nix` calls `scope.mkResource` (for general resources) or effectively `mkWorkload` (via `scopeMkResource`). Since the default injection happens inside `mkWorkload`/`scopeMkResource`, **Helm chart resources get the same safe defaults**. A Helm chart that doesn't set `securityContext` on its pods inherits the cluster's security defaults automatically.

This is the compiler analogy in action: C doesn't let you write raw assembly unless you use `__asm__`. kix doesn't let you create an unsafe Deployment unless you explicitly override the defaults.

#### Profiles: importable default sets

Like NixOS hardware profiles or the existing `lib/flavors/` for cluster capabilities, default sets can be packaged as importable profiles:

```nix
# lib/profiles/security-hardened.nix
{
  resourceDefaults = [
    {
      match.kinds = [ "Deployment" "StatefulSet" "DaemonSet" ];
      template.spec.template.spec.securityContext = {
        runAsNonRoot = true;
        fsGroup = 65534;
        seccompProfile.type = "RuntimeDefault";
      };
    }
  ];
  containerDefaults = {
    securityContext = {
      allowPrivilegeEscalation = false;
      readOnlyRootFilesystem = true;
      runAsNonRoot = true;
      capabilities.drop = [ "ALL" ];
    };
  };
}

# lib/profiles/production.nix
{ lib }:
lib.recursiveUpdate (import ./security-hardened.nix) {
  containerDefaults.resources = {
    limits = { cpu = "1"; memory = "1Gi"; };
    requests = { cpu = "250m"; memory = "256Mi"; };
  };
}

# Cluster definition:
{
  imports = [ kix.profiles.production ];
  # All workloads now get production security + resource defaults
}
```

### Tier 2: Escape Hatch Detection — Scorecard Rules

With Tier 1 in place, the scorecard rules change character. They're no longer checking "did you set `runAsNonRoot`?" — the compiler already set it. They're checking **"did something bypass the compiler's safety?"**:

| Rule | What it detects | When it fires |
|---|---|---|
| `security.explicitOverride` | A resource explicitly sets `securityContext.runAsNonRoot = false` | Someone overrode the safe default — flag for review |
| `security.noContainerDefaults` | A container has no `resources.limits` despite cluster defaults existing | The container was constructed outside `mkWorkload` (raw `mkResource` call) |
| `security.helmUnhardened` | A Helm-imported workload has weaker security context than the cluster defaults | Helm chart's own values overrode kix defaults (possible if values are set in the chart) |
| `governance.mkForceAudit` | A module uses `mkForce` to override a security-related default | Auditable signal that someone bypassed the priority hierarchy |

This is a fundamentally smaller and more useful rule set. Instead of 15 rules checking every container for every security field, you have 3-4 rules checking "did something escape the safety net?" Much fewer false positives, much more signal.

### Tier 3: Audit — Compliance Exports

The compliance exports (doc 61) document:
- **What Tier 1 prevents:** "All workloads have non-root, resource limits, and read-only rootfs by default. The compiler injects these at resource construction time. Overrides require explicit values that are visible in code review."
- **What Tier 2 catches:** "3 resources have explicit security overrides. 2 Helm-imported workloads have weaker security contexts. See SARIF report for details."
- **The combination:** "Of 150 containers in the cluster, 147 have compiler-injected safe defaults. 3 have reviewed overrides documented in findings."

This is the narrative that makes auditors happy: prevention by construction, detection of exceptions, documentation of the gap.

### How the three tiers interact

```
Developer writes package
        │
        ▼
   mkWorkload / mkResource
        │
        ├── Tier 1: kind-based defaults merged UNDER user values
        │   (safe securityContext, resource limits, etc.)
        │
        ▼
   Package fixpoint resolves
        │
        ├── Tier 2: scorecard rules scan for escape hatches
        │   (explicit overrides, missing defaults, Helm bypasses)
        │
        ▼
   Cluster evaluation complete
        │
        ├── Tier 2: namespace/cluster-level rules
        │   (network policies exist, cross-ns deps approved)
        │
        ├── Tier 3: compliance exports
        │   (SARIF, SBOM, SLSA, OSCAL with evidence from both tiers)
        │
        ▼
   Build output + findings report
```

### What changes in the rule library with Tier 1

The built-in rule library (v1) shifts from "check that fields exist" to "check that nothing escaped":

| Old rule (without Tier 1) | New rule (with Tier 1) | Why it's better |
|---|---|---|
| `security.nonRoot` — check every container | `security.explicitUnsafe` — flag containers that explicitly set `runAsNonRoot = false` | 95% of containers pass automatically. Rules only fire on deliberate overrides. |
| `reliability.hasResourceLimits` — check every container | `reliability.noDefaultLimits` — flag containers constructed outside `mkWorkload` that bypass defaults | Only fires on raw `mkResource` calls, not every container. |
| `reliability.hasProbes` — check every workload | Stays the same — probes are app-specific, can't have universal defaults | Probes are one of the few things that truly need per-app configuration. |
| `governance.hasOwner` — check every package | Stays the same — ownership is package-specific | Meta fields can't be defaulted meaningfully. |

**The principle:** If something can have a safe universal default, make it Tier 1 (prevention). If it's inherently per-application (probes, ownership, backup strategy), keep it Tier 2 (detection). If it's about documentation and evidence, it's Tier 3 (audit).

---

## Open questions

1. **Rule evaluation timing vs. build performance.** Running 15 rules across all resources after the fixpoint adds eval time. Is this acceptable, or do we need a `--skip-rules` flag? The network policy pass is already a full resource scan, so the pattern is established.

2. **Rule as module option vs. plain attrset.** Should rules be NixOS module options (typed, with `mkDefault`/`mkOverride` support) or plain attrsets merged by the evaluator? Module options give free priority handling but add complexity. Plain attrsets are simpler but need a custom override mechanism.

3. **Rule dependencies.** Can a rule depend on another rule's findings? E.g., "if `security.nonRoot` passes, skip `security.readOnlyRootfs` (it's redundant on non-root)." This adds complexity — probably not v1.

4. **Custom `appliesTo` ergonomics.** Writing `appliesTo = { resource, ... }: builtins.elem resource.kind [ "Deployment" "StatefulSet" ];` is verbose. Should the rule schema support `appliesTo.kinds = [ "Deployment" "StatefulSet" ];` as sugar?

5. **Finding deduplication.** Manifest-level rules run per-resource. If the same container image is used in 10 Deployments, the `noLatestTag` rule produces 10 findings. Should we deduplicate, or is the repetition useful (shows exactly which resources are affected)?

6. **Interaction with `meta.checkMetaStatic`.** The existing meta checks (k8s version bounds, compatibility, conflicts) could be reframed as built-in scorecard rules. Should they be migrated, or left as a separate "structural validation" layer?

7. **Container defaults and list merging.** `lib.recursiveUpdate` is attrset-only. Containers are lists. The per-container merge requires iterating the user's container list and merging defaults into each item. What about `initContainers` and `ephemeralContainers`? Do they get the same defaults? Probably yes — they're equally capable of running as root.

8. **Default override detection.** For Tier 2 escape-hatch rules to work, the rule needs to know "did the user explicitly set this field, or was it injected by the default?" One approach: the default-injection pass records which fields it injected (as a `_kixDefaults` internal annotation on the resource). The rule then checks if a field differs from the recorded default. Alternative: just diff the user's input against the template — if they specified a weaker value, flag it.

9. **Helm chart default interaction.** Helm charts may set their own `securityContext`. When `wrapHelmResource` calls `mkResource`, the Helm chart's values are "user values" and would win over kix defaults. Is this desirable? Probably yes — the Helm chart author intended those values. But the Tier 2 rule `security.helmUnhardened` should flag cases where the Helm chart's security context is weaker than the cluster defaults. This gives visibility without breaking Helm compatibility.

10. **`resourceDefaults` vs `containerDefaults` vs module priorities.** Should these be separate configuration paths (as designed above) or should they be expressible as module options with `mkDefault` priority? Module priorities would allow `containerDefaults.securityContext.runAsNonRoot = lib.mkDefault true` at the cluster level, which app teams could override with normal priority. This is more idiomatic NixOS but requires the resource construction to participate in the module system evaluation, which it currently doesn't.
