# 2026-10-02 · `kix/packages/smartctl-exporter` · smartctl-exporter fails four items of the package checklist.

- `releaseName = "smartctl-exporter"` (`default.nix:75`) fixes the rendered names, so two instances in one namespace collide.
- `meta.version` is the chart version 0.16.0, not the exporter version v0.14.0 that the image runs.
- The default image `quay.io/prometheuscommunity/smartctl-exporter:v0.14.0` has no digest.
- No test cluster builds the package; only `every-package-evaluates` reaches it.

The missing monitoring is its own entry, `2026-10-02-smartctl-exporter-has-no-kix-monitoring.md`.
