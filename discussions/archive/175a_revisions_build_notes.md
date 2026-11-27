# 175a: Building the revisions (part 2 of 175)

**Status:** Implemented (2026-11-27)
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
- **Revisions are created before the record names them.** A run creates
  its revisions, then writes the phase and the map in one write. A map then
  never names a revision that was not created. Revisions that no record
  names are removed by the next cleanup. This reverses the order in doc
  175, section 4.5, step 3.
- **The CLI and the operator name the same revisions for one build.** Both
  name every object of the build. The operator does not apply CRDs, and
  those objects have no applied hash after it deploys.
- **A `Superseded` record has no map,** so a map exists only on a record
  that should have revisions.
- **Cleanup refuses when it cannot be sure.** It refuses when the list of
  records does not hold the current record or the lock's record, and when a
  record's map is in a format this Kix cannot read.
- **A kind the account may not list** has its objects read one at a time,
  and the plan refuses when it may not get them either (changed after the
  planner review, section 5).
- **The readers of the notes and of the package index stay for one
  release,** behind one constructor, for clusters and records an earlier
  Kix wrote.

Settled while building stages 7 and 8, as reworked after the migration
review:

- **The manager name is `kix/<cluster>`.** A cluster name holds no `/`, so
  it never equals `kix` or another fixed name. The `kix` entry counts as
  this cluster's own only on an object its own records name, that no
  record of an older Kix's cluster lists in the note, and on which every
  other Kix cluster naming it has its own entry (`takes_legacy`). On any
  other object Kix applies unforced.
- **The CLI does not force a field another Kix cluster holds**
  (`HeldByOtherCluster`, its own plan reason). A different rendering is
  refused with K5636, in the dry run too.
- **A Kix cluster that stops deploying a shared object gives up its fields**
  with one empty apply under its own manager, at the start of the prune,
  only while it has its own entry. A failed release stays on the kept list.
- **Convert first.** Every run that holds the lock gives the records an
  older Kix wrote (the current one, and `Failed` or `Partial` ones) their
  revisions before it writes any object, then tidies objects with one JSON
  patch each. The conversion writes no object and names a map only after its
  revisions exist, so a run that stops leaves readable records.
- **Objects shared with an older Kix's cluster** keep both notes and the
  `kix` entries until that cluster moves.
- **An older Kix that deploys after this one** leaves a record without a
  map, which the next run converts.
- **No refusal of `--only` or of the operator's repair:** both convert.
- **The operator refusal is per Kix cluster:** every command that changes a
  Kix cluster refuses (K9557) while a current, queued, or deploying record of
  it was submitted to an operator that does not list `revisions`. An
  operator that publishes nothing is refused too. `kix deploy
  --operator-removed` takes a cluster back from an uninstalled operator
  before it plans: queued records become `Superseded`, a deploying one
  `Failed`, and those and the current record lose `spec.source`.
- **`kix gc --full-scan` rebuilds a missing kept-orphans list** from live
  objects this cluster applied that no other revision names.

Open: the cluster-level and kept-orphans revisions have no bound of their
own (about 2,000 namespaces fill the first). They need a way to split. It
is in `ROADMAP.md`.

## 4. Build order

Each stage builds and passes the tests on its own. New state is written
beside the old before any reader moves.

1. The `PackageInstanceRevision` kind, its store, and building revisions
   from a build. Built.
2. Records name revisions. Steps 3 and 9 of a deploy. The kept-orphans
   revision. Built.
3. The program installs and updates Kix's four CRDs (decision 14). Each
   definition has a number that rises when its content changes, and a
   higher number replaces a lower one. Number 1 of Activation and
   PackageInstance is what builds applied before, and stays the only number
   while a Kix that applies them from a build is still supported. A build
   from before this change loses its two CRDs when it is loaded.
4. Applied hashes in revision status. Built.
5. One reader for "which Kix cluster deploys this object", from revisions,
   with the old reader kept for clusters that are not migrated. Built.
6. The one planner: the three rules of doc 175, section 4.3. Built.
7. One field manager per Kix cluster, and the prune guard that reads it.
   Built.
8. Migration: the one write per object, the end of the second write, the
   rule for a Kubernetes cluster with Kix clusters on two versions. Built.
9. Docs, change records, and the copy pass. Docs and change records
   written; copy pass not run yet.

## 5. Red-team reviews

**Stages 1 and 2 (2026-11-26).** The review found three ways cleanup could
delete a revision that was still needed, and six ways the stored state
could mislead a later reader. The four entries above that begin "Revisions
are created", "The CLI and the operator", "A `Superseded` record", and
"Cleanup refuses" come from it. It also found that `kix gc` deleted kept
orphans and left the list that named them, and that a kept-orphans list
that could not be written was dropped with a warning. Both now fail or
rewrite the list under the lock.

**The planner, stages 4 to 6 (2026-11-26).** The review found four serious
defects: a forced revert took back fields the package ceded, an object of a
kind the account may not list was skipped and forgotten, one drifted object
stopped the operator, and the planner fell back to comparing builds without
saying so. Ceded fields are now out of the applied hash and the drift check;
a forced apply carries the plan's `resourceVersion`; a listing answers
present, absent, or not known, with a GET per object for a kind the account
may not list; the choice of planner fails closed; and the operator reports
drift another manager owns without writing it. The smaller findings on
applied hashes (carry-forward, disagreeing revisions, unreadable maps) were
fixed too.

**The migration (2026-11-26).** The review found that the first deploy
removed notes before every record that relied on them had a map, that a
release could empty an object another cluster deploys, that a failed release
was never tried again, and that the refusals of `--only`, of the repair, and
of an old operator trapped users. The rework converts the records first,
decides per object whose `kix` entry is whose, releases in the prune step,
removes the two refusals, and refuses an old operator per Kix cluster.

**The rework, second pass (2026-11-27).** The earlier findings are closed,
apart from the way out of the operator refusal. New: the conversion trusts a
listing that may miss a kind the account cannot list (a refusal is being
built), a shared object stays untidied while the other cluster has any old
record, an operator never gets its own entry on such an object, a release is
skipped under `--skip-orphan-check`, and applied hashes reach the new
revisions by a best-effort write. Fixes are in progress.

**Second pass fixed (2026-11-27).** The conversion refuses with K9558 when a
record without object names needs a kind the account may not list. Only
records an older Kix still acts on keep a shared object's notes. The operator
applies unforced where it has no entry of its own. `--skip-orphan-check` keeps
shared orphans on the kept list. A run that cannot write its applied hashes
stops before it finalizes. The carry pairs against the map from before the
run, and disagreeing old revisions carry no hash. Kept orphans are found by
their note, the operator refusal reads the current record from the head, and
a record with no index that is too large gets its own advice. Left as
housekeeping: an operator downgraded below the features annotation, the plan
and run converting from two listings, and a redeploy that never finalizes a
complete `Failed` record of the same build.

**The late changes, third pass (2026-11-27).** This review read the forced
revert rule, `--operator-removed`, the saved-plan value check, and the
fixes for the second pass.

- A1: the list of fields a forced apply takes was a guess on the client,
  blind to fields the build spells differently from the server (a port
  without `protocol`, a Secret's `stringData`), so a value changed after the
  plan could be overwritten. Fixed: the plan and the run ask the API server
  with an unforced dry-run apply, and force only when both answers match.
  Without an answer the object is applied without force. The operator's
  version of the same blind spot is left as housekeeping.
- A2: a ceded field taken after the plan was forced back. Fixed: a forced
  apply strips ceded fields another manager holds on each read. This now
  covers `--force-conflicts` too, a change with no error, recorded in
  `changes/deploy-reverts-drift.md`.
- B1: `--operator-removed` cannot see a running older operator. Kix prints
  a check to make. Refusing on a label waits for an operator package, so it
  is housekeeping.
- B2: the saved-plan check compared shown values and ignored managers.
  Managers are now compared. Secrets and long values stay a documented gap
  and a housekeeping entry.
- C1, C2, C3, C4, C7 fixed: `kix plan --out` refuses `--operator-removed`,
  the flag says when it found nothing and the `--only` advice was corrected,
  the take-back continues a dead run of the same build, a recreate applies
  without force, and a failed read is its own error. C5 (a value no manager
  owns) and C6 (a killed redeploy of the current record) are housekeeping.
- The fixes for N1 to N11 held. N3 and N5 have known costs. N9's second half
  (`revisions` left on the CRD after an uninstall or downgrade) stays in
  housekeeping.
