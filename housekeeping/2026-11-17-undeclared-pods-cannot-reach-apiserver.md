# 2026-11-17 · `clusters/test-cnpg.nix` · Pods that no package declares cannot reach the Kubernetes API.

A `Cluster` applied with kubectl (not by Kix) never finishes initdb: the Job fails with `dial tcp 10.96.0.1:443: i/o timeout`. It happens on 1.30.1 too, so no package bump caused it. The Cilium endpoint for such a pod enforces egress, and its only realized egress rule is DNS from `cilium-cluster-dns-egress` (`endpointSelector: {}`), so `kube-apiserver` is not allowed. Check whether that policy should allow the apiserver for every pod, or whether `networkPolicy.enable` should exempt it.
