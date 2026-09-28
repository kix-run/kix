# 2026-09-27 · `kix/packages/grafana` · The root `init-chown-data` init container runs even when /var/lib/grafana is an emptyDir.

The grafana chart renders `init-chown-data` only when `persistence.enabled`
is set; the package runs it always, so every Grafana pod starts a root
container and the package needs the `run-as-root` grant. The pod's
`fsGroup: 472` already makes an emptyDir writable. The grafana-community
chart (13.2.6) also adds `DAC_OVERRIDE` to the container, which the package
lacks, so `chown -R` may fail to enter directories Grafana created with
mode 0700 on a reused volume.
