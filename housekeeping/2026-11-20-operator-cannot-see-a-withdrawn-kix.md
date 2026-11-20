# 2026-11-20 · `cli/kix-operator` · The operator keeps deploying with a withdrawn Kix, because it never reads the release index.

`kix deploy` and `kix rollback` refuse to change a cluster when the Kix that runs them was withdrawn (`cli/kix-cli/src/commands/deploy/withdrawn.rs`). They learn this from the signed release index on kix.run. The operator runs in the cluster, often with no route to kix.run, so it applies every queued Activation with its own Kix even when that release was withdrawn. `kix deploy --operator` checks only the CLI's version, which can differ from the operator's.

Options:

1. The CLI that queues an Activation reads the operator's version (its image tag, or a field the operator writes into its status) and checks it against the CLI's kept index. It costs one more read and a version field the operator publishes, and it trusts the CLI. A deploy started some other way gets no check.
2. The operator fetches the signed index itself, at start and once a day. It needs an egress rule to kix.run in the operator package's network policy and the index key in the operator, and clusters with no egress get no check.
3. The CLI copies the signed index into the cluster, for example into a ConfigMap, on every deploy, and the operator verifies it with its built-in index key. No egress is needed, and the index is as fresh as the last CLI deploy. This is the most work.

I recommend option 3: the operator stays offline and still checks a signed fact.
