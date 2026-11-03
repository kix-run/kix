# 2026-11-02 · `kix/lib/vocab/monitor.nix` · `kix.monitor` cannot give its primary endpoint a bearer token, so a program that authorizes its /metrics cannot be scraped.

metrics-server serves /metrics only behind delegated authentication, so it
needs `bearerTokenFile` (or `authorization`) on the ServiceMonitor endpoint.
The Prometheus ServiceAccount already may `get` the `/metrics` URL, but the
builder only passes `scheme`, `tlsConfig`, `params`, and `honorLabels`.
metrics-server therefore ships no monitor, and nothing sees a kubelet it
fails to scrape (`metrics_server_kubelet_request_total`, pkg/scraper/scraper.go
at v0.9.0). prometheus-default-rules works around it by building its
ServiceMonitors directly.
