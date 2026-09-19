# 145: Availability level

**Status:** Implemented (decisions taken 2026-09-19, built the same day), Design Doc
**Related:** `archive/143_pod_spread_and_failure_zones.md` (spread, PR #115), `127_compiler_target_model.md` (substrate facts), `115_pod_spec_hardening_pass.md` and `110_alerts_as_graph_resources.md` (cluster-level profile read by packages), `132_di_visibility_first_principles.md` (namespace-keyed policy)

One cluster setting says how much failure a workload must survive. Packages
turn it into their own replica counts, quorums and replication. The
compiler derives the default from the substrate, carries the value to every
package, folds the spread strictness of doc 143 into it, and checks the
result.

## 1. Context

Three facts from the tree on 2026-09-19:

- Packages express high availability in 39 replica-shaped options with no
  shared name or default: `replicaCount` defaults to 1, 2 or 3 depending
  on the package, StackGres has `instances`, VictoriaMetrics has
  `replicationFactor` plus a per-component count, valkey adds
  `sentinel.enabled`, harbor has four `replicas` fields. None of them
  looks at the cluster.
- `ludo/services.nix` turns Sentinel off and drops valkey to one replica,
  with a comment that three replicas on one node share the node's fate and
  cost three times the memory. That is an availability decision applied by
  hand, and its trigger is a fact the compiler already holds:
  `cluster.capabilities.multiNode = false`.
- The advertised channel for one operator value to reach every package,
  the `global` option, does not work (housekeeping, 2026-09-19).

Doc 143 shipped the placement half: every multi-replica workload is spread
across `cluster.topology.failureDomainKeys`, with a separate strictness
enum, `cluster.spread`. This doc supplies the missing input, replica
intent, and retires the separate enum.

## 2. The vocabulary

```nix
cluster.availability.default = "zone";   # "none" | "pod" | "node" | "zone"
```

The value names the largest thing whose loss must not cause downtime.

| Level | Promise | Needs from the substrate |
|---|---|---|
| `none` | Downtime on any failure or update is accepted. | nothing |
| `pod` | A pod crash or a rolling update causes no downtime. | nothing |
| `node` | The loss of one node causes no downtime. | `multiNode = true` |
| `zone` | The loss of one zone causes no downtime. | two or more `availabilityZones` |

Prior art: Gardener's `highAvailability.failureTolerance.type: node | zone`
is the same model. OpenShift's `infrastructureTopology: SingleReplica |
HighlyAvailable` is the same delivery, one cluster value every operator
reads to pick its replica count, with a coarser vocabulary.

`region` is not a value yet. Nothing in the tree has regions; doc 127 puts
them in the substrate vocabulary and this doc gains the value when a
cluster declares one.

## 3. Derivation from the substrate

The default is the largest level the substrate can honour:

| `multiNode` | `availabilityZones` | Derived default |
|---|---|---|
| `false` | any | `none` |
| `true` | two or more | `zone` |
| `true` | one, `[ ]` or unknown | `node` |
| `null` (unknown) | any | `node`, plus one warning per cluster |

`none` on a single node, not `pod`, because the people on one node are the
people counting memory. A single-node operator who wants rolling updates
sets `pod` in one line.

The substrate caps every level. A cluster or instance that asks for `zone`
without zones, or `node` with `multiNode = false`, is an eval error; with
`multiNode = null` it is a warning. This is the three-valued rule of doc
127 and `validators.checkSpreadFeasible`, applied one layer up.

## 4. The ladder

```nix
cluster.availability.default = "node";              # the cluster
instances.data.postgres.availability = "zone";      # one instance
```

Two rungs. The instance field lives beside `package` and `config`, not
inside `config`, because this is the operator's decision and a package must
not be able to set it. An instance may exceed the cluster default up to
what the substrate allows; the cluster default is only a default.

A namespace rung (`namespaces.<ns>.availability`) is not built until a
cluster runs two environments side by side and wants them treated
differently. Adding it is a third lookup in the same resolving function.
The namespace-keyed shape already exists in `scorecard.ruleOverrides.byNamespace`
and doc 132's `cluster.di.policy.namespaces`.

## 5. The package contract

### 5.1 Delivery

Every package receives the resolved level as a function argument named
`availability`, beside `scope`, `lib` and `kix` (a system argument in
`kix/lib/eval/resolve.nix`, never resolved as a dependency), and build
functions may take the same argument. Package option defaults read it, and
an explicit value in the instance config still wins by ordinary module
priority:

```nix
{ scope, lib, kix, availability }:
{
  options.replicaCount = lib.mkOption {
    type = lib.types.int;
    default = kix.availability.pick availability {
      none = 1;
      pod = 2;
      node = 2;
      zone = 3;
    };
  };
  options.sentinel.enabled = lib.mkOption {
    default = kix.availability.atLeast "node" availability;
  };
}
```

An argument rather than an injected option, because a package's option set
is a static attrset that cannot read its own evaluated config, and because
the level must be readable inside `build` too. `kix.availability.pick` and
`atLeast` are the whole helper surface: a lookup that refuses an
incomplete table and a comparison, so that a package's mapping is one
expression and reads the same in every file.

### 5.2 Every package maps the level

Reading the level is mandatory for every package that has a replica-shaped
option, including Helm-imported packages, whose wrapper translates the
level into chart values. The rule is enforced on the output, not the
source (§7), because the compiler cannot see whether a default was
computed or typed.

### 5.3 What each level obliges

- `none`: one of everything. No quorum, no replication.
- `pod`: more than one replica of anything stateless that is reachable
  from the package root. Nothing further for stateful components: a
  replica that cannot fail over is cost without benefit, so `pod` is
  standalone for valkey and StackGres alike.
- `node`: `pod`, plus the compiler's spread across hosts, plus whatever
  automatic failover the package has (Sentinel, StackGres replicas,
  VictoriaMetrics `replicationFactor = 2`).
- `zone`: `node`, plus the compiler's hard spread across zones, plus a
  quorum that survives the loss of a zone where the package has one
  (StackGres three instances, synchronous replication if the package
  supports choosing it).

A lowering table for the packages that anchor the design:

| Level | echo-server, caddy | valkey | stackgres-cluster | victoria-metrics-cluster | harbor |
|---|---|---|---|---|---|
| `none` | 1 | standalone | 1 instance | RF 1, 1 per component | 1 each |
| `pod` | 2 | standalone | 1 instance | RF 1, 2 per stateless component | 2 core, 1 rest |
| `node` | 2 | primary + replica + Sentinel | 2 instances | RF 2, 2 per component | 2 each |
| `zone` | 3 | as `node` | 3 instances | RF 2, 3 per component | 2 each |

The package chooses its numbers. There is no cluster-wide table of
minimum replicas; an operator who wants a different count sets it on the
instance.

### 5.4 Packages that cannot reach a level

A package declares its ceiling:

```nix
meta.availability.max = "pod";   # single-writer design: n8n on SQLite
```

A request above the ceiling is lowered to the ceiling with a warning that
names the package, the requested level and the ceiling. This replaces
`meta.spread = false` from doc 143, which said "do not touch my placement"
without saying why. A package that places itself writes standard
`topologySpreadConstraints` or `affinity` on the workload, and the
compiler leaves that workload alone (§6).

## 6. Spread and PDB fold in

`cluster.spread` and `instances.<ns>.<inst>.spread` are retired in the
same change. Placement strictness is a lowering of the level:

| Level | zone key | hostname key |
|---|---|---|
| `zone` | DoNotSchedule | ScheduleAnyway |
| `node` | ScheduleAnyway (if zones exist) | DoNotSchedule |
| `pod`, `none` | ScheduleAnyway (if zones exist) | ScheduleAnyway |

Two things stay keyed on replicas rather than on the level, as in doc
143: constraints and a PDB are derived for every Deployment or StatefulSet
with `replicas > 1`, whatever the level says. An operator who sets
`replicaCount = 3` under `none` has asked for availability; they get soft
spread and a PDB. And a workload whose author wrote
`topologySpreadConstraints` gets neither constraints nor a PDB from the
compiler: one signal, one meaning. This closes the per-workload opt-out
gap recorded in housekeeping on 2026-09-19.

`cluster.topology.failureDomainKeys` stays as it is, for packages whose
pods an operator renders. `meta.spread` is removed.

Every derived constraint carries `nodeTaintsPolicy: Honor`. Found on the
three-zone kind cluster while proving the `node` level: the tainted
control-plane node counts as a hostname domain with zero pods under the
default `Ignore`, so a hard hostname constraint refuses a second pod on
any worker. Doc 143's proof did not see this because its hard zone
constraint excluded the control plane for lacking a zone label. Honouring
taints excludes every node the pod could not land on anyway.

The same policy changes two other things. Nodes in a zone that has gone
dark carry `node.kubernetes.io/unreachable`, so they stop counting and
replacement pods may land in the live zones, which is most of the answer
to doc 143's zone-outage question. And pods scheduled while other nodes
are still coming up (kind applies seconds after creation; workers carry a
not-ready taint for a moment) pack onto the nodes that are ready and stay
there until the next rollout, where the default policy would have left
them Pending until the nodes were ready. `scripts/kind-spread.sh` waits
for every node to be Ready before applying, as a real deploy would.

Deployment constraints also carry `matchLabelKeys: [pod-template-hash]`.
Restarting the zoned deployment on kind left one zone empty (1/2/0):
during a rolling update the new pods are counted against the old ones,
which satisfy the skew until they terminate. Keying the count on the
revision label counts only the new pods, so a rollout keeps the spread.
StatefulSets replace pods in place and have no such label.

## 7. Verification

Packages promise to honour the level; the compiler checks the result. The
availability plugin's instance processor warns, always on rather than only
where the scorecard is enabled: under a resolved level of `node` or above, a
Deployment or StatefulSet reachable from the package root with fewer than
two replicas is reported with the level and the instance. The check starts
at `node`, not `pod`, because §5.3 lets a stateful component stay
standalone at `pod`; from `node` up every workload owes a second replica.
Ancillary workloads off the root path are not judged. The check cannot judge quorums
or replication generically, so `zone` is verified only as far as spread and
replica count go.

`validators.checkSpreadFeasible` keeps refusing hand-written hard rules
on a single node, reading the capability directly as before.

## 8. Migration

Every package with a replica-shaped option maps the level (§5.1). On
2026-09-19 that is the 35 packages found by
`grep -rn -E '(replicaCount|replicas|instances|replicationFactor) = lib.mkOption' kix/packages`,
plus the Helm wrappers, plus `meta.availability.max` on the single-writer
packages.

Existing deployed clusters keep their output. Every cluster in
`clusters/flake.nix` and `ludo/` was built before and after. ludo-kind is
byte-identical without edits: `multiNode = false` derives `none`, and its
build has no Deployment or StatefulSet above one replica. The explicit
`instances = 1`, `sentinel.enabled = false` and `replicaCount = 1` in
`ludo/services.nix` are now redundant and were left in place. The test
fixtures under `clusters/` declare no capabilities, so they derive `node`
with one warning and their outputs moved in the expected way (a second
replica, spread and a PDB on serving workloads and leader-elected
controllers); they exist to exercise the compiler and were not pinned. The
private clusters that run on real substrates live outside this repository
and will see the mapped defaults on their next build; pin there where the
old value should stay.

`clusters/test-spread.nix` and the `s`-prefixed tests in
`kix/lib/tests/default.nix` are rewritten from `spread = ...` to
`availability = ...`. HANDBOOK, FEATURE-CATALOG, BEST-PRACTICES §6.1, the
kix-migration skill and `kix/lib/architecture.md` lose `cluster.spread`
and gain `cluster.availability`.

## 9. Alternatives considered

- **A tolerated-failure count** (`tolerance = 1`): precise arithmetic,
  but says nothing about what fails, so it needs the level beside it.
  Kept as a possible second field if a package ever needs "survive two
  zones".
- **A grade** (`minimal | standard | resilient`, or a boolean `ha`): the
  OpenShift shape. Easy to say, but each package must decide what
  "standard" means for it, and it does not derive from the substrate.
- **Two axes** (compute level and state level): the most honest model of
  the two kinds of redundancy, rejected because no case was found where
  they should disagree that is not a per-instance override, and it
  doubles what every package must read.
- **A utility every package calls for spread** instead of derivation:
  discussed again on 2026-09-19 and kept as decided in doc 143. Helm
  imports and forgotten calls are the reasons.

## 10. Open questions

1. `region` as a fifth value: when the first multi-region cluster is
   declared.
2. The namespace rung: when a shared cluster needs it (§4).
3. Whether the build summary should report the cost of the level (how many
   workloads went above one replica, and which packages hit their
   ceiling), so an operator can see what `zone` bought.
4. Whether any package already declares an option named `availability`
   that the injected option would collide with; check at implementation.
5. Synchronous versus asynchronous replication under `zone` is the
   package's choice today. Whether it should be a second operator-visible
   knob is deferred until a cluster asks.

## 11. Phases

1. **Lib.** The option, the derivation, the ladder, delivery into
   `packageOptions`, `kix.availability.pick` and `atLeast`,
   `meta.availability.max`, the spread fold-in, the verification rule,
   tests.
2. **Packages.** All 35, the Helm wrappers, ceilings where needed.
3. **Clusters and docs.** Pin outputs where they would change, simplify
   ludo, rewrite the spread test cluster and tests, update the five docs,
   archive this doc and lift what remains open to `ROADMAP.md`.
