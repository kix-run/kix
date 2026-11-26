# 2026-11-25 · `cli/kix/src/cluster/readiness/declared.rs` · `kix status` shows ok for a resource whose operator reports a failing feature.

A CloudNativePG `Cluster` stays `Ready=True` while archiving to its backup store fails, and reports `ContinuousArchiving=False`. Readiness reads only the declared ready rule and `failed` states, and a `failed` rule would stop deploys on a failure that may clear by itself. So no package declaration can make `kix status` warn about it. The limit is now in the docs (`check-resource-status.mdx`, "What readiness does not show").
Decision required from the maintainers: add a declared "health" condition list that `kix status` reports as a warning and a deploy never waits on, or keep the documented limit.
