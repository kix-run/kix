# 182: Objects carry no graph state

**Status:** Draft (2026-11-27). Proposed design. Section 9 lists what a review should attack.
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

1. Kix stops writing `kix.run/identity-hash` and `kix.run/depends-on` to
   the cluster. Each Kix cluster's revisions hold both facts.
2. A revision records a hash of each object's content, and the object's
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

### 4.1 What Kix sends

The build is unchanged. A built manifest still carries `kix.run/depends-on`,
and the CLI still stamps `kix.run/identity-hash` on it when it loads the
build. The scheduler, the graph commands, bundles, and stored builds read
them as today.

One function turns a built manifest into the manifest Kix sends. It removes
the two graph annotations. Every request that sends a manifest uses it: the
apply, the dry run, the forced-write check, and the migration write. Every
comparison of a build with the cluster uses it too.

Kix's own Activation record keeps its annotations. It belongs to one Kix
cluster, its name is its build's hash, and no revision lists it.

The annotations that say which instance an object belongs to
(`kix.run/package`, `kix.run/package-namespace`, `kix.run/lifecycle`) stay
on the object. They do not change when a dependency changes. Two Kix
clusters that put one object in two different instances get a conflict,
and that conflict is real.

### 4.2 Revisions, format 2

```yaml
spec:
  format: 2
  slot: { kind: instance, namespace: monitoring, instance: grafana }
  objects:
    - hash: 9f2c...          # content hash
      group: apps
      kind: Deployment
      namespace: monitoring
      name: grafana
      needs:
        - ConfigMap/monitoring/grafana-datasources
        - controller:Deployment.apps/stackgres-system/stackgres-operator
  import:                    # only for an import instance
    apiVersion: v1
    kind: Service
    namespace: kube-system
    name: kube-dns
status:
  applied:
    9f2c...: 51ab...
```

- **`hash` is the content hash:** a hash of the manifest Kix sends, before
  encrypted values are filled in. It changes when the object's own manifest
  changes and at no other time. Kix compares it for equality and reads
  nothing else from it.
- **`needs` lists the object's dependencies by name,** with the prefix
  `depends-on` gives them today (`requires:`, `controller:`, `extra:`, or
  none). Names do not change when a dependency's content changes.
- **`import` describes what an import instance stands for.** Section 4.5.
- A revision's name is still the Kix cluster and a hash of `spec`. With
  content hashes and named edges, a deploy that leaves an instance alone
  now leaves its revision alone too.

Size: the homelab cluster has 334 objects and 980 edges, 2.9 for each
object. An edge is about 60 bytes, so edges add about 180 bytes to an
object's 130. A revision still holds about 4,500 objects before it reaches
Kubernetes' limit. The existing refusal for a revision that is too large
covers the rest.

### 4.3 One rule for the plan

Doc 175's three rules compared the live identity hash first. With no hash on
the object, the applied hash does that work. For each object the new build
makes:

> **Skip the object when a revision this Kix cluster needs holds an applied
> hash for the new content hash, and the live object still matches that
> applied hash. In every other case, apply it and record the applied
> hash.**

"Matches" is today's comparison: the applied hash against the hash of the
fields of the live object that this Kix cluster owns
(`cli/kix/src/cluster/drift.rs`).

The rule gives the same action as the three rules in every case I can find:

| Case | Today | With one rule |
|---|---|---|
| Object missing | rule 1, apply | apply |
| Content changed in the build | rule 1, apply | no entry for the new hash, apply |
| Only a dependency changed | rule 1, a write that changes two annotations | entry exists and matches: **skip** |
| A run died after the apply and before the status write | rule 2, apply again | no entry, apply again (it changes nothing) |
| Edited by hand | rule 3, reverting drift | entry exists, live differs, apply as reverting drift |
| A failed deploy wrote a newer build over it | rule 1, labelled "applied by record X" | entry exists, live differs, apply |

The labels come from the same facts:

- **Reverting drift:** live differs from the applied hash, and no other
  revision this Kix cluster needs holds an applied hash that the live
  object matches.
- **Applied by deploy record X:** live matches an applied hash in a revision
  of the `Failed` or `Partial` record X.
- **Left by a deploy with failures:** the current record is `Degraded` and
  its revision holds no applied hash for the object.

One label gets weaker. A deploy that was killed records no applied hashes
(`scheduler/mod.rs` writes them once, after the last object). If it wrote a
newer build over an object, the next plan sees fields that this Kix
cluster's own manager changed and no record of it. Today the live identity
hash names the record. The new plan says the object was changed by a deploy
of this Kix cluster that did not finish. The action is the same. Section 8
has an option that closes the gap.

**Objects the new build does not make.** A live object becomes an orphan
when a revision of the current record or the kept-orphans revision names
it, as today. For a `Failed` or `Partial` record, today's test is "the live
identity hash is the one that record gives the object, and this Kix
cluster's manager wrote it". The new test is "that record's revision names
it, and this Kix cluster's manager wrote it". The hash half is no longer
needed: only a record of this Kix cluster can have written under
`kix/<cluster>`, and every record that could have is the current one (which
takes the object in already), the kept-orphans revision (the same), or a
stopped one.

### 4.4 Which objects are Kix's

Every sweep today keeps an object when it carries `kix.run/identity-hash`
(`inventory::is_stamped`). The new test is a field manager entry of a Kix
cluster, which `fieldsv1::written_by_kix` reads already. A revision of this
Kix cluster that names the object says the same and attributes it. Both are
written in the apply itself, or before it.

### 4.5 An import is not an object

An import instance says that something exists which Kix does not make: the
platform's DNS Service, a storage class, a CRD another tool installs. Today
Kix applies a `PackageInstance` marker for it and then waits for the thing
itself. The wait reads the build's marker. Nothing reads the live marker
except `kix status`, which shows it as "external".

The marker stays in the build, where it is a node of the graph. Kix no
longer applies it. The instance's revision records the import in
`spec.import`, so `kix status` and other readers can show it with no build
at hand.

This removes the only objects that every Kix cluster on a Kubernetes cluster
wrote by construction. `kubectl get packageinstances` then lists the
instances Kix deployed, and no entries that stand for something else.

### 4.6 Delete order and status

Prune order, `kix gc` order, the controller that removes a finalizer, and
the "needed by" lines of `kix status` read `depends-on` from live objects
whenever the build is not on the machine. They read `needs` from the
revisions. One reader builds the edges from a set of revisions. The
operator, which never has the build, uses the same reader.

### 4.7 What stays the same

- The build, bundles, stored builds, and `kix export`, which already leaves
  out every `kix.run/*` annotation.
- `kix diff` between two builds. A build still knows its dependency hashes,
  so "only its dependencies changed" stays true there.
- The plan document keeps its field for such changes. `kix plan` against a
  cluster leaves it empty.
- The lock, the head, the Activation record, and the applied hash.

## 5. Migration

The first deploy by the new Kix already converts an older Kix's records and
rewrites every object's metadata once (doc 175, section 7). This design adds
to that one step. It does not add a second.

- **Objects.** The first deploy moves each object to `kix/<cluster>` and
  then sends the manifest without the two annotations. Kubernetes removes a
  field that its owner stops sending. An object with unchanged content gets
  the same treatment in the migration write.
- **Revisions for the new record** come from the build, in format 2.
- **Applied hashes across the upgrade.** For an object whose live identity
  hash equals the one the new build gives it, the conversion copies the old
  applied hash under the new content hash. A hand edit made before the
  upgrade is then still reported as drift. For any other object the first
  deploy applies without force, and Kubernetes refuses a field that someone
  else took.
- **Failed and Partial records and kept orphans of an older Kix.** Their
  builds may not be on the machine, so their content hashes are unknown.
  The conversion writes the old identity hash as `hash`. It is still a value
  that says what that build wanted, and it never equals a content hash, so
  the rule never skips such an object. `needs` comes from the live
  `depends-on`, which the conversion reads before any write, as it reads the
  other notes today.
- **Format 1 revisions.** Only clusters deployed from `main` between #374
  and this change have them: one shared test cluster and developers' test clusters. No release
  writes format 1. The first deploy treats them as it treats an older Kix's
  records.
- **Markers already on the cluster** have left the build. They are kept and
  listed like any other object that left, and `kix deploy --prune` or
  `kix gc` deletes them. A marker another Kix cluster still writes stays,
  and this Kix cluster gives up its share.
- **Another Kix cluster on an older Kix.** It keeps writing its two
  annotations and its markers under the manager `kix`. The new Kix does not
  send those fields, so the two never conflict on them. This is the case
  the trial failed on.
- **An older Kix that looks at the new Kix cluster's objects** sees Kix's
  label and no identity hash. Its sweep sets such objects aside as
  "unstamped", and `kix gc` deletes them only with
  `--include unstamped`. Section 9 asks for a test.

## 6. What users see

- `silent`: `kix.run/identity-hash` and `kix.run/depends-on` are gone from
  objects. This joins the record `revisions-annotations-retired`, which
  already tells a reader of `kix.run/activations` and
  `kix.run/applied-hash` to read revisions.
- `silent`: import instances have no `PackageInstance` object.
- `changed`: a deploy no longer writes to an object whose dependencies
  changed, and `kix plan` no longer lists "tracking annotation only".
- `added`: revision format 2 (`needs`, `import`).
- `fixed`: the first Kix cluster to upgrade is no longer refused. This has
  no record of its own, because no release had the refusal.

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

## 9. What a review should attack

1. The claim of section 4.3 that one rule gives the same action as three.
   Look for a state where the live object matches an applied hash recorded
   for the new content hash, and the object is still wrong.
2. The orphan test for a stopped record without the hash half.
3. Two Kix clusters and one shared object, through every step: first apply
   by the second, a prune by one, a hand edit, and the applied hash each
   keeps. The applied hash covers the fields a Kix cluster owns. Check that
   a field both own does not make each report the other as drift.
4. Content hash and encrypted values: a Secret from a SOPS file whose
   decrypted value changes while the file's manifest does not.
5. The migration, from 0.9, from 0.10.0-rc.6, and from format 1, with a
   second Kix cluster left on the older Kix.
6. An older Kix running `kix gc --full-scan --include unstamped` beside an
   upgraded Kix cluster.
7. Anything outside the CLI that reads the two annotations from a live
   object: the operator, `scripts/`, the docs' recorded outputs.

## 10. Build order

Each step ends with the full tests green.

1. The function of section 4.1, used by every sender, with the annotations
   still written. No behavior changes.
2. Revision format 2 with `needs` and `import`, written beside the
   annotations. Readers of edges move to revisions.
3. The sweep reads field managers (section 4.4).
4. The one rule (section 4.3), then stop sending the two annotations.
5. Imports (section 4.5).
6. Migration and conversion (section 5).
7. Docs, change records, the cluster-state fixtures, `cli/README.md`, the
   skills.

Tests on a real cluster before the pull request: two Kix clusters that
differ by one Namespace label; the upgrade from 0.9.2 and from rc.6 with the
other Kix cluster left behind; a shared test cluster.
