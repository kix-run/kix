# 2026-10-01 · `kix/lib/eval/cluster.nix` · Two instances that emit the same object leave one copy in `rawManifests` and no error.

`dedupeByOutPath` in `kix/lib/eval/cluster.nix` keeps the first of two identical resources. Two same-named `prometheus-default-rules` instances in different namespaces used to emit the same kube-system bridge Service, and the build kept one of them. `architecture.monitorSelectorMatchesService` still reported "matches 2 Services: kube-system/X, kube-system/X", so the only sign was a warning naming one object twice.

- Hit again 2026-10-02 in `kix/packages/ingress-nginx`: two same-named instances in different namespaces rendered byte-identical IngressClasses, and the build kept one without an error, so both controllers would have served it. Any cluster-scoped object whose content does not include the instance's namespace has the same hole.
