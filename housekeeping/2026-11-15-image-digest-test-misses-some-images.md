# 2026-11-15 · `kix/lib/tests/units/image-digests.nix` · The image digest test cannot see images set outside `kix.options.image`.

The test reads `kix.options.image` declarations and image string literals in package files. Two kinds of default image escape it:

- Helm chart values (`smartctl-exporter`'s `defaultValues.image`, the chart defaults of `cilium`). `smartctl-exporter` is pinned today by putting the digest in the tag.
- A version string an operator turns into images. `victoria-metrics-cluster` sets `spec.clusterVersion = "v1.156.0-cluster"`, and the operator runs vmstorage, vmselect, and vminsert from it with no digest. Pinning them needs a `kix.options.image` per component, rendered into each component's `spec.<component>.image`.

A check over the rendered manifests of the test clusters would cover the first kind, at the cost of building them. Neither covers images an operator picks itself, such as the VictoriaMetrics config-reloader.
