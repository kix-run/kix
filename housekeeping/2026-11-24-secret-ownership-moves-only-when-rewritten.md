# 2026-11-24 · `cli/kix/src/cluster/apply/` · A Secret an older Kix applied keeps its `stringData` ownership until the build changes it.

Kix now applies Secret values as `data` (`string_data_as_data` in `apply/ssa.rs`), so it owns `data.<key>`. A Secret that an older Kix applied still has Kix owning only `f:stringData.<key>`. The deploy skips it while its identity hash is unchanged, so nothing moves the ownership. The first write after the upgrade that also removes a key leaves that key on the cluster, and no manager owns it. Seen on kind: Kix from main deployed, this branch removed `host`, the plan showed no removal, and `host` stayed. One `kix deploy --reconcile` after the upgrade fixes it, which the change record `fix-secret-apply-owns-data-upgrade` asks users to run. Keys left unowned before the upgrade stay in every case.

Options:

1. Keep the note record. Costs nothing, and a user who skips the step keeps the old behaviour on each Secret until its first rewrite.
2. Have the plan read each skipped Secret's live `managedFields` and apply it again when Kix's `Apply` entry owns `f:stringData` (the operator already holds live objects in `detect_changes_live`; the CLI would need a GET per Secret, like `DeployPlan::read_last_runs` does for Jobs). Automatic, but it adds a cluster read to every deploy until the rule is removed.
3. In `apply_resource`, when the live Kix entry owns `f:stringData` keys missing from the new `data`, apply once with them at their live values and then without them. Fixes the removal in one deploy, at the cost of a second apply and a special case.

Decision required from the maintainer: whether option 1 is enough.
