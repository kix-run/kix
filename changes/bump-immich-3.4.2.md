+++
kind = "fixed"
packages = ["experimental/immich", "experimental/immich-machine-learning"]
+++
`immich` and `immich-machine-learning` now run Immich 3.4.2 (was 3.4.1), a bug fix release. The server's Prometheus exporter now listens on `IMMICH_HOST`, or on all IPv4 and IPv6 addresses when that is unset, instead of IPv4 only, so the metrics ports answer in an IPv6 cluster. Hardware transcoding with VAAPI no longer forces a limited colour range, and integrity report downloads work again. Immich 3.4.2 adds no database migrations, so you can go back to 3.4.1 by deploying the older release. The first deploy restarts the server and the machine-learning worker once.
