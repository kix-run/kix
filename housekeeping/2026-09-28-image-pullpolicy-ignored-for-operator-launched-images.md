# 2026-09-28 · `kix/packages/prometheus-operator` · `pullPolicy` on `prometheusConfigReloader.image` does nothing.

The option comes from `kix.options.image`, so it exposes `pullPolicy`, but the package only passes `kix.image.ref` of it to the operator (`--prometheus-config-reloader`). The operator creates the sidecar and takes its `imagePullPolicy` from the Prometheus or Alertmanager resource, so an instance that sets `pullPolicy` sees no change and no error. The option's description says so; nothing refuses it.
