# 2026-11-12 · `cli/kix/src/cluster/binding.rs` · A unit test fails when the machine's kubeconfig has a current context.

`a_locked_cluster_whose_uid_is_unreadable_says_so` calls `Connection::of_context(None)`, which reads the developer's kubeconfig. With a kind cluster as the current context, the refusal text names that context and the test's assertions fail. `cargo test -p kix-lib --lib` then fails on a machine where nothing is wrong.
