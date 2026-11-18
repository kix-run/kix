+++
kind = "changed"
packages = ["experimental/prometheus"]
+++
`prometheus` now runs Prometheus 3.16.0 (was 3.13.5). The first deploy
restarts each Prometheus pod once, and the server keeps the data it had.
Prometheus 3.15 deprecates the `--log.level` flag, which the operator passes
when the Prometheus resource sets `logLevel`, so the server may log a
warning. Prometheus 3.16 sets `--web.external-url` to an `https` address
when its web config turns on TLS. To go back, run `kix rollback` or deploy
the previous Kix version.
