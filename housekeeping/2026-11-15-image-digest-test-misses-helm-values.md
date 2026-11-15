# 2026-11-15 · `kix/lib/tests/units/image-digests.nix` · The image digest test cannot see images that Helm chart values set.

The test reads `kix.options.image` declarations and image string literals in package files. A package that wraps a Helm chart sets its images in chart values (`smartctl-exporter`'s `defaultValues.image`, the chart defaults of `cilium`), so a tag without a digest there passes. `smartctl-exporter` is pinned today by putting the digest in the tag. A check over the rendered manifests of the test clusters would cover every image, at the cost of building them.
