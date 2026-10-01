# 2026-10-01 · `kix/lib/meta.nix` · A package's Kubernetes range is never checked, because no cluster sets `k8sVersion`.

`checkMetaStatic` returns no assertions when `k8sVersion` is null, and no cluster in kixpkgs or the monorepo sets it. Ten packages declare `meta.k8s.minVersion` and pass on any cluster. Doc 155 §2 and principle 4 propose a warning for a package range on an unset version.
