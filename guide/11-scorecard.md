# Scorecard & rules

This chapter covers the scorecard rule engine: a declarative policy framework that runs at
*build time* and scores the resources your packages emit. It explains the four evaluation
levels (manifest, package, namespace, cluster), the built-in rule library, how the severity
of a finding is resolved through a precedence chain (not a flat config), and how a package
author reads and legitimately silences findings. The engine lives in `kix/lib/scorecard.nix`;
the rules in `kix/lib/rules/`; the cluster-config surface in `kix/lib/modules.nix`.

## What the scorecard is

The scorecard is policy-as-code evaluated while the cluster is being compiled. Rules inspect
the manifests a package produces and emit *findings*. Each finding has a `severity`:

- `info` / `warning` findings become kix trace warnings (printed, non-blocking).
- `error` findings become assertions (`assertion = false`), which **fail the build**.

The conversion happens in `scorecard.scorecardToWarnings` (see `kix/lib/scorecard.nix`): it
splits findings by severity, turns non-errors into `"[scorecard:<rule>] <loc>: <message>"`
warnings, and errors into failing assertions. So "scoring" is not a separate report you run -
it is woven into the normal build and shares the same diagnostics channel as the rest of kix
(see 02-package-anatomy.md for warnings/assertions).

The scorecard is **off by default**. It runs only when a cluster opts in:

```nix
scorecard.enable = true;
```

and provides a non-empty `rules` set. The guard is `scorecardEnabled = enable && rules != {}`
(`kix/lib/eval/instance.nix`).

## The four levels

A rule declares a `level`, which decides what context its `check` function receives and how
often it runs. Levels run from narrowest to widest scope:

| level       | runs per                | `check` ctx keys                                              | wired in |
|-------------|-------------------------|--------------------------------------------------------------|----------|
| `manifest`  | each emitted resource   | `resource`, `instanceName`, `namespaceName`                  | `eval/instance.nix` |
| `package`   | each package instance   | `resources`, `parts`, `config`, `meta`, `instanceName`, `namespaceName` | `eval/instance.nix` |
| `namespace` | each namespace          | `instances`, `resources`, `namespaceName`                    | `eval/cluster.nix` |
| `cluster`   | once, whole cluster     | `allInstances`, `allResources`, `clusterConfig`              | `eval/cluster.nix` |

A `check` returns a **list** of finding records (`{ message = "..."; }`); an empty list means
the rule passed. Each finding in the list becomes one scorecard finding at the rule's resolved
severity. The corresponding evaluators are `evaluateManifestRules`, `evaluatePackageRules`,
`evaluateNamespaceRules`, and `evaluateClusterRules` in `kix/lib/scorecard.nix`.

A rule may also declare `appliesTo`, a predicate over the same ctx. If it returns false the
rule is skipped for that target. Almost every built-in manifest rule uses this to scope itself
to workloads:

```nix
appliesTo = { resource, ... }: isWorkload resource;
```

## Anatomy of a rule

A rule is a plain attrset. From `kix/lib/rules/security.nix`:

```nix
nonRoot = {
  description = "All containers must run as non-root";
  level = "manifest";
  severity = "error";
  tags = [ "security" "cis-benchmark" ];
  appliesTo = { resource, ... }: isWorkload resource;
  check =
    { resource, ... }:
    let
      containers = getContainers resource;
      failing = builtins.filter (c: !(c.securityContext.runAsNonRoot or false)) containers;
    in
    map (c: { message = "container '${c.name or "unnamed"}' does not set runAsNonRoot"; }) failing;
};
```

Fields:

- `description` - human text (not used in output, documents intent).
- `level` - one of the four above. A rule with an unrecognized/missing level is silently
  filtered out (`filter (r: (r.rule.level or "") == "manifest")`).
- `severity` - the rule's own default: `info`, `warning`, or `error`.
- `tags` - free-form labels copied onto findings (e.g. `"cis-benchmark"`, `"reliability"`).
- `appliesTo` (optional) - predicate; default true.
- `check` - the work; returns a list of `{ message; }`.

Rules are organized as a nested attrset `{ category.ruleName = rule; }`. The engine flattens
this to dotted names via `flattenRules`, so `security.nonRoot` is the rule's canonical name
used everywhere in override config and in the printed warning prefix.

## The built-in rule library

`kix/lib/rules/default.nix` exposes four categories, importable as `kix.rules`
(all) or selectively (`kix.rules.security`, `kix.rules.architecture`, ...).

### security (`kix/lib/rules/security.nix`)

| rule | level | default severity | checks |
|------|-------|------------------|--------|
| `nonRoot` | manifest | error | every container sets `securityContext.runAsNonRoot` |
| `noPrivileged` | manifest | error | no container is `privileged` |
| `readOnlyRootfs` | manifest | warning | `readOnlyRootFilesystem` is set |
| `noHostNetwork` | manifest | error | no `hostNetwork` / `hostPID` / `hostIPC` |
| `noLatestTag` | manifest | warning | no image is `:latest` or untagged |
| `hasNetworkPolicy` | namespace | warning | a namespace with workloads has >= 1 `NetworkPolicy`/`CiliumNetworkPolicy` |

`getContainers` pulls both `spec.template.spec.containers` and `initContainers`. `isWorkload`
matches `Deployment`, `StatefulSet`, `DaemonSet`, `Job`.

### reliability (`kix/lib/rules/reliability.nix`)

| rule | level | default severity | checks |
|------|-------|------------------|--------|
| `boundedResources` | manifest | warning | every container has CPU+memory in *both* requests and limits |
| `hasResourceLimits` | manifest | warning | container has `resources.limits` |
| `hasResourceRequests` | manifest | warning | container has `resources.requests` |
| `hasProbes` | manifest | warning | main containers have `livenessProbe` and `readinessProbe` |
| `hasPDB` | package | warning | multi-replica `Deployment`s have a `PodDisruptionBudget` |
| `gracefulShutdown` | manifest | info | `terminationGracePeriodSeconds` set and non-zero |

`boundedResources` is the strict superset of `hasResourceLimits` + `hasResourceRequests`; it
exists for single-node clusters where an unbounded pod can OOM the host. `hasProbes` only
inspects main containers (init containers are excluded by `getMainContainers`).

### governance (`kix/lib/rules/governance.nix`)

| rule | level | default severity | checks |
|------|-------|------------------|--------|
| `hasOwner` | package | warning | package declares `meta.owner` |
| `hasDescription` | package | info | package declares `meta.description` |
| `labelStandards` | manifest | info | workloads carry `app.kubernetes.io/name` and `app.kubernetes.io/managed-by` |

`hasOwner` / `hasDescription` read `meta` from package ctx, so they tie directly to the package
`meta` block (see 02-package-anatomy.md).

### architecture (`kix/lib/rules/architecture.nix`)

These catch DI-hygiene smells - resources hand-rolled inline that should be requested via
dependency injection (see 07-dependency-injection.md and 09-networking-and-meta.md).

| rule | level | default severity | checks |
|------|-------|------------------|--------|
| `capabilityOwnership` | package | warning | a resource whose capability is owned by another package is requested via DI, not hand-rolled |
| `selectorCoherence` | manifest | warning | a `Service` selector value carries store-path context (came from `kix.service.fromWorkload`), not a literal `{ app = "..."; }` attrset |
| `fqdnWithoutContext` | manifest | warning | `*.svc` FQDN strings in workloads carry store-path context (came from a ServiceRef/Service `out.*`), not literals |

`capabilityOwnership` is *fingerprint-driven*. A `fingerprints` list maps a detector to a
capability name. A package "owns" a capability iff `meta.provides` contains it, or one of its
resources carries the annotation `kix.dev/capability: <name>` (stamped by the owner's DI
builder). If a resource matches a fingerprint and the package owns neither, the rule fires with
a `rationale` + `suggest` message pointing at the right DI builder.

The shipped fingerprints are `storage` (detects `PersistentVolumeClaim`) and `reflection`
(detects the `reflector.v1.k8s.emberstack.com` annotation domain anywhere in the resource).

**Adding a fingerprint is data-only.** Append a record to the `fingerprints` list in
`architecture.nix` - `{ capability; detect; describe; rationale; suggest; }`. You do not touch
the rule engine or the generic `capabilityOwnership` check; it iterates the registry.

`selectorCoherence` and `fqdnWithoutContext` both lean on Nix string context: a value with
non-empty `builtins.getContext` is trusted because *something* in the graph carries the DAG
edge; a context-free literal is the smell. This is why the architecture rules are the canonical
default-on set in `ludo/base.nix` - they enforce the store-path-as-DAG-edge discipline that
underpins netpol and wave ordering (see 01-overview.md).

## Enabling and configuring

The config surface is the `scorecard` submodule in cluster config (`kix/lib/modules.nix`):

```nix
scorecard = {
  enable = true;
  rules = { ... };         # nested { category.ruleName = rule; }
  ruleDefaults = { ... };  # cluster-wide fallbacks
  ruleOverrides = { ... }; # per-rule / per-owner / per-namespace tuning
};
```

The minimal opt-in, from `ludo/base.nix`, enables only the architecture category:

```nix
scorecard = {
  enable = true;
  rules = {
    architecture = kix.rules.architecture;
  };
};
```

To enable everything: `rules = kix.rules;`. Because `rules` is just an attrset, you mix and
match categories, or hand-write your own rule under any category name.

## Severity precedence (not flat config)

The severity a finding actually fires at is **not** the rule's `severity` field alone. It is
resolved per (rule, namespace, owner) by `resolveEffectiveSeverity` in `kix/lib/scorecard.nix`,
which walks a precedence chain. Most specific wins:

1. **Per-rule disable** - `ruleOverrides.byRule.<rule>.enabled = false` -> the rule is skipped
   entirely (resolves to `null`, no finding).
2. **Per-rule severity** - `ruleOverrides.byRule.<rule>.severity`.
3. **Per-owner severity** - `ruleOverrides.byOwner.<ownerPattern>.<rulePattern>.severity`.
4. **Per-namespace severity** - `ruleOverrides.byNamespace.<nsPattern>.<rulePattern>.severity`.
5. **Rule's own `severity`** field.
6. **Cluster-wide** `ruleDefaults.severity`, else the hardcoded fallback `"warning"`.

Read the chain top-down: a per-rule override beats a per-owner override beats a per-namespace
override beats the rule's default. (Note this ordering: `byRule` is most specific, `byNamespace`
is least specific of the three override scopes - it is *not* alphabetical and it is *not* "most
recently written wins".)

`byOwner` and `byNamespace` keys are **glob patterns** matched by `matchPattern`: `"*"` matches
anything, a trailing `*` is a prefix match (`"kube-*"`), otherwise exact. Both the
namespace/owner key *and* the inner rule key are patterns, so `"security.*"` matches every
security rule. The `owner` passed in is the package's `meta.owner` (`eval/instance.nix`);
`null` owner means `byOwner` rules never match.

### Worked override examples

Disable a single rule cluster-wide:

```nix
scorecard.ruleOverrides.byRule."security.readOnlyRootfs".enabled = false;
```

Lift a rule to build-blocking:

```nix
scorecard.ruleOverrides.byRule."reliability.boundedResources".severity = "error";
```

Relax a category for a system namespace:

```nix
scorecard.ruleOverrides.byNamespace."kube-system"."reliability.*".severity = "info";
```

Hold one team to a stricter bar by owner:

```nix
scorecard.ruleOverrides.byOwner."platform-team"."security.*".severity = "error";
```

Set a baseline for rules that declare no severity:

```nix
scorecard.ruleDefaults.severity = "warning";
```

## How findings surface to you

When the build runs, package-instance findings are merged into that instance's diagnostics
(`eval/instance.nix`): non-error findings join `warnings`, error findings join `assertions`.
You see lines like:

```
[scorecard:security.nonRoot] myns/myapp/myapp-web: container 'web' does not set runAsNonRoot
```

The location is `namespace/instance/resource`, with `null` segments dropped. Error-severity
findings stop the build with the same message as an assertion. So the practical loop for a
package author is: build, read the `[scorecard:...]` lines, fix the manifest or - if the
finding is a legitimate exception - silence it via `ruleOverrides`.

## Legitimately silencing findings

Prefer fixing the manifest. When a finding is a true exception, silence it at the *narrowest*
scope that covers the exception, using the precedence chain:

- One known-good resource type in one namespace -> `byNamespace."<ns>"."<rule>".severity = "info"`.
- A rule that does not apply to your whole cluster's posture -> `byRule."<rule>".enabled = false`.
- A subsystem owned by a team with different constraints -> `byOwner."<owner>"."<rule>".severity`.

Do **not** reach for disabling unless downgrading to `info` is insufficient - an `info` finding
still prints, leaving a breadcrumb, while `enabled = false` makes the rule vanish. There is no
per-resource inline annotation to suppress a single finding; suppression is always config-driven
through the precedence chain.

## Gotchas

- **Scorecard is opt-in and rules-gated.** `enable = true` alone does nothing if `rules = {}`.
  Both conditions must hold (`scorecardEnabled`).
- **An unknown `level` is silently dropped.** The per-level evaluators filter on an exact level
  string; a typo like `level = "manifests"` makes the rule never run, with no error.
- **`error` findings block the build.** A rule whose default severity is `error` (e.g.
  `security.nonRoot`, `noPrivileged`, `noHostNetwork`) will fail `nix build` the moment a
  workload violates it. Either fix the workload or override the severity before enabling that
  category broadly.
- **Precedence is a chain, not a merge.** Only the first matching tier in the
  `byRule -> byOwner -> byNamespace -> rule -> ruleDefaults` order applies. Don't expect a
  per-namespace `info` to combine with a per-owner `error`; the more specific tier wins outright.
- **Glob matching takes the first match.** When multiple owner/namespace patterns match,
  `resolveEffectiveSeverity` takes `builtins.head` of the matches - ordering across patterns
  is not deterministic by specificity, so avoid overlapping patterns at the same tier.
- **Architecture rules depend on string context.** `selectorCoherence` and `fqdnWithoutContext`
  pass only when the value carries store-path context. Using `rawSelector` (the deliberate
  escape hatch, see 05-workloads.md) drops the context and *will* trip `selectorCoherence` -
  that is intentional, it flags the workaround.
- **`capabilityOwnership` checks emitted resources, not the resolved dep graph.** Having a
  `reflector` dep resolved is not proof of hygiene; the resource must actually carry the
  `kix.dev/capability` annotation (stamped by the owner's builder) or the package must list the
  capability in `meta.provides`.
