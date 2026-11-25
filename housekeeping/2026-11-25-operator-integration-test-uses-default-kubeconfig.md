# 2026-11-25 · `cli/kix-operator/tests/operator_integration_test.rs` · The ignored operator end-to-end test writes to and reads from the default kubeconfig.

It runs `kind create cluster --name ...` and `kubectl --context ...` without `--kubeconfig`, so running it adds a context to the developer's `~/.kube/config` and relies on the context name alone to pick the cluster. A test that passes its own kubeconfig file on every `kind` and `kubectl` call, and to the operator subprocess through `KUBECONFIG`, could not touch another cluster by mistake.
