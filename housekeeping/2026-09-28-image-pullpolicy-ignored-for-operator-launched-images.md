# 2026-09-28 · `kix/packages/prometheus-operator`, `kix/packages/tailscale` · `pullPolicy` on `prometheusConfigReloader.image` and `proxyImage` does nothing.

Both options come from `kix.options.image`, so they expose `pullPolicy`, but the package only passes `kix.image.ref` of them to an operator (`--prometheus-config-reloader` and the tailscale `PROXY_IMAGE` env). The operator creates those containers and chooses their `imagePullPolicy` itself, so an instance that sets `pullPolicy` sees no change and no error.
