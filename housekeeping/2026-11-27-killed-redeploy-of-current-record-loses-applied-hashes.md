# 2026-11-27 · `cli/kix/src/cluster/ops/record.rs` · A redeploy of the current record that is killed before the carry loses the applied hashes it should carry.

A run that deploys the current record again with a different set of revisions (a converted record whose revisions group objects differently from the build) replaces the record's revision list in `begin_deploy`. It carries the old applied hashes over in `record_applied`. If the process is killed between the two, the retry's `current_map` reads the new list as "before" and carries nothing. A normal stop is fine, because `abort_record` carries. The cost: each of those objects gets `AppliedHashMissing` and is applied once more without force on the next deploy. If one of them also drifted with a conflict, that deploy stops on the conflict until `--force-conflicts`.

Decision required from Adam:
- (a) Keep the earlier list on the record until the carry is done: `begin_deploy` writes it (for example `status.revisionsBefore`) only when it replaces a list, `current_map` prefers it, and the carry write clears it. Recommended. Cost: one added field in cluster state, a state fixture, and changes to `Records::begin_deploy` and the carry write.
- (b) Name the new list on the record only at the carry. Cost: the run's revisions are unnamed while it runs, which breaks the rule that an unnamed revision has `status.applied` cleared at create, and the way cleanup and `kix gc` read names.
- (c) Accept it. Cost: one extra apply per object after such a killed run.
