# 175a: Building the revisions (part 2 of 175)

**Status:** Accepted, in progress (2026-11-26)
**Related:** `175_one_home_for_what_a_deploy_did.md`

Type: implementation plan. Doc 175 holds the design. This document holds
what was tested and decided before part 2 was built, and the order of the
build. Where the two differ, this one is newer.

## 1. Tests the design asked for

Run on kind (Kubernetes 1.35) on 2026-11-26.

**Moving objects from the manager name `kix` to one name per Kix cluster.**
An object today has two ownership entries under `kix`: one from the apply,
and one from the second write that owns the two notes.

- An apply of the same manifest under the new name adds a second entry and
  leaves the old one. Both then own every field. A later apply that drops a
  field leaves the field on the object, because `kix` still owns it.
- An apply that changes a value under the new name is refused with a
  conflict that names `kix`, unless it is forced.
- One JSON patch can rename the apply entry's manager, remove the second
  entry, and remove the two notes, with a `test` on `resourceVersion`. After
  it the object has one entry under the new name, and a later apply that
  drops a field removes the field.

So the migration is one write per object, and it runs before the first apply
under the new name.

**A larger cluster.** 5,000 ConfigMaps of 4 KB each (20.7 MB) list in 0.2 s
against a local API server. Listing is not the limit.

**The size of one revision.** With 8,000 objects, `spec` is 1.19 MB and
`status.applied` is 0.61 MB. Together they pass the 1.5 MiB limit. One
instance holds about 6,500 objects, not the 8,000 that section 4.8 of doc
175 gives.

## 2. Answers to the open questions of doc 175, section 8

1. **Old manager entries:** the single patch above.
2. **Scale:** measured above.
3. **Who installs the revision CRD:** the program, as for the head. Taking
   the lock makes sure both CRDs exist. The revision CRD has a status
   subresource and a rule that refuses a change to `spec`.
4. **Cleanup of retired annotation keys:** it moves into the migration
   write, which already goes to every object once. The planner holds each
   live object, so it plans the write only for an object that still carries
   a note or a retired key.
5. **An older Kix and a `Partial` record:** still open, see the housekeeping
   entry doc 175 names.

## 3. Decisions (Adam, 2026-11-26)

13. **Two Kix clusters that render a shared object differently are
    refused.** With one manager name per Kix cluster, Kubernetes refuses the
    second apply. The message names the other Kix cluster and the field.
    Today the last deploy wins with no message.
14. **The program installs Kix's own CRDs.** Activation and PackageInstance
    stop coming from the build, as the head's CRD already does. Two Kix
    clusters on different versions of Kix then do not collide on them.
15. **The CLI forces a revert of drift, and the operator does not.** A hand
    edit makes the editor the owner of the field, so an apply that is not
    forced is refused. After the plan is confirmed, `kix deploy` forces the
    apply of the objects the plan labels "reverting drift", and of no
    others. The plan names who changed which field. The operator's repair
    does not force. It reports the conflict in status and leaves the object.
16. **`--offline` is a preview.** It plans from the builds. When the deploy
    connects it plans again from the live objects, and refuses when the
    result differs from the plan that was confirmed.

Settled without a question, from the code:

- **Two sets of orphans.** A finishing deploy takes in what `Failed` and
  `Partial` records left. `kix gc` deletes only what the kept-orphans
  revision names. Otherwise `kix gc` after `kix deploy --only` would delete
  what that deploy added.
- **One build hash named by two kept revisions.** A run that applies an
  object writes its applied hash to every kept revision of its Kix cluster
  that names the object with that build hash.
- **`status.applied` does not match `spec` one to one.** A `Partial`
  record's revision for an instance it did not apply has no hashes.
- **The first deploy of a cluster** creates the revisions before the record,
  because the record waits for its CRD. The lock keeps cleanup out.
  Decision 14 removes this case.
- **The operator builds revisions from the objects it applies,** which
  leaves out CRDs and the record.
- **A kind the account may not list** stays skipped with a warning.
- **The readers of the notes and of the package index stay for one
  release,** behind one constructor, for clusters and records an earlier
  Kix wrote.

Open: the cluster-level and kept-orphans revisions have no bound of their
own (about 2,000 namespaces fill the first). They need a way to split.

## 4. Build order

Each stage builds and passes the tests on its own. New state is written
beside the old before any reader moves.

1. The `PackageInstanceRevision` kind, its store, and building revisions
   from a build.
2. Records name revisions. Steps 3 and 9 of a deploy. The kept-orphans
   revision.
3. Applied hashes in revision status.
4. One reader for "which Kix cluster deploys this object", from revisions,
   with the old reader kept for clusters that are not migrated.
5. The one planner: the three rules of doc 175, section 4.3.
6. The program installs Kix's CRDs. One field manager per Kix cluster, and
   the prune guard that reads it.
7. Migration: the one write per object, the end of the second write, the
   rule for a Kubernetes cluster with Kix clusters on two versions.
8. Docs, change records, and the copy pass.
