+++
kind = "note"
packages = ["victoria-metrics-agent", "victoria-metrics-alert", "victoria-metrics-operator", "experimental/cloudflared", "experimental/dns-exporter", "experimental/filebrowser", "experimental/firezone", "experimental/smartctl-exporter", "experimental/vaultwarden"]
+++
No configuration changes are needed. On the first deploy after you upgrade, pods in `victoria-metrics-agent`, `victoria-metrics-alert`, `victoria-metrics-operator`, `cloudflared`, `dns-exporter`, `filebrowser`, `firezone`, `smartctl-exporter`, and `vaultwarden` that use the package's default image restart once. Those defaults still run the same image versions, now written with their registry host and `sha256` digest. `firezone` and `vaultwarden` also move their BusyBox init containers to a new `init.image` option with a pinned default, so `firezone` pods (and `vaultwarden` pods with `initChownData = true`) restart once even when `image` is set.
