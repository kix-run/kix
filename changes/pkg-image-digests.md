+++
kind = "note"
packages = ["victoria-metrics-agent", "victoria-metrics-alert", "victoria-metrics-operator", "experimental/cloudflared", "experimental/dns-exporter", "experimental/filebrowser", "experimental/firezone", "experimental/smartctl-exporter", "experimental/vaultwarden"]
+++
The default images of `victoria-metrics-agent`, `victoria-metrics-alert`, `victoria-metrics-operator`, `cloudflared`, `dns-exporter`, `filebrowser`, `firezone`, `smartctl-exporter`, and `vaultwarden` now name their registry and are pinned by digest, as the other packages' images are. The image content stays the same, but the image reference changes, so the first deploy after the upgrade restarts these pods once. The busybox init containers of `vaultwarden` and `firezone` take their image from a new `init.image` option. An instance that sets its own `image` is not affected.
