# 150: Scope the managed sweep to one Kix cluster

**Status:** Implemented in kixpkgs#161 (2026-09-28). Adam took every §7 recommendation: objects stay shareable between Kix clusters, unattributed objects are deleted only with `gc --hard --include-unattributed`, `kix snapshot save` takes the cluster name, phase 2 (§4.4) shipped in the same change, and D is deferred. D and the case of two clusters rendering one shared object differently are in `ROADMAP.md § Open design questions`.
**Related:** `91_cicd_organizational_patterns.md` (shared resource ownership), `129_scaling_axes_fleet_and_linking.md` (multi-activation), `111_operator_experience.md`, `ROADMAP.md` line 71 (multi-activation: exclusive or shared?)
**Source:** `housekeeping/2026-09-27-managed-sweep-ignores-cluster-label.md` (branch `docs/live-captures-linux`)

## 1. Problem

`fetch::sweep_managed` (`cli/kix/src/cluster/fetch.rs:311-319`) lists every
discovered kind with the selector `app.kubernetes.io/managed-by=kix` and
nothing else. `fetch_managed_resources` (`fetch.rs:303`) is the same sweep
without the unstamped bucket. Neither takes a cluster name. When one
Kubernetes cluster hosts two Kix clusters, every caller sees both.

The compiler does not stamp `kix.run/cluster` on ordinary objects. Only the
Activation record carries it (`kix/lib/core/activation.nix:92-95`, and the
CLI's `activation.rs:380`), which is why the record readers in
`cli/kix/src/cluster/activation.rs` (`list_cluster_records`, line 104) can
filter and the sweep cannot. `clusterLabels` (`kix/lib/modules.nix:12`) is a
user option, empty by default.

What each caller does with the extra objects today:

| Caller | Effect of another Kix cluster's objects |
|---|---|
| `kix gc --hard` (`kix-cli/src/commands/gc.rs:262`) | Judges them against this cluster's build only (`gc.rs:211-221`), so every one is `HashNotExpected`. With `--yes` they are deleted. Namespaces are skipped (`gc.rs:1019`); CustomResourceDefinitions are not. |
| operator reconcile (`kix-operator/src/controller.rs:389`) | `detect_changes_live` (`kix/src/cluster/apply.rs:451-457`) marks every stamped live object missing from this build as `Orphan`, and the operator always runs with `PrunePolicy::Delete` (`controller.rs:428`). |
| `kix deploy` fallback (`reconstruct_old_from_live`, `deploy.rs:779`) | Used when the Active record's store path is not on this machine or will not load (`deploy.rs:633-657`). That is the normal case for a deploy from CI or a second laptop. The other cluster's objects enter the old set, become orphans, and `--prune` deletes them. `never_pruned` (`scheduler.rs:1646`) spares only Namespaces and CRDs. |
| `kix diff` (`diff.rs:170`) | Reports them as removals. |
| `kix status` (`status.rs:291`, `:503`) | The flat view lists them; the package view shows them as unowned. |
| `kix snapshot save` (`snapshot.rs:54`) | Writes them into the snapshot, so a later `kix diff --from` shows them as removals. |
| `kix drift` (`kix/src/cluster/drift.rs:73`) | Reports on them. It takes no cluster argument by design (`cli.rs:711-716`). |
| `kix health` (`health.rs:153`) | Fetches them, then keeps only what is reachable from the Active record's hash, so only the resource count is wrong. |

**Worst realistic outcome.** `kix gc a --hard --yes` in a Kubernetes cluster
that also runs Kix cluster `b` deletes all of `b`'s Deployments, Services,
Secrets, standalone PVCs and cluster-scoped objects, and any CRD only `b`
ships, which takes every custom resource of that kind with it. The guide
warns about this (`docs/src/content/docs/how-to/operate-a-cluster/garbage-collect-stale-resources.mdx:47-53`), but
the gc module header still claims hard mode compares against "all active
activations" (`gc.rs:9-11`). An operator serving both clusters would keep
deleting the other cluster's objects on each reconcile, and the other's
reconcile would keep re-creating them.

The docs harness masks it: `resetCluster = true` on the
`how-to/policy-receipt-attestation` group (`docs/nix/captures.nix:703-708`
on `docs/live-captures-linux`) recreates the kind cluster so the tutorial
deployments are not reported as `how-to-application`'s removals.

## 2. What already records ownership

Every object a deploy touches carries `kix.run/activations`: the set of
identity hashes of the Activation records whose closure contains it.
`update_bookkeeping_annotations` (`apply.rs:897`) merges the deploying
record's hash into it on every applied object, and
`record_activation_on_skipped` (`apply.rs:491`) does the same for unchanged
ones, so the whole current closure carries the Active record's hash. The
set is multi-valued on purpose: `live_activation_hashes`
(`activation.rs:497-507`) documents that one object can be referenced by
activations of more than one cluster. An Activation's identity hash is the
root of its closure's Merkle tree (`activation.rs:10-13`), so membership in
this set means "applied as part of that store closure".

This is the reference-counted ownership doc 91 §"Governance" describes. It
is written but never read for ownership. The records map each hash to a
cluster through their `kix.run/cluster` label.

One gap: dead hashes. A leftover object is not re-stamped, so when gc
retires the records it names (`activation::retire_plan`), it names no live
record and no longer says which cluster it came from.

## 3. Options

**A. Compile-time `kix.run/cluster` label on every object, selected
server-side.** Add the label in `kix/lib/scope/labels.nix` and
`core/resource.nix:573`, and add `,kix.run/cluster=<name>` to the sweep's
selector.

**B. Ownership from Activation records, through `kix.run/activations`.** One
list of all Activation records gives this cluster's record hashes and every
other cluster's. Each swept object is attributed by the hashes it names. The
sweep keeps today's selector and filters client-side.

**C. Keep the sweep; guard prune.** Refuse to delete anything the previous
Activation did not contain.

**D. A runtime per-cluster label index** (`clusters.kix.run/<name>: ""`),
written by the bookkeeping merge patch beside `kix.run/activations`, so a
selector can find one cluster's objects.

**E. Per-cluster field manager** (`kix/<cluster>`) and read ownership from
`managedFields`.

| | P1 graph is the model | P2 store is the IR | P3 determinism | P6 compile-time | P16 day 2 | P18 planner |
|---|---|---|---|---|---|---|
| A | neutral | yes, in the build | **breaks for shared objects**: two builds of the same CRD or ClusterRole now differ, identity hashes diverge, the last deploy wins and each deploy re-applies | n/a | every object is unlabelled until redeployed; leftovers from retired records stay attributable | fixes read views |
| B | yes: the record-to-object edge is the ownership | yes: the hash is the closure root | build output unchanged | callers must state a scope (§4.1) | handles shared objects and retired domains; dead-hash leftovers need a rule (§4.2) | the planner reads attributed objects |
| C | partial | partial | n/a | n/a | read views stay wrong | executor-side check |
| D | duplicates B's fact | runtime state | fine | n/a | server-side selection; cluster names must fit the 63-character label name limit | same as B |
| E | no | no | changes ownership of every field on every object | n/a | conflicts on migration | no |

A fails P3 for the objects most likely to be shared, and every Kix cluster
already ships at least the Activation and PackageInstance CRDs
(`kixCRDs`, `core/resource.nix:610`). Today two builds of an identical object
share one identity hash and do not fight; A would make them. C leaves five
of eight callers wrong. D is B's fact written a second time; it only earns
its place if the LIST becomes a cost problem (P14). E is invasive for no
gain over B.

## 4. Recommendation: B

### 4.1 Types and functions

In `cli/kix/src/cluster/activation.rs`:

```rust
/// Which Activation records on this Kubernetes cluster belong to which Kix cluster.
pub struct Tenancy {
    pub cluster: String,
    /// Identity hashes of this cluster's records, every phase.
    pub own: HashSet<String>,
    /// Identity hash -> owning cluster, for every other record.
    pub others: HashMap<String, String>,
}

pub async fn tenancy(client: &Client, ar: &ApiResource, cluster: &str)
    -> Result<Tenancy, ActivationError>;
```

One unfiltered list of records, the same one `live_activation_hashes` makes,
partitioned by `CLUSTER_LABEL`. A record without the label counts as another
cluster's (cluster name `?`), which keeps the rule below conservative.

In `cli/kix/src/cluster/fetch.rs`:

```rust
pub enum SweepScope<'a> {
    /// This cluster's objects (see `attribute`).
    Cluster(&'a Tenancy),
    /// Objects naming one of these record hashes: exactly one closure.
    Records(&'a HashSet<String>),
    /// Every Kix-labelled object. `kix drift` without `--cluster` only.
    All,
}

pub enum Attribution { Ours, Shared(Vec<String>), Foreign(Vec<String>), Unattributed }
pub fn attribute(obj: &DynamicObject, tenancy: &Tenancy) -> Attribution;

pub async fn sweep_managed(client, discovery, scope: SweepScope<'_>) -> Result<ManagedSweep, FetchError>;
pub async fn fetch_managed_resources(client, discovery, scope: SweepScope<'_>) -> ...;
```

`ManagedSweep` gains `foreign: BTreeMap<String, usize>` (objects skipped per
other cluster, for the message) and `unattributed: Vec<DynamicObject>`.
Removing the unscoped signatures makes every caller state its scope; the
compiler finds them all. `attribute` reads `kix.run/activations` through
`keys::get_meta`, so objects still carrying `kix.dev/activations` resolve,
and `kix migrate domain` copies record annotations with their values
(`legacy_domain/migrate.rs:450-458`), so the hashes still match.

### 4.2 The attribution rule

- Names one of `own` → `Ours` (or `Shared` if it also names another cluster's).
- Names only other clusters' hashes → `Foreign`, excluded.
- Names no live record (dead hashes only, no annotation, pre-annotation Kix,
  unstamped label carriers) → `Unattributed`. It counts as `Ours` when
  `others` is empty, which keeps today's behaviour exactly for every
  Kubernetes cluster that runs one Kix cluster. Once a second Kix cluster has
  records here, it is excluded from read views and reported by
  `gc --hard` only.

### 4.3 Callers

| Caller | Scope | Visible change |
|---|---|---|
| `diff.rs:170` | `Cluster` | Adds `tenancy` lookup after the existing gate. Fetch line gains "skipped 41 objects of Kix cluster tutorial-app". |
| `gc.rs` `run_hard_async` | `Cluster` | Foreign objects never enter `live`. Unattributed ones print in their own section, kept unless `--include-unattributed`. Fix the module header. |
| `deploy.rs` `reconstruct_old_from_live` | `Records({active hash} ∪ failed-baseline hashes)` | Takes the hashes it already has (`deploy.rs:602`). Rebuilds the same closure the store graph would have given; leftovers from older closures are not in the old store graph either. |
| `controller.rs:389` | `Cluster` from the reconciled record's label | Stops pruning other clusters' objects. |
| `status.rs:291`, `:503` | `Cluster(args.cluster)` | The flat path stops ignoring its argument. |
| `health.rs:153` | `Cluster` | The resource count becomes correct. |
| `snapshot.rs:54` | `Cluster` | `kix snapshot save <cluster> <dir>`: a new required argument. Records are enough, no flake needed. |
| `drift.rs:73` | `Cluster` with `--cluster`, else `All` | `kix drift [--cluster NAME]` keeps its kubeconfig-only contract. Without the flag each report names its owning clusters (JSON field `clusters`). |

### 4.4 Shared objects on prune (phase 2)

Scoping stops Kix cluster `a` from seeing `b`'s objects. It does not stop `a`
from deleting an object both closures contain after `a` drops it from its
own build; the store-graph prune path deletes it today. With `Tenancy` in
hand the planner can GET each orphan candidate and, when its
`kix.run/activations` names a live record of another cluster, plan it as
kept: `prune: kept ClusterRole/metrics-reader, still deployed by Kix cluster
b`. This belongs in the planner (P18), shared by deploy, soft gc and the
operator. Namespaces and CRDs are already never pruned, so the exposure is
other cluster-scoped kinds of the same name.

### 4.5 Messages

Name the other cluster and what Kix did: "Skipped 41 objects that belong to
Kix cluster tutorial-app." For unattributed objects: "12 Kix objects name no
Activation record on this cluster, and another Kix cluster deploys here, so
Kix cannot tell whose they are. Kept. Review them and pass
`--include-unattributed` to delete them."

## 5. Tests

Unit (`fetch.rs`, `activation.rs`, `gc.rs`, `deploy.rs`):
- `attribute` table: own hash; own and foreign; foreign only; dead hashes
  only with and without other records present; no annotation; the retired
  `kix.dev/activations` key.
- `tenancy` partitions by label; an unlabelled record lands in `others`.
- `gc --hard` planning over a fixed sweep: foreign objects absent from the
  plan, unattributed reported and kept without the flag.
- `reconstruct_old_from_live` under `Records` keeps only objects naming the
  given hashes.

Kind (`cli/kix-cli/tests/kind_integration_test.rs`, extend `deploy_and_gc`):
deploy two Kix clusters with echo servers in different namespaces into one
kind cluster, then assert:
1. `kix diff a` reports no removals.
2. `kix status a` and `kix snapshot save a` contain none of `b`'s objects.
3. After `clear_activation_cache("a")` (forces the fallback path),
   `kix deploy a --prune --yes` leaves every `b` object in place.
4. `kix gc a --hard --yes` deletes nothing of `b`'s.
5. Phase 2: both define an identical ClusterRole; drop it from `a`, deploy
   `a --prune`; `b`'s ClusterRole remains.

## 6. Docs harness

Once `diff` and `gc --hard` are scoped, the reset on
`how-to/policy-receipt-attestation` (`captures.nix:703-708`) is no longer
needed for correctness and can go; recapture and check that the
`application-status` and gc pages do not now show tutorial objects in any
whole-cluster listing. The resets on `how-to/package-envoy-gateway` and
`how-to/adoption-kubectl-takeover` isolate a Helm install and a kubectl
takeover; keep them. Update the caution in
`garbage-collect-stale-resources.mdx:47-53` to describe the unattributed
bucket instead.

## 7. Open questions (Adam)

1. **Exclusive or shared?** B keeps objects shareable between Kix clusters,
   which answers ROADMAP line 71 in favour of sharing without committing to
   the rest of multi-activation. Accept that, or declare Kix clusters on one
   Kubernetes cluster mutually exclusive (then A becomes viable and the
   planner should reject overlapping builds instead)?
2. **Unattributed objects in a shared cluster:** reported by `gc --hard` and
   deleted only with `--include-unattributed` (proposed), or never deletable
   by a single cluster's gc at all?
3. **`kix snapshot save` gains a required cluster argument.** Acceptable
   break, or keep an all-clusters default?
4. **Phase 2 (§4.4) in the same change or later?** It needs a GET per orphan
   candidate on the store-graph path, which today does not touch live objects
   before planning.
5. **Defer D** (a selectable per-cluster label) until listing every
   Kix-labelled object is measurably slow?
