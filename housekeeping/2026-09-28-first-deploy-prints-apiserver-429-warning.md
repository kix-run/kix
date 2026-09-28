# 2026-09-28 · `cli/kix/src/cluster/client.rs` · The first `kix deploy` to a fresh cluster prints a WARN line about a 429 from the apiserver.

Right after the deploy creates `CustomResourceDefinition/packageinstances.kix.run`,
a GET on `/apis/kix.run/v1alpha1/activations` returns "429 Too Many Requests"
once, the client retries it, and the retry succeeds. The deploy completes,
but the retry's WARN line lands in the middle of the plan output. It
reproduced on two fresh kind clusters and is committed in the docs capture
`docs/src/command-output/tutorials/02-hello-world/deploy.json`, so the
hello-world tutorial shows a warning to a first-time reader.
