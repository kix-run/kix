# 182: Objects carry no graph state

**Status:** Built (2026-11-28, branch `graph-off-objects`). Section 9 says what the adversarial review changed, and section 11 where the build differs from the design.
**Related:** `archive/175_one_home_for_what_a_deploy_did.md` (this finishes it), `archive/175a_revisions_build_notes.md`, `archive/150_scope_managed_sweep_to_one_cluster.md`, `55_shared_resource_ownership.md`, `ROADMAP.md` ("Two Kix clusters that render one shared object differently").

## 1. Summary

A Kix cluster is one cluster definition. Several can share one Kubernetes
cluster. Doc 175 promised that they keep working, "including objects they
share, and including the time when they run different versions of Kix". The
upgrade trial of 2026-11-27 showed that they do not.

The cause is that Kix still writes two facts about its own dependency graph
onto every object: `kix.run/identity-hash` and `kix.run/depends-on`. Each
Kix cluster has its own graph, and the object has one annotation. Two Kix
clusters that share an object therefore conflict, also when they want the
same object.

This design removes graph state from objects:

1. Kix stops writing `kix.run/identity-hash`, `kix.run/depends-on`, and
   the three annotations that name an object's instance. Each Kix
   cluster's revisions hold those facts.
2. A revision records a hash of each object's manifest, and the object's
   dependency edges by name.
3. The planner's three rules become one.
4. An import is a statement about the cluster, so Kix records it in the
   revision and writes no object for it.

After this, an object on the cluster holds what the definition says and
nothing about any deploy. Two Kix clusters conflict only on a field that
both set to different values.

The design also ends a class of writes. Today a change to one object changes
the identity hash of everything downstream of it, and Kix rewrites each of
those objects to update the two annotations. On the trial cluster that was
106 of 112 writes.

## 2. What the trial found

### 2.1 The failure

Two Kix clusters, `lab` and `lab2`, on one kind cluster, both using
`kix.flavors.kind`. Kix 0.9.2 deployed both. The new Kix then deployed `lab`
and stopped before applying anything:

```
✗ PackageInstance.kix.run/platform-dns@kube-system field ownership conflict
    kix owns .metadata.annotations.kix.run/depends-on, .metadata.annotations.kix.run/identity-hash, ...
✗ PackageInstance.kix.run/platform-storage@kube-system field ownership conflict
```

A flavor gives every Kix cluster the instances `platform-dns` and
`platform-storage` in `kube-system`. Each instance has a marker object named
after the instance, so every Kix cluster on that Kubernetes cluster writes
the same two objects.

### 2.2 It is not about versions

I first read this as a version problem. It is wider. Four definitions on the
same library, built side by side:

| Kix clusters | Difference between the definitions | Shared objects |
|---|---|---|
| `a`, `b` | only the name | identical |
| `a`, `d` | `d` sets one label on `kube-system` | `depends-on` differs on both markers |

`d` adds a label that `a` does not set. Kubernetes field ownership allows
that: `d` owns the label, and both own the rest. But the marker's
`depends-on` holds the identity hash of the Namespace, and that hash covers
the whole Namespace manifest. So `a` and `d` conflict on the markers, and
on `kix.run/identity-hash` of the Namespace itself.

### 2.3 The cause

`kix.run/identity-hash` is a Nix store hash of the object's manifest and of
everything the manifest depends on. `kix.run/depends-on` lists the identity
hashes of its dependencies. Both are facts about one Kix cluster's graph.

Doc 175 moved two such facts off objects (`kix.run/activations`,
`kix.run/applied-hash`) for this reason: "Two Kix clusters never write the
same status, because revisions are per Kix cluster." It left these two, and
it gave each Kix cluster its own field manager. Since then Kubernetes
refuses what used to be a silent overwrite.

Three more things follow from the same cause:

- **Objects are rewritten when nothing in them changed.** A change to one
  object changes the identity hash of every dependent. The plan calls these
  "tracking annotation only". Each one is a real write. It raises a
  Deployment's `generation`, and a controller that copies annotations onto
  Pods restarts them.
- **A revision is replaced when nothing in its instance changed,** because
  the revision lists identity hashes.
- **An import marker is an object with no content of its own.** It exists
  to carry graph state. One test cluster holds 92 PackageInstance objects, and 44 of
  them are markers.

## 3. The principle

**An object on the cluster holds what the definition says about it.
What a Kix cluster knows about its own graph and its own deploys lives in
that Kix cluster's revisions.**

Doc 175's decision 2 already says it: "Kix keeps two hashes. The build hash
says what the build wants. The applied hash says what the cluster stored."
The identity hash was used as the build hash, but it says more than what the
build wants for one object. It also says what the build wants for every
dependency.

## 4. Design

Words used below. The **graph notes** are the annotations that describe one
Kix cluster's graph: `kix.run/identity-hash`, `kix.run/depends-on`, and the
three that name an object's instance, `kix.run/package`,
`kix.run/package-namespace`, and `kix.run/lifecycle`. The **object hash** is
a hash of the manifest Kix sends for one object. The **applied hash** is
doc 175's: a hash of what the cluster stored.

### 4.1 What Kix sends

The build is unchanged. A built manifest still carries `kix.run/depends-on`,
and the CLI still stamps the other four graph notes on it when it loads the
build. The scheduler, the graph commands, bundles, and stored builds read
them as today.

One function turns a built manifest into the manifest Kix sends. It removes
the five graph notes, so Kix sends what the library rendered and nothing the
graph added. Every request that sends a manifest uses it: the apply, the
dry run, the forced-write check, and the migration write. Every comparison
of a build with the cluster uses it too, including the offline plan.

The three instance notes go with the two hashes because they are the same
kind of fact. Two Kix clusters that make one CRD from instances with
different names would conflict on `kix.run/package-namespace`, and
`kix.run/lifecycle` comes from a package's `meta`, so it can differ between
two library versions. A revision's `slot` already names the instance.

Kix's own Activation record keeps its annotations. It belongs to one Kix
cluster, its name is its build's hash, and no revision lists it.

### 4.2 Revisions, format 2

```yaml
spec:
  format: 2
  slot: { kind: instance, namespace: db, instance: main, lifecycle: stateful }
  objects:
    - hash: 9f2c...          # object hash
      group: example.com
      kind: Widget
      namespace: db
      name: main
      needs:
        - { kind: ConfigMap, namespace: db, name: main-config }
        - { kind: PackageInstance, group: kix.run, namespace: db, name: crd-ref-main-widgets-example-com }
  imports:
    - name: crd-ref-main-widgets-example-com
      hash: 77ab...
      target: { apiVersion: apiextensions.k8s.io/v1, kind: CustomResourceDefinition, name: widgets.example.com }
      needs:
        - { as: requires, group: apps, kind: Deployment, namespace: ops, name: widget-operator }
status:
  applied:
    9f2c...: 51ab...
```

- **`hash` is the object hash:** a hash of the manifest of section 4.1, with
  sorted keys and nulls removed, before encrypted values are filled in. It
  covers every other `kix.run/*` annotation, so a changed SOPS file changes
  it through `kix.run/sops-digest`. Kix compares it for equality and reads
  nothing else from it. No reader joins it with a build's store hashes:
  every join between a revision and a build goes by name. A test fixture
  pins the function, because the value is stored state.
- **`needs` lists the object's dependencies by name,** each with the role
  `depends-on` gives it today (`requires`, `controller`, `extra`, or none).
  Names do not change when a dependency's content changes.
- **`imports` lists the instance's import markers** (section 4.5): the
  marker's name, what it stands for, and its own `needs`. An edge to a
  marker names it as today, so an edge that passes through a marker, such
  as custom resource to CRD marker to operator, stays whole.
- A reader of `objects` gets only objects Kix makes. A reader of edges gets
  `objects` and `imports`.
- A revision's name is still the Kix cluster and a hash of `spec`. A deploy
  that leaves an instance alone now leaves its revision alone too.
- Code that maps an object to its applied hash keys on the object's name
  and hash, not on the whole entry, so a changed edge does not lose it.
- The new CRD must be on the cluster before the first format 2 write. An
  API server with the old definition drops the new fields without an
  error. Kix installs its own CRDs at the start of a deploy, and this
  design depends on that order.

Size: the homelab cluster has 334 objects and 980 edges, 2.9 for each
object. An edge is about 60 bytes, so edges add about 180 bytes to an
object's 130. A revision still holds about 4,500 objects before it reaches
Kubernetes' limit, down from about 11,000. No single instance comes near
that. Two revisions cannot be split by instance. The cluster-level one
holds Namespaces, which have almost no edges. The kept-orphans one fills
sooner than before. The existing refusal for a revision that is too large
covers both.

### 4.3 One rule for the plan

Doc 175's three rules compared the live identity hash first. With no hash on
the object, the applied hash does that work. For each object the new build
makes:

> **Skip the object when a revision this Kix cluster needs holds an applied
> hash for the new object hash, and the live object still matches that
> applied hash. In every other case, apply it and record the applied
> hash.**

For the rule to hold, the two hashes must cover the same things. Today the
applied hash leaves out every `kix.run/*` annotation, because a stamp
written after the apply must not change its own hash. No stamp is written
after the apply any more. So the applied hash covers every field this Kix
cluster owns, and leaves out only the retired notes: the five graph notes
and doc 175's two. Without this, a change to `kix.run/readiness` alone
would be skipped after a failed deploy. With it,
`apply::owner_stamps_moved` has no work left and goes.

| Case | Today | With one rule |
|---|---|---|
| Object missing | rule 1, apply | apply |
| Content changed in the build | rule 1, apply | no entry for the new hash, apply |
| Only a dependency changed | rule 1, a write that changes two annotations | entry exists and matches: **skip** |
| A run died after the apply and before the status write | rule 2, apply again | no entry, apply again (it changes nothing) |
| Edited by hand | rule 3, reverting drift | entry exists, live differs, reverting drift |
| A failed deploy wrote a newer build over it | rule 1, labelled "applied by record X" | entry exists, live differs, apply |
| Only a dependency changed, and someone edited it | rule 1, no force, Kubernetes refuses | **reverting drift** |
| A killed run wrote over it, and another tool then took a field | rule 1, no force, Kubernetes refuses | **reverting drift** |

The last two rows change. Reverting drift asks Kubernetes which fields a
forced write would take, shows them in the plan, and forces after you
confirm. That is doc 175's decision 1. No case goes from a forced write to
an unforced one.

The labels come from the same facts:

- **Reverting drift:** live differs from the applied hash, and no other
  revision this Kix cluster needs holds an applied hash that the live
  object matches.
- **Applied by deploy record X:** live matches an applied hash in a revision
  of the `Failed` or `Partial` record X.
- **Left by a deploy with failures:** the current record is `Degraded` and
  its revision holds no applied hash for the object.

A deploy that was killed records no applied hashes. If it wrote a newer
build over an object, the next plan cannot name the record. It labels the
object as changed by a deploy of this Kix cluster that did not finish, when
a stopped record's revision names the object and holds no applied hash for
it. Section 8 has an option that narrows this.

**A runner that never forces** (the operator) skips a drifted object today
and reports it, on the grounds that the object carries the build's hash.
That is no longer known. So the operator applies the build without the
fields other managers hold, which changes nothing when its own fields are
already right, and reports the held fields as today. It does not record a
new applied hash for such an object, so the report stays until the drift
is gone.

**Readers with no new build.** `kix status` and `kix diff --live` compare
the live object with the applied hash that the current record's revision
holds for it, found by name. A live object that matches a stopped record's
entry is shown as written by that deploy.

**Objects the new build does not make.** A live object becomes an orphan
when a revision of the current record or the kept-orphans revision names
it, as today. For a `Failed` or `Partial` record, today's test is "the live
identity hash is the one that record gives the object, and this Kix
cluster's manager wrote it". The new test is "that record's revision names
it, and the object has an apply entry under `kix/<cluster>` itself". The
old shared manager `kix` does not count here, or a Kix cluster could delete
an object that only another one wrote before the upgrade.

### 4.4 Which objects are Kix's

Every sweep today keeps an object when it carries `kix.run/identity-hash`
(`inventory::is_stamped`). The new test is one thing: a field manager entry
of a Kix cluster, which `fieldsv1::written_by_kix` reads already. A
revision that names the object attributes it to a Kix cluster and does not
make it Kix's by itself, so an object whose ownership records a restore
dropped stays a copy until Kix applies it again, as today.

Today's "unstamped" class is "written by Kix and not stamped". It becomes
empty. Such an object is now an object Kix wrote that no revision names,
which `kix gc --include unattributed` covers. `--include unstamped` is
removed, and Kix refuses it with an error that names the other flag.

### 4.5 An import is not an object

An import says that something exists which Kix does not make: the
platform's DNS Service, a CRD another tool installs, a Secret or Service a
package refers to. The library makes a marker for each (`kix.mkImport`,
`scope.mkCRDRef`, `mkSecretRef`, `mkServiceRef`). Today Kix applies the
marker as a `PackageInstance` and then waits for the thing itself.

The marker stays in the build, where it is a node of the graph, and Kix no
longer applies it:

- A marker is not one of the objects a build makes. So a marker already on
  the cluster has left the build, like any object a build stops making.
- The planner gives a marker no write. The scheduler treats it as it treats
  an unchanged marker today: it checks that the target exists when
  something this deploy writes depends on it.
- The revision lists it under `imports`, so status, delete order, and the
  controller lookup read it from there.

This removes the only objects that every Kix cluster on a Kubernetes cluster
wrote by construction. `kubectl get packageinstances` then lists the
instances Kix deployed.

### 4.6 Delete order and status

Prune order, `kix gc` order, the controller that removes a finalizer, and
the "needed by" lines of `kix status` read `depends-on` from live objects
whenever the build is not on the machine. They read `needs` from the
revisions. The operator, which never has the build, does the same. The
edges Kix derives from content, such as a RoleBinding to its Role, still
come from the live objects.

Two orders get weaker. An object that no revision names
(`kix gc --full-scan --include unattributed`) has only the edges derived
from content. So has a kept-orphans revision that `kix gc` had to rebuild
because it could not be read.

### 4.7 What stays the same

- The build, bundles, stored builds, and `kix export`, which already leaves
  out every `kix.run/*` annotation.
- `kix diff` between two builds. A build still knows its dependency hashes,
  so "only its dependencies changed" stays true there.
- The plan document keeps its field for such changes. Every plan of a
  deploy leaves it empty.
- The lock, the head, and the Activation record.

## 5. Migration

The first deploy by the new Kix already converts an older Kix's records and
rewrites every object's metadata once (doc 175, section 7). This design adds
to that one step. It does not add a second.

- **Order.** The conversion reads every note it needs and stores the
  revisions before the first object is written. A migration deploy that
  dies and runs again then finds its revisions and does not need notes the
  first run removed.
- **Objects.** The first deploy moves each object to `kix/<cluster>` and
  then sends the manifest without the graph notes. Kubernetes removes a
  field that its owner stops sending.
- **Applied hashes.** The old applied hash left out `kix.run/*`
  annotations and the new one does not, so no old value can be kept as it
  is. For an object whose live identity hash equals the one the new build
  gives it, and which matches its old applied hash, the conversion stores
  the new applied hash of the live object. For one that does not match, it
  stores the old value, which no live object can match, so the plan reports
  drift as it would have.
- **Failed and Partial records and kept orphans of an older Kix.** Their
  builds may not be on the machine, so their object hashes are unknown. The
  conversion writes the old identity hash as `hash`. It still says what
  that build wanted, and it never equals an object hash, so the rule never
  skips such an object. `needs` comes from the live `depends-on`.
- **Format 1 revisions.** Only clusters deployed from `main` between #374
  and this change have them: one shared test cluster and developers' test clusters. No release
  writes format 1. A revision's `spec` cannot change, so the first deploy
  writes new revisions and a new map for each record it keeps, as it does
  for an older Kix's records.
- **Markers already on the cluster** have left the build. They are kept and
  listed like any other object that left, and `kix deploy --prune` or
  `kix gc` deletes them. A marker another Kix cluster still writes stays,
  and this Kix cluster gives up its share.
- **Another Kix cluster on an older Kix.** It keeps writing its notes and
  its markers under the manager `kix`. The new Kix sends none of those
  fields and no markers, so the two never conflict on them. This is the
  case the trial failed on.
- **An older Kix that looks at the new Kix cluster's objects** sees Kix's
  label and no identity hash. From its code, `kix gc` deletes such an
  object only with both `--include unstamped` and `--include unattributed`.

## 6. What users see

- `silent`: the five graph notes are gone from objects. This joins the
  record `revisions-annotations-retired`, which already tells a reader of
  `kix.run/activations` and `kix.run/applied-hash` to read revisions.
- `silent`: an import has no `PackageInstance` object.
- `silent`: a deploy no longer writes to an object whose dependencies
  changed. An operator that acts only when its custom resource is written
  no longer sees a write when a Secret the resource depends on changes.
  `kix plan` no longer lists "tracking annotation only".
- `silent`: two cases that Kubernetes refused are now reported as reverting
  drift (section 4.3).
- `error`: `kix gc --include unstamped` is removed.
- `added`: revision format 2 (`needs`, `imports`, `slot.lifecycle`).
- The first Kix cluster to upgrade is no longer refused. This has no record
  of its own, because no release had the refusal.

## 7. Alternatives considered

- **A per-Kix-cluster annotation key,** such as
  `kix.run/identity-hash.<cluster>`. Small, and it keeps the hash in the
  apply. It keeps graph state on objects, keeps the rewrites, and adds a
  key for each Kix cluster to every shared object. A Kix cluster name may
  hold characters and lengths an annotation key refuses.
- **An identity hash that covers content only.** Two Kix clusters that set
  different fields of one Namespace still disagree on it, because the hash
  covers the whole manifest and ownership is by field.
- **One marker for each Kix cluster,** with the Kix cluster in the name. It
  fixes the markers and nothing else in section 2.2, and it keeps objects
  that exist only to carry graph state.
- **Keep the design and explain the refusal.** The first upgrade needs
  `--force-conflicts`, and so does every later one where the definitions
  differ.
- **Keep the instance notes on objects.** This was the first version. They
  do not change when a dependency changes, but two Kix clusters that make
  one object from differently named instances conflict on them.
- **Compare every `kix.run/*` annotation in the rule,** and keep the
  applied hash as it is. It is smaller, and it turns one special check
  into a general one where the other choice removes it.
- **Keep `depends-on` on objects, by name.** It stops the rewrites. Two Kix
  clusters that give a shared object different dependencies still conflict
  on it.

## 8. Options left open

1. **Record applied hashes when an instance finishes,** not once at the end
   of the run. It closes the weaker label of section 4.3, and it is what
   doc 175 section 4.3 describes. It costs one status write for each changed
   instance. Housekeeping entry
   `2026-11-27-killed-redeploy-of-current-record-loses-applied-hashes` is
   about the same window.
2. **Delete migrated markers in the first deploy** without `--prune`. They
   hold nothing, so deleting them is safe. It is a second rule for when an
   object is deleted, which is why the design does not do it.

## 9. Review, 2026-11-27

An adversarial review read this design against the code and found no flaw
in the principle. It changed the design in these places:

- **The applied hash must cover what the object hash covers** (section
  4.3). As first written, a change to a `kix.run/*` annotation alone was
  skipped after a failed deploy.
- **Markers are of four kinds and edges pass through them** (sections 4.2
  and 4.5). As first written, a revision recorded one import for each import
  instance, and a prune with no build at hand could delete an operator
  before its custom resource.
- **The instance notes go too** (section 4.1). The first version kept them.
- **The stopped-record orphan test needs this Kix cluster's own manager**
  (section 4.3).
- **The operator's skip** (section 4.3), **readers with no build**, the
  offline plan (section 4.1), the "unstamped" class (section 4.4), and the
  order of the migration (section 5) were not covered.

It could not build a failing case for ceded fields, `stringData`, server
defaults, a co-owned object, a rollback whose revisions are gone, `--only`,
`--reconcile`, rerun Jobs, recreated objects, a kind that is not served
yet, or an edge between Kix clusters.

Tests it asked for, beyond section 10: a flip between two builds across a
failed deploy and across a killed one, for each `kix.run/*` annotation; the
delete order custom resource, CRD marker, operator with no build at hand;
a killed migration deploy run again; Kix 0.9.2 running
`kix gc --full-scan` beside an upgraded Kix cluster; a dependency name that
holds a colon; one build read from a bundle and from the store gives the
same object hashes.

## 10. Build order

Each step ends with the full tests green.

1. The function of section 4.1, used by every sender, with the notes still
   written. No behavior changes.
2. Revision format 2 with `needs` and `imports`, written beside the notes.
   Readers of edges move to revisions.
3. The sweep reads field managers (section 4.4).
4. The applied hash covers `kix.run/*` annotations, the one rule (section
   4.3), then stop sending the graph notes.
5. Imports (section 4.5). This part is the riskiest and can ship after the
   others if a test shows a problem.
6. Migration and conversion (section 5).
7. Docs, change records, the cluster-state fixtures, `cli/README.md`, the
   skills.

Tests on a real cluster before the pull request: two Kix clusters that
differ by one Namespace label; the upgrade from 0.9.2 and from rc.6 with the
other Kix cluster left behind; a shared test cluster.

## 11. As built

Where the code differs from sections 4 to 6, or settles what they left open:

- **Format 2.** The slot names the instance in `name`. A `needs` entry is an
  object (`group`, `kind`, `namespace`, `name`, `as`), because a name can
  hold a colon. An edge to a hash the build does not make is left out. A
  `spec.format` above 2 is refused as written by a newer Kix.
- **Map format 2.** `status.revisions` is written as format 2, and 1 and 2
  are read, so an older Kix refuses the map instead of misreading it.
- **Imports.** An entry records the marker's `namespace` and an optional
  `target`. An edge passes through a marker only when the manifests at hand
  do not hold it. The kept-orphans revision lists the imports its objects
  reach. The derived package index lists markers with a flag.
- **The object hash** is 32 hex digits of a SHA-256 of the sent manifest.
  A rebuilt kept-orphans list uses the hash `rebuilt`.
- **The rule has a third clause.** The applied hash leaves out ceded fields
  and the object hash does not, so the two do not cover the same things
  (section 4.3 says they must). A skip also needs each ceded field that
  `kix/<cluster>` still owns to hold the value the build sends.
- **Taking in leftovers** of a `Degraded`, `Failed`, or `Partial` record
  needs an applied hash in that record's revision or an `Apply` entry under
  `kix/<cluster>`. The shared `kix` manager alone never counts.
- **Labels.** A stopped record shows as `unfinished_deploy` when the object
  has no drift and as `reverts_drift` when it has drift.
- **The operator** applies a drifted object without the fields another
  manager holds and records no applied hash for it.
- **What Kix sends** leaves out all seven retired notes, under every domain.
- **Kept-orphans size** is checked when planning, before the lock. Orphans
  that `--prune` deletes are not counted.
- **Migration.** The conversion takes `needs` and lifecycle from the live
  notes, and carries an applied hash only when the object's
  `kix.run/activations` note lists the record. A marker an older Kix applied
  gets the migration write once and is then a kept orphan.
- **Kix's kinds** are matched by group and kind. Another group's `Activation`
  or `PackageInstance` is an ordinary object.
- **One definition of what a build makes** (`lifecycle::makes`) leaves
  markers out everywhere, gc included.
- **Hand-over of a shared object** goes through records only. Another Kix
  cluster still deploys an object when its records name it. Its `Apply`
  entry counts only beside its own kept-orphans list. A record stops naming
  a shared orphan once the run saw its entry gone, and a release-only plan
  runs. `kix gc --full-scan` takes an object no record names that carries
  the cluster's own entry as the cluster's.
- **`kix status -o json`** renames `resources[].identity_hash` to `hash`.
- **Known limits** are in `ROADMAP.md` and `housekeeping/` (2026-11-28).
