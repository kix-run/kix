# 2026-11-25 · `cli/kix/src/cluster/client.rs` · The client and the description of where it connects read the kubeconfig separately.

`make_client` builds its config with `Config::infer` or `Config::from_custom_kubeconfig`, and `binding::Connection::of_context` reads the kubeconfig again to name the context and server. They agree for every kubeconfig, but with no kubeconfig `Config::infer` falls back to the in-cluster service account while `of_context` says "the current context" with no server. Having `make_client` return the `Connection` from the config it used would leave one owner.
