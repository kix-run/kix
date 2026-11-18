+++
kind = "note"
packages = ["experimental/metrics-server"]
+++
`metrics-server` runs upstream 0.9.1 instead of 0.9.0. The new image drops the distrusted eMudhra root certificates from its CA bundle, and it is built with a newer Go. The first deploy after the upgrade restarts the metrics-server pods once. You do not need to change anything.
