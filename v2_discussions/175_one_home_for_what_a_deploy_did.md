# 175: One home for what a deploy did

**Status:** Accepted, third version. Rewritten on 2026-11-24 after a red-team review (section 9). Brought up to date on 2026-11-26 for `kix deploy --only`, with the build order (section 10). Part 1 is being built.
**Related:** `122_runtime_content_drift.md` (the applied hash), `81_deploy_as_lifecycle_engine.md`, `55_shared_resource_ownership.md`, `archive/150_scope_managed_sweep_to_one_cluster.md` (several Kix clusters on one Kubernetes cluster), `archive/157_kix_plan_primary_preview.md` (the plan), `interesting_thoughts/54_activation_signing.md`, `housekeeping/reviews/2026-11-23.md` (themes 4 and 5)

Type: design doc. It reads code at `origin/main` on 2026-11-26, with the
branch that adds `kix deploy --only` and the `Partial` phase. Section 10 says
what is built.

## 1. Summary

Kix keeps what a deploy did in three places: notes written onto every object,
the Activation record, and the build on the deploying machine. Each command
reads its own mix, and the notes cause real faults. This document gives each
fact one home.

| Fact | Kind | New? | Changes when |
|---|---|---|---|
| What one build makes for one package instance | `PackageInstanceRevision`, in `spec` | New | Never |
| What Kubernetes stored when Kix last applied each of those objects (the applied hash) | `PackageInstanceRevision`, in `status` | New | One of its objects is applied |
| What a deploy was | `Activation`, which now names revisions | Changed | Its phase changes |
| Who is deploying, which Activation is current, and which Kix wrote last | `ActivationHead`, one per Kix cluster | New | Every deploy |
| What the build wants an object to be | The object itself, written in the one apply | As today | The build changes it |

Kix then writes each object once, and only when the object changes. The
PackageInstance kind is not changed.

## 2. Context

### 2.1 What Kix stores today

- **On every object, in the apply:** `kix.run/identity-hash` (the build hash),
  `kix.run/package`, `kix.run/depends-on`, and the other notes the compiler
  and the loader produce.
- **On every object, in a second write after the apply**
  (`cli/kix/src/cluster/apply/ssa.rs`, `update_bookkeeping_annotations_checked`):
  `kix.run/activations`, the records that use the object, and
  `kix.run/applied-hash`, a hash of the fields Kix owns as the server stored
  them.
- **On every unchanged object, when a deploy of a new build finishes**
  (`cli/kix/src/cluster/scheduler/mod.rs`, `stamp_unchanged`): Kix reads the
  object and adds the new record's hash to `kix.run/activations`. A deploy of
  the same build, a deploy that stops early, and the operator's repair do not.
- **On the Activation record:** `status.packageIndex`, the build hash of every
  object grouped by package instance, with names since 0.10
  (`cli/kix-core/src/eval/package_index.rs`). A record the operator deployed
  from an Activation applied by hand or from git has no index.

### 2.2 What goes wrong

- **The second write collides with operators.** An operator that read the
  object between the two writes loses its status update
  (`housekeeping/2026-10-01-bookkeeping-patch-races-operator-status-writes.md`).
- **A deploy writes to every object.** One operator copies a resource's
  annotations into its pods, so a deploy restarts all ClickHouse Keeper pods
  (`housekeeping/2026-11-18-kix-annotations-on-chk-restart-keeper.md`). With
  100 ms a round trip and 8 at a time, 1,600 unchanged objects cost at least
  20 seconds.
- **The list does not fit a production cluster.** The index is capped at
  150 KiB. With names it holds about 1,200 objects. Past that Kix drops the
  names, and past about 3,600 objects it stores no list.
- **Nothing orders two deploys**
  (`housekeeping/2026-09-28-kept-orphans-list-last-finalize-wins.md`,
  `housekeeping/2026-11-11-stale-deploying-record-never-cleared.md`). The
  deploy reference says a second deploy is refused, and the code does not
  refuse it.
- **The cluster does not know which Kix wrote it last**
  (`housekeeping/2026-11-20-record-names-the-builder-not-the-writer.md`).
- **A deploy of part of a build makes two deploys at once likely.** With
  `kix deploy --only`, two people may each deploy one instance of the same
  build. Both runs write the same record, and the last to finish sets its
  phase and `status.partial`
  (`housekeeping/2026-11-26-two-deploys-of-one-cluster-are-not-blocked.md`).
- **Commands disagree.** `kix deploy` compares two builds. The operator and
  gc read the notes on live objects. `kix plan --read-only` compares a
  filtered view of live objects.

### 2.3 Decisions already taken (Adam, 2026-11-24)

1. A plain `kix deploy` brings the whole cluster back to the build. The plan
   labels a change that undoes an edit made outside Kix as "reverting drift".
   An intended change has no label.
2. Kix keeps two hashes. The build hash says what the build wants. The applied
   hash says what the cluster stored.
3. The lock is one object per Kix cluster, owned by Kix.
4. Kix keeps no state outside Kubernetes.
5. The new kinds are `PackageInstanceRevision` and `ActivationHead`. Neither
   uses "cluster", which already means two things in Kix.

6. Shared objects: test one field manager per Kix cluster first
   (section 4.7, option b).
7. The operator's repair takes the lock.
8. Kix keeps only the revisions it needs to run. It keeps no history of
   revisions. A team that wants one stores it in another system.
9. An older Kix is stopped from running `kix gc` after a newer one has
   deployed.
10. The first deploy by the new Kix removes the two old notes from every
    object (section 7). Pods of operators that copy annotations restart once.
11. One release carries the whole design (Adam, 2026-11-26). An earlier
    version split it in two so that every project passed through a Kix whose
    `kix gc` refuses. Kix has two users of earlier releases, so they are told
    instead (section 7).
12. A deploy of part of a build ends with its record in its own phase,
    `Partial` (Adam, 2026-11-26). This design treats a `Partial` record as it
    treats a `Failed` one, except where it says otherwise.

Decision 1 reverses a rule the CLI states today: live state is read "never to
decide" (`cli/README.md`, "Baseline: what a plan compares against"). That
section is rewritten when this is built.

## 3. What the design must hold

1. One write per changed object in a deploy, and no write to an unchanged one.
2. No fixed limit that a production cluster reaches. A cluster of 20,000
   objects and 1,000 instances must work.
3. Every command and the operator decide from the same stored facts.
4. A deploy that dies at any point leaves state the next deploy can read and
   repair with no step by hand.
5. Two deploys of one Kix cluster cannot both finish.
6. Kix reads state written by releases of the last six months.
7. Several Kix clusters on one Kubernetes cluster keep working, including
   objects they share, and including the time when they run different
   versions of Kix.

## 4. Design

### 4.1 PackageInstanceRevision

`spec` lists what one build makes for one package instance: the build hash,
group, kind, namespace, and name of each object. Objects that belong to no
instance, such as Namespaces, go in one revision for the cluster level.

- **`spec` is immutable and names the object.** The name is the Kix cluster's
  name and a hash of `spec`. The CRD refuses a change to `spec`, and a reader
  checks the hash against the name. Two machines that hold the same build
  compute the same name.
- **Carried forward.** The Activation record holds one revision name per
  instance. A deploy that leaves an instance unchanged names the same
  revision as the deploy before it, and writes nothing for that instance.
- **Kept only while Kix needs them** (section 4.2). A record that is no
  longer needed keeps its phase and receipt and loses its revisions.
- **Cluster-wide objects,** like Activation, labelled `kix.run/cluster`. One
  list request with that label returns every revision of a Kix cluster.
- **`status.applied`** maps each object's build hash to its applied hash. The
  keys match `spec` one to one. Section 4.3 has the rules.

Kubernetes has this pattern already: a `ControllerRevision` is an immutable,
hash-named piece of a StatefulSet's history.

The PackageInstance object cannot serve as the revision. It holds the current
instance only. Its build hash follows the instance's main resource, hooks,
and listed requirements (`kix/lib/core/activation.nix`) and leaves out the
other objects the instance makes.

### 4.2 The Activation record

The record keeps its phase, receipt, and request fields. `status.packageIndex`
is replaced by a map from `namespace/instance` to a revision name, plus the
cluster-level revision.

- **Only a lock holder writes the map and the revisions.** `kix deploy
  --operator` queues a record and holds no lock, so the operator writes both
  from the build it already holds. That also gives an index to an Activation
  applied by hand or from git, which has none today.
- **An object belongs to a record** when one of the record's revisions names
  it.
- **Which records keep revisions.** The current record, the record a lock
  holder is deploying, a queued record, and each `Failed` or `Partial` record
  until a later deploy finishes and takes in what it left. A `Superseded` record
  keeps none. A rollback to it writes its revisions again from its build.
- **Kept orphans.** A deploy that finishes without pruning leaves objects
  that the new build no longer makes. The new record lists them in one more
  revision, the kept orphans: the ones the deploy left, plus the ones the
  record before it already listed that are still live. This replaces
  `status.orphansKeptFrom`, which names whole builds.
- **An orphan** is a live object that a `Failed` record, a `Partial` record,
  or the kept-orphans revision names and that the current record's instances
  do not.
- **Which Kix cluster an object belongs to** is read from the same records:
  current, in flight, queued, `Failed`, `Partial`, and the kept orphans.
- **A `Partial` record** names a revision for every instance of its build,
  like any record. `status.partial.only` stays the list of instances the
  deploys with `--only` applied in full. The applied hashes cannot replace
  it: an instance the build did not change has them too. A second deploy
  with `--only` of the same build adds to the list while it holds the lock,
  so the two runs no longer race.
- **A reader that finds a named revision missing** refuses to compute orphans
  and refuses to prune. It says which revision is missing. A lock holder with
  the build creates it again, with the same name.

### 4.3 Applied hashes and what a plan decides

Kix writes `status.applied` on a revision after it applies objects of that
instance, and again on the way out of a deploy that stops early. An unchanged
object in a changed instance has its hash copied from the old revision to the
new one in the same write.

Keeping the hash on the revision has four effects:

- Cluster-level objects need no second home.
- The revision exists before any apply, so no object is applied before the
  place for its hash exists.
- Two Kix clusters never write the same status, because revisions are per
  Kix cluster.
- A cluster can let a team edit Deployments and deny it
  `packageinstancerevisions/status`. Today anyone who can edit an object can
  edit the hash on it and hide the edit.

A plan decides with three rules, in this order:

1. **The live build hash differs from the new build's hash, or the object is
   missing: apply.** The records supply only the label: no label for an
   intended change, "applied by deploy record X" when a `Failed` or
   `Partial` record's revision names the live hash (the plan prints this
   label today, from the record's build), and "left by a deploy with
   failures" when a
   `Degraded` record names an object it did not reach.
2. **The applied hash is missing: apply and record it,** with its own label.
   It is never read as "in sync". This covers a run that died between an
   apply and the status write, a restore from a backup that drops `status`,
   and a note edited by hand.
3. **The applied hash differs from the hash of the live object's Kix-owned
   fields: reverting drift** (`cli/kix/src/cluster/drift.rs` computes this
   today against the annotation).

An object that moves between instances with the same build hash stays an
apply, because its owner notes change.

### 4.4 ActivationHead and the lock

One object per Kix cluster, cluster-wide, named after the Kix cluster.

| Field | Meaning |
|---|---|
| `status.current` | Name of the record the cluster runs. |
| `status.generation` | A counter that rises each time a run that wrote to the cluster releases the lock: a finish, a deploy with `--only` that ends `Partial`, a failed run, a prune, or a gc. A plan binds to this value. |
| `status.lock.holder` | An id for the run, with a hint a person can read. The operator's id survives a restart of its pod. |
| `status.lock.activation` | The record the holder is deploying. |
| `status.lock.renewed`, `durationSeconds` | Lease values. The duration is 30 seconds. The holder renews every 10 seconds. |
| `status.lock.purpose` | `deploy`, `rollback`, `gc`, `migrate`, or `repair`. |
| `status.lock.waiting` | The id of a run that waits for a repair to give up the lock. |
| `status.writer` | The Kix version and program (CLI or operator) that last finished a write to the cluster. |

Rules:

- **Every write uses the object's `resourceVersion` as a precondition.**
  Kubernetes then refuses the second of two writers.
- **Every command that changes objects takes the lock first:** deploy
  (with or without `--only`), rollback, gc, prune, and migrate. `kix deploy
  --operator` is the one exception: it only queues a request, and the
  operator takes the lock.
- **The operator's repair gives way.** A repair holds the lock with the
  purpose `repair`. A run that finds such a holder writes its own id to
  `status.lock.waiting`. The repair reads the head before each object it
  applies, and releases the lock when `waiting` is set. A repair does not
  change `status.writer` or `status.generation`.
- **A second run watches before it decides.** One read cannot tell a live
  lock from a dead one without agreed clocks. The run watches for up to one
  lease. If the holder renews, the run refuses and names the holder, its
  purpose, and the record it is deploying. If nothing renews, it takes over.
  Kubernetes' own leader election measures expiry this way. A live holder
  renews within 10 seconds, so a refusal takes at most that long, and a
  takeover takes 30.
- **Taking over a dead lock.** If the dead run was deploying the record that
  is already current, the takeover only clears the lock. If the new holder is
  about to deploy the same record, it continues it. Otherwise it marks the
  dead run's record `Failed`.
- **The holder stops itself.** It notes when it last renewed and sends no
  apply, status write, or delete once 20 seconds have passed since then,
  which is 10 seconds before another run may take over. The clock must count
  time while the machine sleeps, since a closed laptop is the likely pause.
  No one clock does that on every system, so the holder measures with the
  monotonic clock and with the wall clock and uses the longer of the two. The holder renews immediately before it prunes and checks
  the deadline before each delete.
- **A plan is bound to `status.generation`.** A plan is shown and confirmed
  before the lock is taken. The run refuses if the generation has moved. A
  saved plan stores the generation beside what it binds to today.
- **A read never waits.** `kix status` and `kix plan` print the holder, its
  purpose, the record, and how long ago it renewed. When that is longer than
  the lease by this machine's clock, they say the run has probably died and
  that the next deploy will take over. They do not decide it.
- **The head's CRD is part of the Kix program, not of the build.** The CLI
  and the operator create it when it is absent, before they take the lock.
  A rollback to a build from before this design, and an Activation applied
  by hand, then need nothing from the build. The operator's role gains
  `create` on CustomResourceDefinitions for this.
- **An Activation with no `kix.run/cluster` label** uses the head named
  after the Kix cluster it is read as today, which is its own name.
- **The checks for required stops and for an older Kix read `status.writer`**
  (`cli/kix/src/cluster/stops.rs`). `kix gc` gains the check, which it lacks
  today.
- **When the head and the phases disagree,** the head is right when it was
  written after the records. Two cases show that it was not. In the first,
  the record `status.current` names is `Superseded` or gone while another
  record is current by phase. In the second, built with the revisions, the
  record that is current by phase has no revision map. In both an older Kix
  deployed after the head was written. Kix then treats the Kix cluster as
  not migrated and rebuilds the head (section 7). A head with no `status`,
  as after a restore from a backup, is rebuilt the same way. When no record
  has a phase either, the Kix cluster has no current record, as today.

The phases on records stay as history and for older readers.

### 4.5 One deploy, step by step

| Step | Writes | If the run dies here |
|---|---|---|
| 1. Create the head's CRD if it is absent | One CRD | Nothing to repair |
| 2. Take the lock, check `status.writer` and `status.generation`, then update Kix's CRDs | Head, CRDs | The lock expires |
| 3. Create the record, phase `Deploying`. Then send a create for every revision it names and accept "already exists". | Record, revisions | The next run takes over as section 4.4 says, and sends the creates again |
| 4. Apply each changed object, in dependency order | One write per object | Objects it reached carry its build hash. Rule 1 or 2 of section 4.3 applies them again. |
| 5. Write `status.applied` on each revision whose objects were applied | One write per changed instance | Some applied hashes are missing. Rule 2 applies and records them. |
| 6. Prune, if asked: renew the lock, then delete | One delete per orphan | The remaining orphans are still orphans |
| 7. Write the receipt and the deploy time to the record | Record | The head still names the old record, which is true |
| 8. Finish: `current`, `generation`, `writer`, release the lock | Head | Nothing to repair |
| 9. Set the phases, and delete the revisions no longer needed | Records, revisions | The next run repairs the phases from the head and deletes them |

Step 8 is the one point where the deploy becomes current.

A deploy with `--only` takes steps 1 to 5 for the objects it selected. It
never prunes. In place of steps 7 to 9 it sets the record's phase to
`Partial` with `status.partial`, then raises `generation`, sets `writer`,
and releases the lock in one write to the head. `current` does not change.
If the run dies before that write, the next run takes over and marks the
record `Failed`, as for any deploy.

### 4.6 How each command reads

Every command starts the same way: read the head, list the Kix cluster's
records, and list its revisions. That is three requests.

- **`kix plan` and `kix deploy`** then list the live objects of the kinds the
  revisions name, and apply the three rules of section 4.3. This is one
  planner, which the operator can share.
- **`kix status` and `kix diff`** need no build: revisions name every object,
  and the applied hashes say which have drifted.
- **`kix gc` and prune** use the orphan rule of section 4.2.
- **`kix rollback`** applies an older record's build through the same steps,
  and step 3 writes that record's revisions from the build.
- **Rebuilding the old side on a machine without the builds**
  (`cli/kix/src/plan/baseline.rs`) reads revisions where it reads the note
  today.
- **Which Kix cluster an object belongs to** (`inventory.rs`, `attribute`) is
  read from the revisions of every Kix cluster on the Kubernetes cluster.
  `kix status`, `kix diff`, `kix snapshot`, gc, and the operator need that
  list. It is small, because no Kix cluster keeps history.

The second write also removes annotation keys of the retired API group
(`cli/kix-core/src/legacy_domain/mod.rs`). That cleanup needs a new home.

### 4.7 Several Kix clusters on one Kubernetes cluster

Two Kix clusters may deploy the same object (doc 150). A prune by one must
not delete what the other deploys. Each Kix cluster has its own lock, so the
lock does not order them.

Today's guard is safe because of the second write. A deploy creates its
record and then writes the record's hash onto each object, which changes the
object's `resourceVersion`. A prune reads the object, reads the records, and
deletes with the `resourceVersion` it read. So the prune either sees the new
record or has its delete refused (`cli/kix/src/cluster/tenancy.rs`).

This design removes that write, and an apply that changes nothing does not
change `resourceVersion`. The guard therefore needs a new way to see that
another Kix cluster has begun to deploy an object. Two options:

- **(a) A claim, written once.** When a deploy takes in an object that is
  already live and that its previous record did not contain, it writes a note
  on the object naming its Kix cluster. That is one write per adopted object,
  once.
- **(b) One field manager per Kix cluster.** Each Kix cluster applies under
  its own manager name. Kubernetes then records on the object which Kix
  clusters apply it, in the one apply, and the first apply by a second Kix
  cluster changes `resourceVersion`. Two Kix clusters that render the object
  differently would get a conflict, which is an open question in
  `ROADMAP.md`. It changes the manager name on every object Kix has applied,
  and the drift code is keyed on that name.

The guard reads every record of the other Kix cluster that is not
`Superseded`, plus the record its lock names. Reading only `current` would
let one Kix cluster delete what another is deploying at that moment.

Adam chose to test (b) first, and the test on kind supports it (2026-11-24).
An apply of the same manifest under the same manager left `resourceVersion`
unchanged. The first apply of the same manifest under a second manager
succeeded, added that manager to the object's ownership records, and changed
`resourceVersion` once. Later applies by either manager changed nothing. An
apply by the second manager with one value changed was refused with a
conflict that names the first manager and the field. Not yet tested: what
happens to objects applied under today's single name when Kix moves to a
name per Kix cluster.

### 4.8 Sizes, counts, and requests

Measured on `homelab-kind`, built from main with no deploy:

| Measure | Value |
|---|---|
| Objects | 333, of 32 kinds |
| Instances | 50: 31 with objects, 18 references and imports with a PackageInstance only, and the cluster level |
| Objects in an instance | Median 5, largest 35 |
| Cluster-level objects | 34 for 8 namespaces, about 4 a namespace |
| A revision's `spec` | 118 bytes an object. Median 575 bytes, largest 7 KB. |
| A record's map of revisions | 71 bytes an instance |
| Applied hashes, 32 characters each | 70 bytes an object |
| The build as JSON | 1.1 MB, and 113 KB after gzip |

Limits, at about 1.5 MiB an object: about 20,000 instances in one record, and
about 8,000 objects in one instance. The cluster's total size has no limit of
its own. The build can refuse an instance that would pass the limit.

How far one change spreads, counted by rebuilding the cluster with the change:

| Change | Instances changed, of 50 | Objects changed |
|---|---|---|
| The size of one app's volume | 2 | 7 |
| The size of the shared database's volume | 8 | 34 |
| How the platform's DNS Service is described (pull request 303) | 12 | 49 |
| Two library changes that alter no manifest (pull requests 302 and 305) | 0 | 0 |

How many objects exist, for a Kix cluster of 150 instances:

| Kind | How many | Removed by |
|---|---|---|
| `ActivationHead` | 1 | Removing the Kix cluster |
| `Activation` | Up to about 52, as today | Retention, as today |
| `PackageInstanceRevision` | 152 when the cluster is at rest: one an instance, the cluster level, and the kept orphans. One more for each instance that a deploy in flight, a queued deploy, or a `Failed` record changes. | Step 9 of the deploy that makes it unneeded |

The count follows the number of instances and does not grow with the number
of deploys. A project that changes every instance on every deploy holds 152
revisions at rest and about 300 while a deploy runs.

Measured on the same cluster deployed to kind (Kubernetes 1.37, 334 live
objects), through a proxy that adds 100 ms to each round trip:

| Measure | Value |
|---|---|
| Live objects, as the API returns them | 1.82 MB, 5.4 KB each: 1.6 times the build |
| Ownership records (`managedFields`) in that | 22 percent |
| Kix's own annotations in that | 510 bytes an object |
| `kix status` | 6.4 s, 140 requests. It lists 100 resource types for a build of 32 kinds. |
| One list for each of the build's 32 kinds, 8 at a time | 0.94 s, 1.93 MB |
| The same with gzip | 0.95 s, 0.88 MB. The API server compresses only answers over about 128 KiB, which was 4 of the 32. |
| A deploy of the same build | 9.9 s, 78 requests. No object is read for drift. |
| A deploy that changes 6 objects | 44.3 s, 1,207 requests |
| In that deploy, the notes on 332 unchanged objects | 336 reads and 336 writes, 56 percent of the requests, 3.6 s (they run 64 at a time) |
| In that deploy, API discovery | 244 requests, at least 10 s |

What the measurements say:

- **The drift listing is cheap.** Listing the kinds a build has costs under a
  second at this latency. That is the read decision 1 adds to every deploy.
- **The notes cost requests more than time,** because they run 64 at a time.
  Scaled to 1,700 objects they are about 18 s. Each note is a real write, so
  every controller that watches those objects gets an update on each deploy.
- **Discovery costs more than either,** and this design does not touch it.
  Kix asks for one group version at a time, in series, and repeats the round
  two or three times in one command: 6.7 of the 9.9 seconds of a deploy with
  nothing to do. It is logged as a housekeeping entry.
- **Compression saves about half,** not nine tenths, on lists of this size.
- **List only the kinds the revisions name.** `kix status` lists three times
  as many types as the build has.
- **Keep the head small.** It is rewritten at each renewal, so it holds no
  list. One Activation is already 97 KB live, and a deploy lists the
  Activations 5 to 7 times.

For a deploy that changes a few objects, the design removes two requests for
each unchanged object and adds about 10 writes to Kix's own objects, 3 reads,
and one list per kind.

### 4.9 Cleanup

- **Revisions.** At step 9 and in `kix gc`, Kix deletes each revision that no
  record of section 4.2's list names. Both hold the lock. After a deploy
  finishes, that removes the old revision of every instance it changed.
- **No age rule is needed.** Lock holders write a record before the revisions
  it names, and the cleanup lists revisions first and records second.
- **Applied hashes** go with their revision.
- **A Kix cluster that is abandoned** leaves its head, records, and revisions
  behind, as its records stay today. A teardown deletes the head last.
- **Retention's stated reason goes.** The limits of 10 to 50 records exist
  today because of the size of the note on each object
  (`cli/kix/src/cluster/activation/retention.rs`). Records no longer cost
  anything per object, so the limits can be set by how far back a team wants
  to roll back.

## 5. Angles checked

- **Scale.** Section 4.8. No object grows with the whole cluster.
- **Failure.** Section 4.5. Every step leaves state the next run reads and
  repairs, and section 4.3 says what a missing hash means.
- **Two deploys at once.** The lock, the holder's own deadline, and step 8.
- **Several Kix clusters.** Section 4.7, with one choice open.
- **Tampering.** A revision's name is the hash of its `spec`, so a changed
  list is detectable, and a signed record (doc 54) would cover its revisions.
  An applied hash can be forged by someone who may write revision status. A
  full check against the build, by server-side dry run of every object, stays
  available for an audit.
- **A person with kubectl.** `kubectl get activationhead` shows who is
  deploying and what is current. To see which record uses an object, a person
  asks Kix, where today they read a note.
- **Backups.** Common backup tools do not restore `status` unless told to.
  After such a restore the head has no `current` and no applied hash exists.
  Rule 2 of section 4.3 then applies every object once. How the head is
  rebuilt needs an answer (section 8).
- **The original idea.** A deploy is two hash comparisons per object: build
  hash against the new build, and applied hash against the live object. Kix
  writes what differs.
- **Operators that copy annotations into pods.** The per-deploy notes are
  gone. The build hash stays on the object and changes when a dependency of
  the object changes, so such an operator still restarts its pods then.

## 6. Alternatives considered

- **Keep one list on the record and raise the cap.** It stops hard at about
  8,000 objects, and 50 records would hold 50 copies.
- **Compress the list,** as Helm does for a release. It moves the limit and
  keeps it. The copies stay, and kubectl cannot read it.
- **Split the list into fixed-size chunks,** as EndpointSlice does. Chunks are
  not shared between records, so every deploy rewrites all of them.
- **Keep the revisions of every kept record,** shared by hash. This was the
  first version. The count grew with deploys, up to kept records times
  instances, and Kix reads none of that history.
- **Kubernetes owner references to remove revisions.** Each deploy would have
  to add itself as an owner of every revision it names.
- **Applied hashes in PackageInstance status and on the head.** This was the
  first version. It needed a second home for cluster-level objects, wrote to
  a PackageInstance that may not exist yet, and let two Kix clusters that
  share a PackageInstance erase each other's entries.
- **Keep the applied hash on the object, sent in the one apply.** Kix would
  run a server-side dry run first and send the hash with the real apply. It
  fails when a webhook refuses dry runs, and when a webhook answers
  differently the second time. Each needs a fallback to a second write.
- **Drop the applied hash and ask Kubernetes about every object on every
  deploy.** It costs one request per object, each of which runs the cluster's
  admission webhooks, and `kix status` could not report drift without the
  build. It also gives up decision 2.
- **Use only Kubernetes' field ownership records.** It needs the build to
  know what Kix should own, and the code already handles a write that
  Kubernetes records with no owner (`drift.rs`, `unrecorded_scale`).
- **A standard Kubernetes Lease for the lock.** It needs a namespace on every
  cluster, and the writer and the current record would still need a home.
- **A database outside Kubernetes.** A deploy from the CLI must work with no
  operator, and the state would need its own backup and access control.

## 7. Migration

- **The first deploy by the new Kix** creates the head. It writes a revision
  map and revisions for the new record, and a kept-orphans revision from the
  builds that `status.orphansKeptFrom` names. Older records need none. It copies
  each object's applied hash from the note into revision status. It then
  removes the two notes from every object (but see the next point).
- **A Kubernetes cluster that holds Kix clusters on different versions.** A
  project may keep clusters on several versions of Kix. An older Kix that
  prunes for Kix cluster B reads the note to learn that Kix cluster A still
  deploys a shared object. If A has removed the note, B deletes the object.
  So while another Kix cluster on the Kubernetes cluster has no head, the new
  Kix keeps the note on every object whose note names a record of that
  cluster, with its own current record's hash in it. The rule ends when that
  cluster gets a head.
- **An older Kix that deploys after the new one** (with `KIX_ALLOW_DOWNGRADE`,
  or past a record with no receipt version) writes phases and notes and
  leaves the head alone. Section 4.4 says how the new Kix detects this and
  migrates again. The cluster-state fixtures gain this case.
- **An older Kix that runs `kix gc` after the new one** is not refused today.
  With one Kix cluster on the Kubernetes cluster, the older gc counts objects
  that name no record as its own, and would delete live objects once the
  notes are gone. Two releases, the first a required stop whose gc refuses,
  would close this for every project that upgrades in order. It would not
  stop a Kix from an old checkout. With two users of earlier releases, one
  release ships, and its change record says not to run an older `kix gc`
  on a cluster this Kix has deployed.
- **The operator.** An older operator beside a new CLI applies its whole
  build on every requeue and writes the notes back. The operator is upgraded
  before the first deploy by the new CLI, and the new CLI refuses when the
  operator does not announce the new feature
  (`kix.run/operator-features`). The operator's role gains the two new kinds.
- **What users see.** The first deploy writes every object once, and pods of
  operators that copy annotations restart once: a `note` record. The two
  annotations going away is a breaking change with no error for any program
  that reads them. The records set `state = true`.

## 8. Open questions

Nothing is waiting for Adam.

Settled on 2026-11-26, in section 4.4: the lease duration and the holder's
margin (was question 3), a restore that drops `status` (4), what a read
shows while a lock may be dead (5), an Activation with no cluster label (6),
who installs the head's CRD (7, for the head; the revision CRD is open until
part 2), and what a saved plan binds to (9).

Settled on 2026-11-24: the old notes are removed on the first deploy
(decision 10), the
field manager test comes first (decision 6), the
repair takes the lock (decision 7), no revision history (decision 8), and an
older `kix gc` is stopped (decision 9). The repair yields to a waiting deploy
and does not count as a writer.

To settle by reading or testing before any code:

1. Test what happens to objects applied under today's manager name when a
   Kix cluster starts to apply under its own name, and how the old entry is
   removed. The rest of the field manager test passed (section 4.7).
2. Measure on a cluster larger than 334 objects. The sizes and timings in
   section 4.8 come from one small cluster on kind.
3. Say who installs the revision CRD on a cluster that only the operator
   deploys. The operator leaves CRDs out of its reconcile.
4. Find the new home for the cleanup of retired annotation keys
   (section 4.6).
5. Say what an older Kix does with a `Partial` record, which it does not
   know (`housekeeping/2026-11-26-older-kix-ignores-a-partial-record.md`).
   The head's `status.writer` lets a later Kix see it. An older one cannot.

Not in this document: the planner itself (review theme 4), replacing an
object that cannot change in place (theme 6), and readiness (theme 7). Each
builds on the state described here.

## 9. Red-team review, 2026-11-24

A separate agent read the first version against the code. Its verdict was
"sound with changes". The full report is not in the repository. What it
changed here:

- **Applied hashes moved** from PackageInstance status and the head to the
  revision's status (section 4.3).
- **The plan's rules were incomplete.** A `Degraded` record's objects and a
  missing applied hash had no rule. Section 4.3 now has three.
- **The takeover rule was wrong** for a deploy of the build that is already
  current, and for the operator after a restart (section 4.4).
- **"The head is right" was wrong** after an older Kix deploys (section 4.4).
- **A record could name a missing revision** through `kix deploy --operator`,
  and gc would then read live objects as orphans (section 4.2).
- **The orphan rule was wrong:** superseded records still name kept orphans
  (section 4.2).
- **The prune guard between Kix clusters depended on the write this design
  removes** (section 4.7), and a mixed-version Kubernetes cluster could lose
  a shared object (section 7).
- **Smaller corrections:** the refusal needs a watch, the holder needs its
  own deadline, the finish needs one commit point, the plan needs a value to
  bind to, and `kix health` no longer exists.

Two claims of the first version were only half right. A deploy writes to
every unchanged object only when a new build finishes. The record's list
repeats the note only when the list exists, which it does not past 150 KiB
or for a record the operator made from a hand-applied Activation.

## 10. Build order

The work is two pull requests in one release. The lock needs none of the
tests that the revisions wait for, so it is built first.

**Part 1: the head and the lock.**

- The `ActivationHead` kind, created by the CLI and the operator.
- The lock, for deploy, rollback, gc, prune, migrate, the operator's
  deploys, and its repair. The holder's deadline. The takeover rules.
- `status.current`, `status.generation`, and `status.writer`. Plans and
  saved plans bind to the generation. The checks for a required stop and
  for an older Kix read the writer, and `kix gc` gains them.
- The first run by this Kix creates the head from the phases. Phases are
  still written, and the head is rebuilt when an older Kix wrote after it.
- `kix status` and `kix plan` show the holder.
- The operator announces the feature, and the CLI refuses an operator
  that does not.

Part 1 changes nothing about the notes on objects, the package index, the
baseline of a plan, or the prune guard between Kix clusters. Requirements 1
and 2 of section 3 are not met until part 2.

**Part 2: revisions.** Not started. Before any code: questions 1 to 4 of
section 8.

- The `PackageInstanceRevision` kind, the revision map on records, and the
  kept-orphans revision.
- Applied hashes in revision status, and the three rules of section 4.3 as
  the one planner.
- One field manager per Kix cluster, and the prune guard that reads it.
- The first deploy removes the two notes from every object.

