# 2026-11-18 · `experimental/infisical-operator` · Upstream documents Kubernetes 1.29 as supported, but its CI tests 1.30 to 1.33 only.

The package declares 1.29 to 1.33 in `meta.k8s`, from the supported-versions list on Infisical's Kubernetes overview page. The repo's `ct.yaml` tests only 1.30 to 1.33, so 1.29 has no upstream test. Check upstream's stated range again at each bump. See `kix/packages/experimental/infisical-operator/default.nix`, `meta.k8s`.
