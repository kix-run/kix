+++
kind = "error"
state = true
id = "K9557"
+++
The deploy lock needs permissions that Kix did not ask for before. The account that first runs `kix deploy`, `kix rollback`, `kix gc`, or `kix migrate domain` on a cluster after the upgrade needs `get` and `create` on `customresourcedefinitions`, once, to create `activationheads.kix.run`, and every account that changes the cluster needs `get`, `list`, `create`, and `update` on `activationheads.kix.run`; without them the command stops with `[K9557]` before it changes anything. The Kix operator needs the same, and must be upgraded before the first deploy by the new `kix`: `kix deploy --operator` and `kix rollback --operator` stop with `[K9557]` when the operator does not list `head-lock` in `kix.run/operator-features`.
