# 2026-10-01 · `kix/lib/eval/cluster.nix` · Two instances that emit the same namespaced object leave one copy in `rawManifests` and no error.

`dedupeByOutPath` in `kix/lib/eval/cluster.nix` keeps the first of two identical resources. Two same-named `prometheus-default-rules` instances in different namespaces used to emit the same kube-system bridge Service, and the build kept one of them. `architecture.monitorSelectorMatchesService` still reported "matches 2 Services: kube-system/X, kube-system/X", so the only sign was a warning naming one object twice.

`sharedClusterObjectAssertions` now refuses a cluster-scoped object that two instances render. A namespaced object that two instances render identically, such as a Service in a shared namespace, still collapses to one copy without an error.
