+++
kind = "changed"
packages = ["experimental/otel-collector"]
+++
`otel-collector` now runs OpenTelemetry Collector Contrib 0.165.0 instead of 0.161.0. The components the package configures read the same settings, so you do not need to change anything. The first deploy after you upgrade replaces each collector pod once. If your `settings` use a component that 0.162.0 to 0.165.0 removed or changed, such as the `wavefront` or `signalfx` receivers or the `transform` processor's `flatten_data`, the collector refuses to start until you update them. Read the upstream changelog for the components you add. To go back, set `image.tag` and `image.digest` to the 0.161.0 image, or deploy the previous Kix version.
