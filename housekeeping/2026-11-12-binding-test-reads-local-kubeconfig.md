# 2026-11-12 · `cli/kix/src/cluster/binding.rs` · The test `a_locked_cluster_whose_uid_is_unreadable_says_so` fails when a kubeconfig is present.

The test passes `Connection::of_context(None)` and expects the message to say "the current context". On a machine whose kubeconfig has a current context (here `kind-kixtest`), the message names that context and its URL instead, so `cargo test -p kix-lib` fails for reasons unrelated to the change under test. The test should pin the connection it describes instead of reading the developer's kubeconfig.
