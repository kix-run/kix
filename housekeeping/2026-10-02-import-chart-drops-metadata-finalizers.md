# 2026-10-02 · `kix/lib/helm.nix` · `importChart` drops `metadata.finalizers` from every chart resource.

`wrapResource` passes a resource's labels, annotations and name to `mkResource`
and filters `metadata` out of `extra` (`standardFields`), so any other metadata
field a chart renders is lost without a warning. The upstream
gha-runner-scale-set chart puts `actions.github.com/cleanup-protection` on the
runner set's Role, RoleBinding and ServiceAccount; imported through Helm they
never carried it, which is one reason `arc-runner-set` is now Kix-native. Any
chart that relies on a finalizer or `ownerReferences` is affected.
