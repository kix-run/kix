# 2026-11-28 · `cli/kix/src/cluster/revision/spec.rs` · A Kix built from main before format 2 reports every format 2 revision as modified outside Kix.

Such a Kix re-serializes the spec without `format`, `needs`, and `imports`, gets a name mismatch, and refuses the revision. The same goes for an operator of that build. No release wrote format 1, so only developer and test clusters deployed from main between the revisions merge and design 182 meet it, but nothing refuses the older Kix up front with a clear message.
