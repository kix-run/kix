# 2026-11-13 · `cli/kix/src/cluster/errors.rs` · A missing kubeconfig file is reported as a kubeconfig with no current context.

`KUBECONFIG=/nonexistent kix status` says "your kubeconfig has no current context", and the real cause appears only in "(Details: ...)". `kix history` adds "failed to connect to cluster:" in front, as about ten other commands do (`miette!("failed to connect to cluster: {e}")`). Suggested text: "Kix cannot read the kubeconfig at /nonexistent (KUBECONFIG): no such file. Set KUBECONFIG to an existing file or pass --context."
