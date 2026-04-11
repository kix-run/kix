# 83 — Package-Owned Scorecard Rules

## Status

Draft (2026-04-09). Follows from the `architecture.capabilityOwnership`
rule shipped alongside the grafana / stackgres DI-hygiene migration.
Design settled on `meta.rules` (general) + `allInstances` (only-when-deployed);
the open question is whether this is actually valuable in practice or
whether rules should stay in the cluster module system.

## Problem

The architecture scorecard rule shipped in `kix/lib/rules/architecture.nix`
uses a hard-coded list of capability fingerprints:

```nix
fingerprints = [
  { capability = "storage"; detect = r: r.kind == "PersistentVolumeClaim"; ... }
  { capability = "reflection"; detect = r: lib.hasInfix "reflector.v1.k8s.emberstack.com" ...; ... }
];
```

This is fine for the two smells we migrated, but has structural problems
as the set grows:

1. **Ownership is split across files.** The `persistent-volume-claim`
   package defines the capability (`meta.provides = [ "storage" ]`),
   `persistent-volume-claim`'s consumers use `kix.mount.pvc storage`,
   and the smell that catches hand-rolled PVCs lives in
   `kix/lib/rules/architecture.nix`. If the capability definition moves
   (e.g. a new stamping annotation, a renamed kind), the fingerprint has
   to be updated in a different file by someone other than the capability
   owner.

2. **Adding a new fingerprint is a library edit.** cert-manager wanting
   to flag hand-rolled `Certificate` resources requires a patch to
   `rules/architecture.nix`, not to `packages/cert-manager`. That's
   backwards — the capability owner knows best what belongs to it.

3. **The central list doesn't scale to optional third-party packages.**
   A user bringing their own in-house package (an internal secret store,
   a custom operator) can't ship its smell without forking kix/lib.

4. **Rules can't be scoped to "only when the capability is deployed."**
   Today the fingerprint list is static: the storage smell fires in any
   cluster, even clusters with no `persistent-volume-claim` instance at
   all. That's probably correct for storage, but wrong for e.g. a
   "custom hardware CR" rule that only makes sense when that custom
   controller is actually present.

## Goal

- Let a package declaratively ship scorecard rules alongside its other
  meta (`meta.provides`, `meta.defaultAliases`, `meta.lifecycle`).
- Rules contributed by a package become active in the cluster scorecard
  only when at least one instance of that package is deployed.
- The central library becomes a collector + executor, not a rule
  registry. Existing `architecture.capabilityOwnership` is re-expressed
  as a library-shipped template that packages parameterize with their
  own fingerprints.
- No regression for the existing "rules in cluster config" path — cluster
  operators can still add rules directly, and those take precedence /
  merge cleanly with package-contributed rules.

## Non-goals

- Replacing the cluster-level `scorecard.rules` option. Cluster ops still
  need a place to disable / override / add ad-hoc rules.
- Enabling packages to ship rules that fire on *their own* internals.
  Self-provider exemption (via `meta.provides`) stays the contract:
  a package's rules apply to every other package that touches the
  package's capability, not to itself.
- Distributing rules out-of-tree (rule marketplaces, fetched rulesets,
  signed rule bundles). That's a potential future; this RFC is about
  the collection model inside a single flake's `packages`.

## Proposed shape

### 1. `meta.rules` on packages

Packages gain a `meta.rules` attribute. Same shape as
`scorecard.rules` today: a nested attrset `{ category.ruleName = rule; }`.

```nix
# kix/packages/cert-manager/default.nix
{
  meta = {
    version = "1.16.2";
    provides = [ "certificates" ];
    defaultAliases = [ "certManager" ];

    # Rules this package contributes to the cluster scorecard.
    # Active only when at least one cert-manager instance is deployed.
    rules = {
      architecture.noInlineCertificate = {
        description = "Certificates should be created via certManager.out.mkCertificate, not hand-rolled";
        level = "package";
        severity = "warning";
        tags = [ "architecture" "di" "cert-manager" ];
        check = { resources, meta, ... }:
          let
            ownsCerts = builtins.elem "certificates" (meta.provides or []);
            isCert = r: lib.hasPrefix "cert-manager.io/" (r.apiVersion or "");
            hasCapStamp = r:
              (r.metadata.annotations or {})."kix.dev/capability" or null == "certificates";
            offending = builtins.filter (r: isCert r && !(hasCapStamp r)) resources;
          in
            if ownsCerts then [] else
              map (r: {
                message = "${r.kind} '${r.metadata.name or "?"}' is hand-rolled — use certManager.out.mkCertificate scope {...}";
              }) offending;
      };
    };
  };

  build = { scope, lib, self, config, ... }: {
    root = {
      resource = self.operator;
      out.mkCertificate = consumerScope: args:
        consumerScope.mkResource (args // {
          annotations = (args.annotations or {}) // {
            "kix.dev/capability" = "certificates";
          };
        });
    };
  };
}
```

Two things to notice:

- The fingerprint *and* the builder that stamps `kix.dev/capability`
  live in the same file. Changing one without the other is impossible.
- The check function is generic — it's almost literally the body of the
  current `architecture.capabilityOwnership` rule, specialized to
  certificates. We'll factor out a `kix.rules.capabilityCheck` helper so
  packages don't reimplement this pattern.

### 2. Collection in `eval/cluster.nix`

During `buildCluster`, after `allInstances` is populated, walk the
instance list and fold `_meta.packageMeta.rules or {}` into the
effective scorecard ruleset:

```
effectiveRules =
  clusterConfig.scorecard.rules
  // collectPackageRules allInstances;
```

Merge semantics:

- **Only deployed packages contribute.** We walk `allInstances`, not
  `availablePackages`. A package sitting in the registry but not
  instantiated stays silent.
- **Cluster rules win on collisions.** If both a package and the cluster
  config define `architecture.noInlineCertificate`, the cluster's
  version takes precedence. This preserves the existing operator
  override story.
- **Collected per package class, not per instance.** Two
  cert-manager instances don't double-register the same rule.
  Deduplication key: the package's origin path (so two imports of the
  same package collapse) or a fallback `meta.id` if the path isn't
  stable across flake reloads.
- **Collection is side-effect-free.** Rules are read via
  `peekPackageMeta`, not by building anything. A package shipping a
  broken rule fails the scorecard phase, not the package build.

### 3. Refactor `architecture.capabilityOwnership`

Today that rule is a single library rule with a private fingerprint list.
Post-refactor:

- `kix/lib/rules/architecture.nix` no longer ships fingerprints. It
  exports a `mkCapabilityCheck { capability; detect; describe; suggest; rationale; }`
  helper that returns a rule record.
- `packages/persistent-volume-claim` ships
  `meta.rules.architecture.noInlinePVC = mkCapabilityCheck { ... }`.
- `packages/reflector` ships
  `meta.rules.architecture.noInlineReflection = mkCapabilityCheck { ... }`.
- `packages/cert-manager` (new) ships the same for certificates.

The cluster scorecard picks them all up automatically, provided each
package is actually deployed.

### 4. Enabling

Cluster definitions enable the collector with a single flag:

```nix
scorecard = {
  enable = true;
  collectFromPackages = true;   # default: true once settled
  rules = {
    # Cluster-owned rules still go here and still win on collisions.
    architecture = kix.rules.architecture;  # library staples
  };
};
```

## The actual question: is this valuable?

Settling the mechanics is the easy part. The design question is
**whether capability-owner-contributed rules are a pattern that will
attract real use**, or whether they'll mostly stay empty and the
cluster module system will remain the canonical place to define rules.

### Case for packages shipping rules

These are hypotheses, not observations. Each needs validation before the
refactor earns its keep.

1. **Architecture rules naturally live with capability owners.**
   The strongest case: `architecture.capabilityOwnership`-style rules
   are always a contract between "I own this kind" and "everyone else
   must use my builder". The contract is easiest to keep honest when
   both halves live in the same file. Every new capability owner brings
   one new rule, and that rule is trivially correct (the owner literally
   knows which kinds it owns). This is the grafana/stackgres migration
   scaled out.

2. **Operator packages have opinions about how they're consumed.**
   cert-manager wants you to use `Certificate` CRs, not raw `tls.crt`
   Secrets. prometheus-operator wants you to use `ServiceMonitor`, not
   scrape configs in the Prometheus CR. external-secrets-operator
   wants `ExternalSecret` CRs, not imperative Secrets. These are all
   "if you installed me, there's a right way to use me" rules. They
   aren't generic — they belong to the operator.

3. **Third-party / in-house packages can't edit `kix/lib/rules/`.**
   A team shipping an internal custom-resource package (e.g. a
   homegrown `Workflow` CRD) has no way to contribute a smell that
   catches misuse of their own CRD without forking kix. Package-owned
   rules are the only distribution mechanism that scales to "packages
   not in kixpkgs upstream".

4. **Activation matches intent.** A rule that says "hand-rolled
   certificates are a smell" only makes sense when the cluster actually
   has cert-manager deployed. Otherwise the rule is hectoring the user
   to adopt a tool they haven't installed. Package-owned rules activate
   iff the package is deployed — this is semantically tighter than
   cluster-wide rules, which fire everywhere regardless.

5. **No central maintenance burden.** The library rule set stops growing
   as the package registry grows. kix/lib/rules/ becomes a small
   collection of *cross-cutting* rules (security baselines, reliability
   defaults) and packages own their *capability* rules. Two different
   maintenance models, two different cadences.

### Case against

1. **Packages will not ship rules.** Maintainers of upstream packages
   have no incentive to write scorecard rules — they don't use kix, they
   ship Helm charts and YAML manifests. The rules will be written by
   kix maintainers either way. If so, the file they live in doesn't
   matter and `kix/lib/rules/` is fine.

2. **Cluster operators already have the right place.** The module
   system (`kix.modules.*` + `scorecard.rules`) already lets a cluster
   op add rules per-cluster or per-module. For most actual rules,
   that's the correct location — the operator knows their context.
   Adding another layer confuses "who owns this rule".

3. **Importable rulesets from the cert-manager team are more portable.**
   If we want third-party rule distribution, a cluster op can
   `import` a rule module from cert-manager's repo and add it to
   `scorecard.rules`. That's fewer moving parts: no collection phase,
   no per-instance activation logic, no `peekPackageMeta` plumbing.

4. **Activation scoping is weak signal.** "Only fire when the package
   is deployed" sounds tighter than always-on, but in practice the rule
   should fire in every *other* package's scope, not the owning
   package's. Activation based on deployment is really saying
   "whenever someone could be using me" — which is ~everywhere in a
   mature cluster. The scoping value-add is small.

5. **It couples package definitions to scorecard implementation details.**
   Every package file now has a `meta.rules.architecture.noInlineX`
   stanza with a closure. If the scorecard API changes, every package
   needs editing. Today only `kix/lib/rules/` needs editing.

### What would actually validate this

Before committing to the refactor, we want concrete answers to:

1. **How many smells are even capability-scoped?** Enumerate all the
   smells we can think of over the next month. Bucket them:
   - *Capability-scoped* (hand-rolled X when capability owner exists):
     storage, reflection, certificates, external-secrets, service-monitor,
     sealed-secrets, …
   - *Cross-cutting* (security baselines, reliability defaults,
     governance): hostNetwork, missing resources.limits, no PDB, etc.
   - *Cluster-specific* (tag taxonomy, naming conventions, owner
     required): lives in the cluster module system.
   If capability-scoped is the biggest bucket by count and by churn,
   package-owned is valuable. If cross-cutting dominates, it isn't.

2. **Do package-owned rules actually reduce churn?** Track the next 5
   new smells we want to add. For each, ask: would this have been a
   smaller diff as a package-owned rule vs a library-owned rule? If
   4/5 is yes, ship it. If 3/5 or worse, don't.

3. **Does cert-manager actually want one?** We can write the
   cert-manager package tomorrow and see whether its
   `noInlineCertificate` rule looks "native" (belongs next to
   `mkCertificate`) or "bolted on" (belongs in the central rule file).
   Gut-feel test: if the fingerprint and the builder reference each
   other (both know about `kix.dev/capability: certificates`), they
   want to live together.

## Decision

Not settled. Shipped `kix/lib/rules/architecture.nix` with a static
two-entry fingerprint list. Plan:

- Leave the library rule in place.
- Add cert-manager package + its rule as a static entry in the library
  next time it comes up. That gives us a third data point.
- Re-open this RFC once we have 4–5 capability-scoped smells and can
  answer the three validation questions above.
- Meanwhile keep `meta.rules` reserved as a forward-compatible key:
  packages can set it, the collector just isn't wired yet.

## What to watch for

Signals that we should refactor sooner:

- A third party asks "how do I ship a scorecard rule with my custom
  package without forking kix?" — the distribution pressure case.
- A capability owner rename (e.g. reflector gets replaced by a new
  cross-ns secret controller) causes a painful cross-file edit —
  the co-location case.
- `kix/lib/rules/` starts accumulating `if provides ... else ...`
  special-cases for specific packages — the ownership smell.

Signals that we should not:

- Cluster ops keep wanting to tune/disable rules, not add new ones.
  Meaning the pressure is on override ergonomics, not contribution.
- Every new rule we actually write turns out to be cross-cutting
  rather than capability-scoped.
- `peekPackageMeta` gets expensive when walking all `allInstances`
  for rule collection. (Unlikely, it's already used for other things.)

## Open questions

- **Merge semantics on collisions.** Settled direction: cluster rules
  win. Still need to specify attribute-level behavior — does a
  cluster-level `{ severity = "error"; }` on a package-contributed rule
  override just severity, or replace the whole rule? (Probably severity
  only, reusing the existing `ruleOverrides.byRule` mechanism.)

- **Rule identity across package versions.** If a package ships
  `architecture.noInlineCertificate` in v1.16 and drops/renames it in
  v1.17, the cluster op's `ruleOverrides.byRule."architecture.noInlineCertificate"`
  silently becomes a no-op. No clean answer; warnings on unmatched
  overrides would help (and are probably a separate small feature).

- **Dev UX for writing a rule.** Package authors need a cheap way to
  iterate on a rule without going through a full cluster build. Spike:
  a `nix eval .#rules-test-<package>` helper that runs the package's
  rules against fixture manifests. Not a blocker, just something the
  refactor should budget for.

- **Factoring the capability-check helper.** Design-wise, we want a
  `kix.rules.mkCapabilityCheck { capability; detect; … }` that both
  library and package rules consume. The question is whether it lives
  in `kix/lib/rules/architecture.nix` (same file as the existing rule)
  or a new `kix/lib/rules/lib.nix`. Probably the former.

## Related work

- RFC 60 (scorecard rules design) — the base rule engine.
- RFC 80 (structured diagnostics) — how scorecard findings are surfaced
  alongside other eval-time diagnostics.
- The grafana/stackgres migration landing commit — where this problem
  first bit.
