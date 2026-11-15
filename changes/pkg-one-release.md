+++
kind = "changed"
packages = ["secret", "secret-ref", "experimental/envoy-gateway", "experimental/smartctl-exporter"]
+++
`secret`, `secret-ref`, and `envoy-gateway` no longer report a version, because they deploy no upstream software of their own. Their `PackageInstance` records drop the placeholder versions `1.0.0` and `1.1.0`. `smartctl-exporter` now reports the version of the exporter it runs, `0.14.0`, rather than the version of its Helm chart, `0.16.0`.
