# 2026-11-17 · `clusters/test-cnpg.nix` · Pods that no package declares cannot reach the Kubernetes API.

A `Cluster` applied with kubectl to a fresh namespace in test-cnpg never finishes its initdb Job: the Job retries and fails with `dial tcp 10.96.0.1:443: i/o timeout`. A plain busybox pod in that namespace times out on the same address. The cluster-wide policy `cilium-cluster-dns-egress` has `endpointSelector: {}` and allows only DNS, and I did not confirm that it is the rule that drops the traffic. Check that first.
