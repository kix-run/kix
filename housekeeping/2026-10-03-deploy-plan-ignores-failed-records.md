# 2026-10-03 · `cli/kix/src/plan/saved.rs` · `kix deploy --plan` does not compare the failed deploy records folded into the plan.

A deploy that fails after the review leaves a Failed Activation record. The
next deploy folds its closure into the plan, which changes the old side and
the orphans and can turn skipped objects into applies, while the new and
deployed identity hashes still match. Reverted drift and new prune deletes
catch most of the effect, but no rule names the failed record itself.
