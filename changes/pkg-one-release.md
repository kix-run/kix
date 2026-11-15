+++
kind = "changed"
packages = ["secret", "secret-ref", "experimental/envoy-gateway", "experimental/smartctl-exporter"]
+++
No configuration changes are needed. `secret` and `secret-ref` no longer report the placeholder version `1.0.0`, and `envoy-gateway` no longer reports `1.1.0`. None of those packages runs software of its own, so `kix list packages` now shows `-` for them and their `PackageInstance` records omit `spec.version`. `smartctl-exporter` now reports `0.14.0`, the exporter version it runs, and keeps the same container image. Before, it reported `0.16.0`, its Helm chart version.
