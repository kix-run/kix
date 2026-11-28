# 2026-11-28 · `cli/kix/src/plan/decide.rs` · Objects of a revision read from a build are labelled "left by a degraded deploy".

When the current record is `Degraded` and one of its revisions is lost, the plan reads the revision from a build with no applied hashes (`Tenancy::with_rebuilt`). Each of its objects then has no applied hash, so `decide` labels the write `LeftByDegraded` ("its deploy did not reach it"), when the real reason is that the applied hashes were lost. The write itself is right; only the reason the plan shows is wrong. Look at the label choice near `decide.rs:391`.
