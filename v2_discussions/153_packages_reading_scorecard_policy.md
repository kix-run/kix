# 153: Packages reading scorecard policy

**Status:** RFC/Draft. Decision required.
**Related:** `archive/60_scorecard_rules_design.md` (rule and override model), `115_pod_spec_hardening_pass.md` (a cluster-level hardening profile both a merge pass and a rule would read), `archive/145_availability_level.md` (the precedent for a cluster value packages adapt to), `archive/128` (`meta.unsafe` grants).
**Code:** `kix/lib/vocab/default.nix` (`scorecard.effectiveSeverity`), `kix/lib/scorecard.nix` (`resolveEffectiveSeverity`, `evaluateManifestRules`), `kix/lib/eval/instance.nix` (the scorecard pass, `scorecardConfig`, `owner`), `kix/lib/eval/cluster.nix` (`cfg`, the two instance fixpoints), `kix/packages/{vaultwarden,immich,immich-machine-learning}/default.nix` (`initChownData`, `nonRootFailsBuild`).

## Terms

- **Scorecard**: the rule set evaluated over what an instance ships. A rule has a level (`manifest`, `package`, `namespace`, `cluster`), a base severity, and an optional `appliesTo` predicate. A finding at `error` fails the build; lower severities print.
- **Effective severity**: the base severity after `ruleOverrides` (by rule, owner, namespace, in that order) and after the cluster cap `scorecard.maxSeverity`. `null` means the rule does not run.
- **Cluster config** (`clusterConfig` inside a package): the evaluated module-system config of the cluster definition. Packages already read `cluster.domain`, `cluster.capabilities`, `cluster.topology.failureDomainKeys`, `networkPolicy.enable` from it.
- **Grant**: `meta.unsafe = [ "run-as-root" ]` and friends (`kix/lib/unsafe.nix`). A manifest rule receives the package's `meta` and its `appliesTo` drops the rule for a package that holds the matching grant.

## Problem

PR #145 gave vaultwarden, immich and immich-machine-learning an `initChownData` option. It adds a root init container that chowns a volume a root-run release wrote, for one deploy on hostPath or local-path storage, where the kubelet does not apply `fsGroup` (`housekeeping/2026-09-27-non-root-apps-cannot-write-root-owned-volumes.md`). The container fails `security.nonRoot`, which is `error` in every cluster of this repository. The finding said "container 'init-chown-data' may run as root", which is true and unhelpful: the user turned the option on and needs to know which override lets the migration deploy through and that it must be undone afterwards.

The fix in #145 is `kix.scorecard.effectiveSeverity { clusterConfig; rule; namespaceName; owner ? null; }` in `kix/lib/vocab/default.nix`. Each package calls it inside its build function and, when it answers `"error"`, throws a message that names the exact `scorecard.ruleOverrides.byNamespace.<ns>."security.nonRoot".severity = "warning"` entry. When the override is in place the container ships and the `warnings` channel prints a reminder to remove the override.

This is the first time a package reads scorecard state. Adam asked four things: is there a recursion risk, should a separate cluster-level value feed both the scorecard and packages, should packages read the scorecard at all, and should this generalise.

## 1. Recursion: what the helper reads, and what it would take to close a loop

### The data flow today

`clusterConfig` is `evaluated.config` from `lib.evalModules` (`eval/cluster.nix:32-41`). The two instance fixpoints, `instanceConfigs` (config injection, `:336`) and `clusterInstances` (full views, `:356`), take `cfg` as an input. Nothing in the evaluator writes into `cfg`: scorecard findings go to `scorecardDiag` and `scorecardReport` (`instance.nix:602-603`) and to `collectClusterDiagnostics` (`cluster.nix:593`), never back into config.

The helper reads five attributes of `clusterConfig.scorecard`: `enable`, `rules` (one path via `lib.attrByPath`, not `flattenRules`, so it does not force every rule's `level` check), `ruleDefaults`, `ruleOverrides`, `maxSeverity`. It then calls the scorecard's own `resolveEffectiveSeverity`, which matches string patterns against `ruleName`, `namespaceName` and `owner` (`scorecard.nix:88-173`). It never touches a resource, a part, `self`, or another instance.

The rules themselves read resources: a manifest rule gets `resource` and `meta`, a package rule gets `resources`, `parts` and the instance `config` (`instance.nix:552-599`). That happens after the build function has returned. So the dependency order is config, then build, then findings, with no back edge. A package reading `clusterConfig.scorecard` sits at the same point as a package reading `clusterConfig.cluster.domain` (vaultwarden and harbor do) and adds no new phase.

### What I tried

A scratch cluster with a package that calls the helper and throws on `"error"` (`scratchpad/loop.nix`, kept out of the repository):

| Case | Setup | Result |
|---|---|---|
| A1 | no override, cap `error` | package guard throws, as intended |
| A2 | `byNamespace.appns` override to `warning` | builds; guard silent |
| A3 | cap lowered to `warning` | builds; guard silent |
| B | `ruleOverrides.byNamespace = lib.mapAttrs (…) config.instances` in a cluster module | builds. A module-system fixpoint over config is fine |
| C | `ruleOverrides` computed from `(buildCluster …).rawManifests` of the same cluster | `error: infinite recursion encountered` |
| D | package holds `meta.unsafe = [ "run-as-root" ]` | without the guard the build passes (the rule drops out via `appliesTo`); with the guard it throws, because the helper answers `"error"` |
| E | package passes `owner = "app-team"`, `meta.owner = "platform"`, `byOwner.platform` override to `warning` | scorecard would pass; guard throws |

Case C is the only loop, and it is a knot a cluster author ties in Nix by routing build output into any config option; `instances` would do the same. The helper does not make it easier. Case B shows the legitimate form: scorecard config may derive from config.

### Where a future change could close the loop

Three shapes would create a back edge, and none exists today:

1. **Findings written into config.** For example an "auto-accept" feature that turns findings into `ruleOverrides`, or a `readOnly` option computed from resources the way `cluster.topology.failureDomainKeys` is computed from capabilities (`plugins/availability/module.nix:144-186`). That plugin is the safe pattern: derived config derives from config.
2. **A rule whose definition is data-dependent.** `scorecard.rules` is `attrsOf anything`, so a rule's `severity` could be a thunk that inspects the built cluster. That is case C spelled differently.
3. **The helper growing to answer "would this rule fire on me".** That needs the resource, which needs the build, which is where the helper is called from. This is the one to watch, because cases D and E make it tempting (see §3).

**Verdict:** no recursion risk in the shipped helper. The invariant to record where the option is defined: `scorecard.*` must stay a function of cluster config, never of findings or resources.

## 2. Does policy need a second channel that both sides read?

The suggestion: a cluster-level intent such as `cluster.security.rootless = "required" | "accepted"` that the `nonRoot` rule and the packages both read, so packages never touch scorecard state.

Precedents for a cluster value packages adapt to:

- `cluster.availability.default` plus `instances.*.availability`: resolved once per instance in `instance.nix:66-74`, handed to packages as `availability`, consumed through `kix.availability.pick` (51 packages). Both a workload interceptor and an instance processor read the same resolved level. This works because availability is a fact about the substrate with one meaning.
- `cluster.capabilities.*` and `cluster.topology.failureDomainKeys`: substrate facts, read by operator-rendered packages that cannot be linted.
- `networkPolicy.platformIntents` and `meta.network.intents` (doc 92): intents the enforcer materialises; the netpol module reads them, packages do not.
- Doc 115's `cluster.podHardening.profile`: the design has a merge pass and a rule read the same profile. The rule fires on weakening relative to the profile; the profile is the policy, the rule is its detector.

The `nonRoot` case is different from all of these. The policy in question **is** the rule's severity: "root containers fail the build here" has no expression other than `security.nonRoot` resolving to `error`. A parallel `cluster.security.rootless` would be a second statement of the same fact, and the two can disagree (rule at `error`, intent says `accepted`, or the reverse), with the scorecard reading one and the package the other. Doc 115 avoids that only because its profile carries information the rule cannot hold (the field set to merge). Here there is nothing extra to carry.

Adding an intent would also violate the "don't invent fields" principle (PRINCIPLES 7, 8) for no automation gain, and it does not remove the package's need to know the cluster's decision; it only moves the read.

**Verdict:** no second channel. The scorecard config is already the cluster's statement of policy, and doc 60 designed the override tree as that statement (the "Spacelift lesson" section).

## 3. Should packages read the scorecard, then?

Yes, for one narrow purpose: a package whose own option knowingly trips a rule may fail earlier with a better message. That is PRINCIPLES 6 (fail at compile time with an actionable reason) applied to a failure the scorecard would raise anyway. The read does not change what ships: the output with the override in place is identical to the output the scorecard would have judged. Only the choice between building and throwing depends on policy.

The shipped helper has two defects, both visible in cases D and E:

- **It answers a question the package is not asking.** The package wants "will `security.nonRoot` fail my build for this resource". The helper answers "what severity does the rule resolve to for this namespace and owner". The gap is `appliesTo`: a package with a `run-as-root` grant gets `"error"` and throws although the scorecard would skip it. No current caller holds the grant, so this is latent.
- **The package repeats facts the evaluator already holds.** `owner` is passed by hand (`owner = "app-team"` in all three packages) and must match `meta.owner`, which is what `instance.nix:550` uses. `namespaceName` is passed from `scope`. A mismatch makes the guard and the scorecard disagree, and nothing checks it.

Both go away if the query is bound to the instance instead of taking raw arguments. The narrowest form:

```nix
# In the build function. Resolved by the evaluator for this instance:
# namespace, meta.owner and meta.unsafe come from the instance, not the caller.
scope.scorecard.severity "security.nonRoot"   # "error" | "warning" | "info" | null
```

`scope` already carries `namespaceName`, and the evaluator has `packageMeta` when it builds `scope'`, so the binding is a few lines in `instance.nix` next to `_networkPolicyEnforcer`. `appliesTo` predicates take a `ctx` with `resource`; for the grant check the resource is not needed (`holdsGrant meta`), but a general `appliesTo` cannot be evaluated without one. The bound helper should therefore answer with the grant applied and document that per-resource `appliesTo` conditions (workload kinds) are not considered. The `kix.scorecard.effectiveSeverity` function can stay as the pure form the bound one calls, or go.

The `kix-migration` skill, `HANDBOOK.md §17.1` and `architecture.md` describe the current helper and would change with it.

### The alternative that avoids the read entirely

A package could attach advice to the finding instead of pre-empting it: it ships the root container unconditionally and declares, per rule, the message the scorecard should append when that rule fires on this instance. The scorecard stays the single judge, the package never reads policy, and the failure is still at eval time in the same build. What is lost: the package cannot choose to fail before the scorecard runs, so the error arrives with the scorecard's other findings rather than alone, and the `warnings` reminder to undo the override needs the same channel. What is gained: no owner or grant mismatch is possible, because the scorecard applies its own `appliesTo` and overrides.

This is a sound design and I would take it over the raw helper. Against the bound helper it is a wash on correctness and worse on message placement (the throw in the package points at the option; a finding points at the container). It also needs a new declaration surface for the message, which is more API than a scope-bound query. I list it because it is the cleanest answer to "packages should not read the scorecard" if Adam holds that as a principle rather than a preference.

## 4. Should this generalise?

The question has two readings.

**Early failure for more rules.** Other opt-in options could trip `readOnlyRootfs`, `boundedResources`, `noHostNetwork`, `hasNetworkPolicy`. The bound query in §3 already generalises: it takes a rule name. Nothing more is needed for that reading, and the driver rule (PRINCIPLES 14) says not to add surface until a second package has a second case. Today there is one case in three packages.

**Adaptation to policy.** A package that reads severity and changes what it ships (drop the init container, pick a different strategy, size resources to a limit) is a different thing. Then the manifests depend on `scorecard.maxSeverity`, and a cluster that lowers the cap to see findings gets different resources. That breaks the reading of determinism that matters here: same intent, same output, with policy deciding only whether the output is accepted. It also puts policy interpretation in sixty packages instead of one rule set, which is what doc 60 centralised. I would refuse this reading outright, and the bound helper's documentation should say the value may choose between building and throwing and must not shape a resource.

For cases where a package needs a fact to size or place a workload (resource bounds, topology), the existing pattern is the right one: a cluster fact (`cluster.capabilities`, `cluster.hardware`, availability) resolved by the evaluator, and a rule that checks the result. Doc 115 §Future work lists resource defaults as a LimitRange or `boundedResources` question, not a scorecard read.

The conditional grant is worth ruling out too: `meta.unsafe` depending on `config.initChownData` cannot work, because `peekPackageMeta` reads meta before config exists (`instance.nix:59-62`), and `unsafe.nix` says an application that runs root has a bug, not a grant.

## Options

| | Option | Recursion | Correctness | Surface | Principles |
|---|---|---|---|---|---|
| O1 | Keep `kix.scorecard.effectiveSeverity` as shipped | none | owner and grant can drift from the scorecard (D, E) | one pure function | 6 yes; repeats facts the evaluator holds (12) |
| O2 | Bind it to the instance: `scope.scorecard.severity rule` | none; same read, resolved by the evaluator | owner and grant come from `packageMeta`; per-resource `appliesTo` still not modelled, documented | one scope attribute, replaces three copied `owner` literals | 6, 12 yes |
| O3 | Package attaches advice to the finding, never reads policy | none | exact, the scorecard judges | new declaration surface for messages; no early throw | 6 yes; more API than O2 |
| O4 | Cluster-level intent both sides read | none | two statements of one fact can disagree | new option | 7, 8 no |
| O5 | Packages adapt output to severity | none | manifests vary with the cap | none | 3 no |

## Recommendation

O2. Keep the read, move the binding into the evaluator so the package states only the rule name, and answer with the grant applied. Record two rules where they will be found:

- At `scorecard` in `modules.nix`: scorecard config is a function of cluster config; a value derived from findings or resources is a cycle.
- At the bound helper: the result may decide between building and throwing; it must not change a resource.

Do not add an intent (O4) and do not let packages shape output by policy (O5). Revisit O3 if a second package needs a message on a rule with a per-resource `appliesTo` that O2 cannot answer.

## Decisions needed

1. **O2 or O3.** Bound query in `scope`, or advice attached to the finding with no package-side read. O2 is smaller; O3 keeps the "packages never read policy" line clean.
2. **The `appliesTo` boundary for O2.** Answer with grants applied and per-resource conditions ignored (documented), or refuse rules that carry a resource-dependent `appliesTo` and make the caller pass the resource.
3. **Whether the pure `kix.scorecard.effectiveSeverity` survives** beside the bound one (the tests and the pure form are useful for the scorecard's own tests) or is removed from the package-facing vocabulary.
4. **The no-adaptation rule.** Confirm that a policy read may only decide between build and throw, so it can be written into the helper's documentation and the `kix-migration` skill as a hard rule rather than advice.
