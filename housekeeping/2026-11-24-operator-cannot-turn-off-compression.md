# 2026-11-24 · `cli/kix-operator/src/main.rs` · The operator has no way to turn off gzip compression of API server responses.

The operator builds its client from `kube::Config::infer()`. In a pod with no kubeconfig, that is the in-cluster config, which always asks for gzip. The CLI's off switch is the kubeconfig field `disable-compression: true`, and the operator has no matching setting. A cluster whose API server or proxy mishandles compressed responses would leave the operator with no workaround short of mounting a kubeconfig into its pod.
