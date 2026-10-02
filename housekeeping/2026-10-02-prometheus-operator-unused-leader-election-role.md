# 2026-10-02 · `kix/packages/prometheus-operator/operator.nix` · The operator gets a leader-election Role for a lease it never takes.

The operator has no leader election upstream, so the package runs it under `meta.availability.max = "none"` with one replica. `operatorLeaderElection` still grants create, get, update and patch on `coordination.k8s.io` leases, plus write access to ConfigMaps and events, in the instance's namespace. Whether the operator writes those ConfigMaps or events is not known.
