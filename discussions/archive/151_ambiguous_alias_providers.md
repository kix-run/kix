# 151: Ambiguous alias providers in auto-instantiation

**Status:** Implemented in kixpkgs#156 (2026-09-28), as recommended in §3, with two additions: a dependency wired with `deps.<arg>` never pulls from the shelf and activates an optional instance of any name, and optional instances are ranked as `resolveArg` ranks them (managed over import, then the requester's namespace) before a remaining tie throws. The §4 questions stayed open and are in `ROADMAP.md § Open design questions`.
**Related:** `127_compiler_target_model.md` (demand-rooted stock catalogs, role bindings), `132_di_visibility_first_principles.md` (resolution ladder), `148_clickhouse_packages_plan.md` (two implementations behind one alias), `27_auto_instantiation.md`, `120_compiler_theory_mapping.md` (weak/strong symbols, link-time `out` typing)

## 1. Problem

When a required dependency has no instance, auto-instantiation looks its
argument name up in `availablePackages`. Several packages can answer the same
name, and the lookup keeps whichever one sorts first. Nothing reports the
collision.

- `kix/lib/eval/auto.nix:93-113` builds `availableByKey` with
  `builtins.listToAttrs`, which keeps the first entry for a duplicate key.
  Entries are ordered by `builtins.attrNames`, so the package whose name sorts
  first wins every shared key. A package name counts as a key with the same
  weight as an alias.
- `kix/lib/eval/auto.nix:166-168` builds `optionalByKey` the same way, so two
  optional instances that answer one name have the same defect.
- The observed failure (`housekeeping/2026-09-27-auto-instantiation-picks-first-alias-claimant.md`,
  on `checks/every-package-evaluates`): with `availablePackages = packages`,
  an alertmanager with no operator instance gets `kube-prometheus-stack`
  instead of `prometheus-operator`, and fails later with
  "attribute 'mkAlertmanager' missing". `kube-prometheus-stack`'s `out`
  (`kix/packages/kube-prometheus-stack/default.nix:378-386`) has the four
  monitor builders but neither `mkAlertmanager` nor `mkPrometheus`.
- `kix/package-eval.nix` on that branch removes `kube-prometheus-stack` from
  its `availablePackages` to avoid it.

The rest of the compiler already refuses this kind of ambiguity:

- `resolveArg` (`kix/lib/eval/resolve.nix:58-125`) throws when a dependency
  matches two instances in one namespace, or one in each of two namespaces,
  and tells the user to set `deps.<arg>`.
- `findRoleProvider` (`kix/lib/eval/hooks.nix:150-190`) throws on two managed
  providers of one role ("Declare exactly one provider for this role"), and
  `checkRoleBindings` forces that eagerly.
- Annotation domains with two declarers throw (`hooks.nix:57-96`).

Auto-instantiation is the one place where the compiler makes the choice
itself, and it does so based on package names.

### Every collision in the catalog today

Computed by peeking the aliases of every directory under `kix/packages/`
(package name, `meta.roles`, `meta.defaultAliases`):

| Key | Claimants (in the order that decides today) | Required by |
|---|---|---|
| `prometheusOperator` | kube-prometheus-stack, prometheus-operator | alertmanager, prometheus, prometheus-default-rules (all required) |
| `clickhouse` | clickhouse (name), clickhouse-cluster | clickhouse-database (required) |
| `prometheus` | kube-prometheus-stack, prometheus (name), prometheus-operator, victoria-metrics-operator | only optional `prometheus ? null` deps |
| `prometheusServer` | prometheus, victoria-metrics-cluster | grafana (optional) |
| `redis` | redis (name), valkey | none |
| `secret` | secret (name), secret-ref | none |
| `network-policy-enforcer` | cilium, cilium-external | role; not an argument name, so never a shelf demand |

Two keys are live defects: `prometheusOperator` silently picks the Helm stack,
and `clickhouse` silently picks the single-node implementation, although doc
148 says "the cluster definition chooses". The `prometheus` row is also the
trigger ROADMAP names for a `monitoringProvider` capability ("right shortcut
for two providers and the wrong one for three"): the catalog now has three
alias claimants plus the `prometheus` package name.

### Who hits it today

No cluster in the repo does. Evaluating every cluster that sets
`availablePackages` shows what it auto-instantiates:

| Cluster | Auto-instantiated |
|---|---|
| ludo-kind | stackgres-operator |
| immich | storage-classes, valkey |
| harbor | cert-manager |
| auto, auto2 | valkey (+ optional coredns) |
| ingress-netpol | nothing |

None of these keys is contested. `kix/package-eval.nix` is the first
consumer to demand contested keys, because it puts every package in a cluster
of its own with the full catalog on the shelf. A catalogue bump can create
the problem in an existing cluster without any change to that cluster: a new
package whose name sorts before the current claimant would take over the key.

## 2. Options

**A. Refuse at the point of demand.** When a demanded key has more than one
shelf claimant, throw, naming the key, the requesting instance, every
claimant and why it claims the key, and the ways to choose. The check is
lazy: an ambiguous key that nothing demands is fine, so
`availablePackages = packages` keeps working. The choice is made with
mechanisms that already exist: an optional instance (checked before the shelf,
`auto.nix:225`, and created only on demand), or removing claimants from
`availablePackages`.

**B. Cluster-level preference map.** A new option such as
`autoProviders.prometheusOperator = "prometheus-operator"`. It works, but it
restates what an optional instance already says, adds a second vocabulary
keyed on alias strings, and has no driver beyond this bug.

**C. Reuse `cluster.roles`.** Promote contested aliases to roles and select
with `cluster.roles.<name>.provider`. Roles are a closed vocabulary with an
`outContract`, admitted only with a consumer (`kix/lib/eval/roles.nix:1-17`),
and doc 127 made `provider` a vendor string that nothing may branch on.
Selecting a package through it contradicts both. Uniqueness of role providers
already follows A's policy, so A gives roles and aliases one rule without
merging the vocabularies.

**D. Package-declared priority.** A numeric priority, a `meta.defaultFor`,
or "weak" aliases that do not count on the shelf. The package author then
decides which implementation every cluster gets, which is the choice
principle 10 gives to the cluster. For `clickhouse` and `prometheus` both
claimants are legitimate and the right answer differs per cluster. A weak
alias fits `kube-prometheus-stack` narrowly, but that package's real problem
is a partial `out` (open question 2), not its rank.

**E. Filter candidates by what the consumer needs.** Drop claimants whose
`out` lacks what the consumer reads, or whose version fails the consumer's
constraint (ROADMAP: "whether a consumer's version requirement should choose
what auto-instantiation creates"). Consumers do not declare the `out`
attributes they read, and checking `out` before the fixpoint would force
provider instances out of order (`roles.nix:13-17`). This depends on doc
120's link-time `out` typing. When it lands it narrows the candidate list
before A's uniqueness check. It does not replace that check, because two
conforming providers still need a choice.

**F. Keep first-wins, add a warning.** A warning that decides anyway is the
silent failure principle 6 calls a bug. Whether the outcome is correct still
depends on package names.

### Scoring

| | 1 graph | 3 determinism | 5/6 unrepresentable, actionable | 9 personas | 10 DI by cluster | 13 wiring first | 14 no hypotheticals |
|---|---|---|---|---|---|---|---|
| A | selection is an instance in the graph | outcome no longer depends on unrelated names | error names claimants and fix | platform team chooses | yes | optional instance is wiring | no new API |
| B | a map beside the graph | yes | yes | platform team | yes | new config surface | new API, no driver |
| C | yes | yes | yes | mixes SRE environment facts with platform choice | yes | overloads roles | breaks closed vocabulary |
| D | yes | depends on catalog-wide priority | no error, wrong pick possible | package author decides | no | `meta` as plumbing | new meta field |
| E | yes | yes | partial | yes | yes | yes | blocked on 120 |
| F | n/a | no | no | n/a | no | n/a | n/a |

## 3. Recommendation: A

### User-facing behavior

Nothing changes for an uncontested key or a key with an instance. For a
contested key the build stops with:

```
kix: dependency 'prometheusOperator' of monitoring/alertmanager has no instance, and 2 packages in availablePackages provide it:
  kube-prometheus-stack (meta.defaultAliases)
  prometheus-operator (meta.defaultAliases)
Kix does not choose between them. Declare the one this cluster uses as an optional instance, which is created only when something depends on it:
  instances.<namespace>.prometheus-operator = { package = packages.prometheus-operator; optional = true; };
or remove the others from availablePackages.
```

The claim source is one of `package name`, `meta.roles`,
`meta.defaultAliases` or `availablePackages.<name>.aliases`. For a weak role
demand the first line reads `role 'storageClasses', needed by <ns>/<inst>,
has no provider, and 2 packages ...`, and the text also suggests setting
`cluster.roles.<role>.binding` when the environment provides the role.

Two optional instances answering one name throw in the same shape
("... 2 optional instances provide it: a/x, b/y. Keep one of them and
remove the other."). Before counting, optional
imports are dropped when a managed optional instance also answers, mirroring
the managed-over-import filter in `resolveArg` (`resolve.nix:87-88`), so a
flavor's optional `platform-storage` import does not collide with a cluster's
own optional storage instance.

The selector for a cluster is an optional instance. The ClickHouse case
reads:

```nix
instances.data.clickhouse = {
  package = packages.clickhouse-cluster;
  optional = true;
};
```

### Changes in `kix/lib`

- `eval/auto.nix`: `availableByKey` and `optionalByKey` become key to list of
  claimants (`lib.groupBy` or a fold, as `buildResolutionIndex` already does
  at `resolve.nix:45-51`), each claimant recording its claim source. A
  `pickProvider` helper returns the single claimant or throws the message
  above. The closure operator and `autoInstanceList` call it. `? key`
  membership tests (`weakStockDemands`, the `newReq` filters) stay as they
  are. The throw only happens when a demand looks the key up.
- `mkItem` carries the requesting instance (`<ns>/<inst>`) for the message.
  The `genericClosure` key stays `dep@ns` / `role:dep`, so deduplication does
  not change.
- `meta.peekPackageAliases` (`meta.nix:104-121`) returns the claim source
  alongside each key, or `auto.nix` computes it from the three lists it
  merges.
- `modules.nix:157-167`: the `availablePackages` description says a
  contested name is refused and how to select.
- Docs: `docs-legacy/HANDBOOK.md` (auto-instantiation section),
  `docs-legacy/BEST-PRACTICES.md` (selecting among implementations, with the
  ClickHouse example), `.claude/skills/kix-migration/SKILL.md` (the
  two-implementations-one-alias pattern gains "the cluster selects with an
  optional instance"), `ROADMAP.md` (tick the item, link this doc).

### Migration

- `clusters/`, `ludo/`: no change. None demands a contested key (table in
  §1). The implementation PR proves this by building ludo-kind and the
  catalog clusters and comparing manifests with main: they must be identical.
- Flavors: no flavor contributes a contested shelf key today. `lithus`
  puts `lithus-storage` (role `storageClasses`) on the shelf, and so does
  `storage-classes` in the full catalog, so a lithus cluster with
  `availablePackages = packages` and a storage demand would now be refused
  (today it gets `lithus-storage` because it sorts first). No cluster in the
  repo combines them; open question 1.
- `kix/package-eval.nix`: the `removeAttrs` becomes a shelf selection with
  two entries and a comment that states the choice, not a workaround:
  `removeAttrs packages [ "kube-prometheus-stack" "clickhouse-cluster" ]`.
  Both packages are still evaluated, each as its own instance. Any future
  contested required key fails this check with the message above, which is
  the point of the check.

### Tests (`kix/lib/tests/default.nix`, `evalFails` style)

1. Two shelf packages with `defaultAliases = [ "x" ]`, a consumer requiring
   `x`: refused.
2. The same shelf with no consumer of `x`: builds.
3. Case 1 plus an optional instance answering `x`: builds, the optional
   instance is activated, neither shelf package is instantiated.
4. A package named `x` and a package aliased `x` on the shelf, consumer
   requires `x`: refused (the name gets no priority).
5. Two managed optional instances answering `x`, demanded: refused.
6. An optional import and a managed optional instance answering `x`: the
   managed one is activated.
7. Two shelf packages with `meta.roles = [ "storageClasses" ]`, a consumer
   with a weak `storageClasses ? null` dep: refused. With
   `cluster.roles.storageClasses.binding = "shadowable"`: builds, nothing
   pulled.

`builtins.tryEval` cannot read the message, so the wording is reviewed in
the PR by running case 1 through `nix eval` and pasting the output.

## 4. Open questions for Adam

1. **Flavor shelf entries against the generic catalog.** When a flavor's
   stock entry and a catalog package claim the same role, refuse (this doc's
   default, consistent and simple), or let flavor-contributed entries win
   (doc 127 treats the flavor as the more specific source, but
   `availablePackages` cannot currently tell who contributed an entry)?
2. **`kube-prometheus-stack`'s claim.** It answers `prometheusOperator` but
   lacks `mkAlertmanager` and `mkPrometheus`, so an explicit kps instance
   with a native alertmanager still fails with a missing attribute. Drop the
   alias, add the builders, or leave it for doc 120's `out` typing? This doc
   does not fix it.
3. **Shelf-entry `aliases` add, instance `aliases` replace.**
   `effectiveAliases` (`meta.nix:97-102`) replaces `defaultAliases` with
   instance aliases; `peekPackageAliases` (`meta.nix:104-121`) adds entry
   aliases to them. Aligning the shelf to "replace" would give a third
   selector (`availablePackages.kube-prometheus-stack.aliases = [ ]`). Worth
   doing for consistency alone, or wait for a driver?
4. **Sugar over the optional instance (option B).** Recommended no until
   selecting providers becomes repetitive across real clusters.
