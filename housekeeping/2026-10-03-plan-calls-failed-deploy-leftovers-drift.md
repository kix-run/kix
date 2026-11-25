# 2026-10-03 · `cli/kix-cli/src/commands/plan.rs` · `kix plan` labels what a failed deploy left behind as drift.

Objects a failed deploy applied are folded into the plan and compared with
the Active record's manifests. Their differences are labelled `reverts_drift`
with no manager named, although no one changed them by hand: the failed
deploy wrote them.
- Hit again 2026-11-25 while testing `kix deploy --only`: a full deploy after a partial one labelled the partial deploy's changes `(reverts drift)`.
