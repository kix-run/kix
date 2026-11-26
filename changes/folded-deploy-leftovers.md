+++
kind = "fixed"
+++
A plan that folds in a deploy that did not finish, one that stopped or one `kix deploy --only` left partly deployed, no longer lists objects that deploy never created as left behind, no longer tries to delete them with `--prune`, and no longer records its build under `status.orphansKeptFrom` when it left nothing. An object counts as left behind only when the cluster holds it with that deploy's record in its `kix.run/activations` annotation. A field such a deploy wrote is shown as written by that deploy record, under `earlier_deploys` in the plan document, and no longer as drift.
