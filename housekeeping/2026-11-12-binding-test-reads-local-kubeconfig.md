# 2026-11-12 · `cli/kix/src/cluster/binding.rs` · The test `a_locked_cluster_whose_uid_is_unreadable_says_so` fails when the developer's kubeconfig has a current context.

`Connection::of_context(None)` reads the machine's kubeconfig, so the refusal names that context, such as `kind-kixtest (https://127.0.0.1:34447)`, and not "the current context" that the test expects. `cargo test -p kix-lib` fails on any machine with a kind cluster selected, and passes in CI. The test should build its `Connection` without reading the kubeconfig.
