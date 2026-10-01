# 2026-09-28 · `kix/lib/rules/security.nix` · No scorecard rule reports a container image that has no digest.

`security.noLatestTag` catches `:latest` only. Every hand-written package now
accepts a digest through `kix.options.image`, but a cluster that never pins
one gets no warning, so tag-only references go unnoticed.

- Hit again 2026-10-01 while fixing the monitoring-package sweep: the default images of cloudflared, dns-exporter, filebrowser, vaultwarden, node-exporter, kube-state-metrics, and the grafana sidecar carry no digest, and some (`cloudflare/cloudflared`, `tykling/dns_exporter`, `filebrowser/filebrowser`, `vaultwarden/server`) no registry host.
