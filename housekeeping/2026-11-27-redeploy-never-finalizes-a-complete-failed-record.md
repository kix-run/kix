# 2026-11-27 · `cli/kix/src/cluster/scheduler/mod.rs` · A redeploy never finalizes a `Failed` record of the same build when every object already has its applied hash.

Take a record of the build being deployed that is `Failed`, or still `Deploying` after `DeployError::FinalizeFailed`, whose objects all carry their applied hashes. A redeploy of that build plans nothing: `finalize` runs only when something changed, and in the CLI `Work::Nothing` starts no run. The previous record can then stay current while the new build's objects are live. The test harness leaves the record `Deploying`; whether `start` marks the build's own record `Superseded` in the CLI is unchecked.

Decision required from Adam:
- (a) A build whose own record exists and is not current counts as work, and `finalize` runs when the record was not current. Recommended by the second review: one small rule.
- (b) Make `FinalizeFailed` and similar paths leave applied hashes unwritten, as a failed applied-hash write now does, so the next deploy has work. Patchy.
