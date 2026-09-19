# 143: Pod spread and failure zones

**Status:** Implemented (2026-09-19, same session as the design). Open questions lifted to `ROADMAP.md` § Open design questions. §3's replica arithmetic was corrected during implementation, see the note there.
**Related:** `127_compiler_target_model.md` (§4 substrate vocabulary, §6 "zones → derived spread"), `115_pod_spec_hardening_pass.md` (same interception point, defers anti-affinity), `121_netpol_as_plugin.md` (the hook contract this extends; shipped as `kix/lib/eval/hooks.nix`), `106_ops_lifecycle_verbs_and_capacity_check.md` §2.5 (single-node module), `interesting_thoughts/69_hardware_driven_scheduling.md`, `housekeeping/2026-09-19-no-standard-way-to-place-pods-across-failure-zones.md`

## Context

Fourteen packages write pod anti-affinity or topology spread by hand, each
with its own option names and defaults (`enableAntiAffinity` plus
`antiAffinityTopologyKeys` in `kix/packages/ingress-nginx/default.nix:186`,
a local `antiAffinity` function in the two VictoriaMetrics packages, inline
terms in valkey, caddy, n8n, external-dns, openebs and the rest). Every one of
them names a `topologyKey` as a string literal, so every one of them guesses
what a failure zone is on the cluster it ends up on.

The cluster already knows. `cluster.capabilities.multiNode`
(`kix/lib/modules.nix:325`) is set by the kind, scaleway and ovh flavors and by
`ludo/cluster.nix:20`, and no package reads it. `availabilityZones`
(`modules.nix:335`) is declared and never set or read. So ludo, one node, still
renders ingress-nginx pods that ask to spread across hostname and zone.

The mechanism to fix this has shipped. `hooks.workloadInterceptors`
(`modules.nix:570`, run from `sealWorkload` in `kix/lib/scope/builders.nix:160`)
sees every native and Helm-imported workload before `builtins.toFile` seals
it, with `ctx.cluster.config` in hand. Today a hook result may carry
`requires`, `resources` and `warnings`. It cannot patch the pod template. That
is the one lib change this design needs, and doc 115 needs the same one.

Doc 127 §4 already reserved the schema slot (`cluster.substrate.topology`) and
named this derivation as the first consumer of `topology.zones`. This doc is
the mechanism.

## Design

### 1. The compiler derives spread; nobody writes it

A `spread` workload interceptor adds `topologySpreadConstraints` to every
Deployment and StatefulSet with `spec.replicas > 1`, one constraint per
failure-domain key the cluster declares (§2), `maxSkew = 1`, label selector
taken from the workload's own selector. DaemonSets and Jobs are skipped: a
DaemonSet is placed by definition and a Job's parallelism is throughput, not
availability.

The intent is already in `replicas`. The mechanism is derivable from cluster
facts. This is the netpol move applied to scheduling (PRINCIPLES §10:
automation over brevity), and it deletes the fourteen hand-rolled blocks.

Author-written fields win per field. If the workload input already carries
`topologySpreadConstraints`, the derived list is dropped whole; the two are
never merged element-wise. `affinity.podAntiAffinity` written by hand is left
alone and does not suppress derivation, since the two fields are orthogonal in
the scheduler and a package that wrote anti-affinity for one reason (a quorum
that must never co-locate) still wants zone spread.

### 2. The failure-zone key is a cluster fact, resolved once

A read-only option `cluster.topology.failureDomainKeys :: [str]` is computed
from the facts the cluster declares:

| Declared | Keys, in order |
|---|---|
| `availabilityZones` known, length > 1 | `topology.kubernetes.io/zone`, `kubernetes.io/hostname` |
| `availabilityZones` known, length ≤ 1 | `kubernetes.io/hostname` |
| `availabilityZones` null (unknown) | `kubernetes.io/hostname`, plus one info diagnostic: "zones unknown, spreading across hosts only" |
| `multiNode = false` | `[ ]` (§4) |

Reads the existing `cluster.capabilities.multiNode` and `availabilityZones`.
Flavors fill `availabilityZones` where they can (scaleway and ovh node pools
carry a zone; kind sets `[ ]`).

**Upgrade note.** When doc 127's `cluster.substrate.topology` lands (zones,
racks, per-node zone facts), this table moves onto it as a rename, and gains a
rack tier (`topology.kix.dev/rack`) between zone and hostname. Nothing in the
interceptor or the escape hatches changes; only where the keys come from. Do
not build on 127's schema now, it is still an RFC.

Packages whose pods are rendered by an operator (VMCluster, SGCluster) never
pass through `sealWorkload`; a native StatefulSet such as valkey's does.
The operator-CR packages keep writing spread into the CR by hand, but
read `clusterConfig.cluster.topology.failureDomainKeys` for the key instead of
a literal. That is the dependency-injection form of the same fact.

### 3. Strictness is a cluster decision, defaulting to hard on zones

Soft spread (`ScheduleAnyway`) applied blind means a cluster can run without
the availability it looks like it has, and nothing says so. So strictness is
a cluster-level option, not a per-package guess:

```nix
cluster.spread.default = "hard-zones";   # "off" | "soft" | "hard-zones" | "hard"
```

| Value | Zone key | Hostname key |
|---|---|---|
| `soft` | ScheduleAnyway | ScheduleAnyway |
| `hard-zones` (default) | DoNotSchedule | ScheduleAnyway |
| `hard` | DoNotSchedule | DoNotSchedule |
| `off` | not emitted | not emitted |

On a cluster with no zones declared, `hard-zones` has no zone key to be hard
on and behaves as `soft` on hostname, with the §2 diagnostic. That is the
three-valued rule from doc 127: skip visibly, never silently.

**Replica arithmetic.** The session asked for an eval-time error when a
workload wants more replicas than there are zones under hard spread. With
`topologySpreadConstraints` and `maxSkew = 1` that case is legal (five
replicas across three zones lands 2/2/1). The same holds for hosts: the
first draft of this section claimed `hard` places at most one pod per node
and proposed refusing `replicas > nodes`; the kind proof showed a fourth
pod landing 2/1/1 on three nodes, so that check was wrong and was removed.
A hard constraint is even distribution, not one per domain. What strands
pods under `DoNotSchedule` is a domain that cannot take its share, such as a
zone with no ready nodes, which is a runtime condition and not an eval-time
count (§ Open questions).

The one-per-domain arithmetic the session had in mind is what
`requiredDuringScheduling` pod anti-affinity does, and §4 covers that for
hand-written rules.

### 4. Single node is a legalization gate

When `multiNode = false`:

- No constraints are derived (`failureDomainKeys = [ ]`). One info diagnostic
  per cluster, not per workload.
- A hand-written hard rule that can only ever leave pods Pending is an
  eval-time error naming the instance: `requiredDuringSchedulingIgnoredDuringExecution`
  pod anti-affinity on `kubernetes.io/hostname` with `replicas > 1`, or a
  `DoNotSchedule` spread on hostname with `replicas > 1`. Today
  `kix/packages/openebs/mayastor.nix:326` writes exactly this for its etcd; on
  ludo it would be refused at build, which is correct, since a three-member
  etcd cannot run there.
- Soft hand-written rules pass through untouched.

When `multiNode = null` (unknown) the same conditions produce warnings, not
errors.

The check lives beside `validators.checkDaemonSet` in
`kix/lib/scope/builders.nix`, which already reads a capability and refuses.
This closes the "required → preferred, or strip entirely" question doc 106
§2.5 left open: neither. Refuse hard rules, do not derive anything, and leave
what the author wrote alone otherwise. Downgrading a stated requirement is
the silent weakening §3 rejects.

### 5. Escape hatches: the operator's, then the maintainer's

Spread is the operator's call. Two levels, both the same enum as §3:

```nix
# clusters/ludo.nix
cluster.spread.default = "hard-zones";      # cluster-wide
instances.apps.n8n = {
  package = kixpkgs.n8n;
  spread = "off";                           # this one instance
};
```

`instances.<ns>.<name>.spread` sits next to `package`, `deps` and
`extraDeps` in the instance submodule (`modules.nix:43`) and overrides the
cluster default for that instance. Turning spread off for one workload never
means reaching into its pod template from the cluster definition.

A package maintainer may opt a package out with `meta.spread = false`. The
interceptor reads it from `ctx.packageMeta` (already passed, see
`builders.nix:191`), skips derivation, and emits a warning on the hook's
`warnings` channel naming the instance and the package, so every cluster sees
it (the scorecard is off in most clusters, so this does not ride a scorecard
rule). The warning is the point: the opt-out exists for the genuine case (a
workload whose replicas are shards that must co-locate with their storage)
and should read as unusual in every build log. `meta.spread` takes only
`false`; a package cannot raise strictness, because that is the operator's
decision.

### 6. The hook contract grows a `podSpec` channel

`hooks.workloadInterceptors` results gain one key:

```
fn :: ctx -> { requires ? [ ]; resources ? [ ]; warnings ? [ ]; podSpec ? { }; }
```

`podSpec` is merged into `spec.template.spec` of `workloadInput` in
`sealWorkload` before `scopeMkResource`, per field at the top level of the
pod spec, author wins. `channelResultKeys` in `kix/lib/eval/hooks.nix` gains
the key so a typo still throws. Two interceptors patching the same field
resolve by hook priority (lower wins, same as execution order), which keeps
the merge deterministic and content-addressed.

Fixpoint rules are unchanged from doc 121 §1b: the interceptor reads the raw
`workloadInput` (replicas, selector, existing constraints) and outer-fixpoint
cluster config, and never forces the resource under construction. The
derived constraints become part of the sealed manifest, so every
multi-replica workload's store path changes once when this lands (§ Migration).

Doc 115's hardening profile uses the same channel. It should land as a second
interceptor with its own priority, not be folded into this one.

### 7. Phase 2: PodDisruptionBudget rides the same gate

The condition "replicas > 1 on a multi-node cluster" is also the condition
under which a PDB is worth having. Phase 2 has the same interceptor emit a
`PodDisruptionBudget` with `maxUnavailable = 1` and the workload's selector on
the `resources` channel (the channel already exists; netpol uses it for
CNPs), honoring the same `spread` enum: `off` emits no PDB. An author-written
PDB in the package wins, detected by selector match against the instance's
resources.

This graduates `hasPDB` (`kix/lib/rules/reliability.nix:157`) from a warning
into a derivation, as doc 127 §4 proposed. Phase 2 is separable so spread can
ship first, and it is the phase that touches deploy-time behaviour (drains,
doc 81), so it gets its own review.

## Alternatives considered

- **Package declares intent (`spread = true`, `scope.spread`).** Rejected in
  session. Adds a DSL word for information `replicas` already carries, and
  leaves every package that forgets it without spread.
- **Packages keep standard fields, cluster injects only the key.** The
  smallest change; rejected because the fourteen blocks stay, each still
  choosing its own weight, skew and strictness, and the operator still cannot
  turn one off without a package option.
- **Soft spread by default.** Rejected in session: silent loss of
  availability. Strictness is a cluster option with a hard-on-zones default.
- **Downgrade hard hand-written rules on single node.** Rejected: weakens a
  stated requirement without saying so. Refuse instead.
- **Author-wins as the only escape hatch.** Rejected: turning spread off from
  the cluster side would mean overriding a pod template field from the
  cluster definition, which is not an operator-shaped action.
- **Waiting for doc 127's substrate schema.** Deferred, not rejected: build on
  `cluster.capabilities` now, rename when 127 lands (§2 upgrade note).

## Migration

1. Lib: `podSpec` channel in `sealWorkload` and `hooks.nix`; the
   `cluster.spread`, `instances.*.spread` and `cluster.topology.failureDomainKeys`
   options; the `spread` plugin at `kix/lib/plugins/spread/module.nix`
   beside netpol; the single-node validator.
2. Flavors: `availabilityZones` on scaleway and ovh where the node pool
   carries a zone; `[ ]` on kind.
3. Packages: delete the hand-written spread in caddy, n8n, valkey,
   external-dns, dns-exporter, python-app, kubevirt, openebs (non-etcd),
   victoria-metrics-agent, ingress-nginx (drop `enableAntiAffinity` and
   `antiAffinityTopologyKeys`). Keep mayastor etcd's required anti-affinity
   (a real quorum rule) and the operator-CR packages (victoria-metrics-cluster,
   victoria-metrics-alert), switching their key to
   `clusterConfig.cluster.topology.failureDomainKeys`.
4. Expected diff: none on ludo-kind (`multiNode = false`, nothing derived, no
   hand-written hard rules in that package set). On stage1 and stage2 every
   multi-replica workload changes once, gaining constraints, and the
   VictoriaMetrics CRs change if the key differs from the literal they carry.
5. Docs: `docs-legacy/HANDBOOK.md` capability table and flag list (`:921`,
   `:935`), `docs-legacy/FEATURE-CATALOG.md:182`, `docs-legacy/BEST-PRACTICES.md`
   (a short "you do not write spread" rule), `.claude/skills/kix-migration/SKILL.md:508`,
   `cli/README.md` if the diagnostics surface in `kix check`. Delete the
   housekeeping entry in the shipping commit.

## Open questions

1. **`minDomains`.** With `hard-zones` and three declared zones, should the
   derived constraint set `minDomains = 3` so a two-zone cluster that claims
   three fails visibly rather than packing? Leaning yes when
   `availabilityZones` is known.
2. **Zone outage under `hard-zones`.** The dead zone still counts as a
   domain, so replacement pods cannot land in the live zones until the
   nodes are removed. Is that acceptable as the default, or does the default
   want `hard-zones` only when zones ≥ 3? Needs an operator's answer, not a
   compiler's.
3. **StatefulSets with zone-pinned volumes.** A PVC in zone A pins its pod
   to zone A regardless of spread. Derivation is harmless there, but the
   `hard` replica-vs-node check may need to count per zone. Park until a
   package hits it.
4. **Where the per-instance `spread` enum meets 115's profile.** Both are
   cluster-side per-instance knobs on the pod template; whether they share a
   submodule (`instances.*.podPolicy = { spread; hardening; }`) is 115's call.
