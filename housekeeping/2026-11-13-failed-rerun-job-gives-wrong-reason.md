# 2026-11-13 · `cli/kix/src/cluster/apply/mod.rs` · A rerun Job recreated because its last run failed is reported as "changed its own content".

Seen on kind. A bootstrap Job's run fails. The user fixes the Secret it reads and deploys a change that only touches a namespace label. The Job's `kix.run/rerun-hash` is the same as in the failed run. Kix recreates the Job, which is correct. But the plan says the Job "changed their own content", and the deploy logs "rerun: changed since the last run". The real reason is that the last run failed.

`changed()` compares the new rerun hash with the manifest in the Active record. That record is the deploy before the failure. The failed record's rerun hash is compared only on the Skip path, so the content-change reason wins on the Apply path. A fix: compare against the failed closure's rerun hash on the Apply path too, as the Skip path already does. The engine then names the "last run failed" reason it already has.
