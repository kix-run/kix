# 2026-10-03 · `cli/kix/src/plan/saved.rs` · A deploy from a saved `kix diff` cannot catch new drift on objects its own dry run cannot check.

The fresh plan's drift comes only from dry-run answers. An object a webhook
without dry-run support matches has no answer, so it shows no drift, and the
`newly_unchecked` rule applies only to `kix plan` documents. A diff reviewer
saw that object's drift through a live read; drift added since is reverted
without a refusal. Applying the rule to diff plans would refuse every deploy
on a cluster with such a webhook.
