# 2026-10-02 · `kix/packages/node-exporter` · node-exporter cannot read /run/udev/data, so diskstats metrics carry no udev device properties.

On kind (kind/w9-ludo) the exporter logs `level=ERROR source=diskstats_linux.go:255 msg="Failed to open directory, disabling udev device properties" collector=diskstats path=/run/udev/data` at start. The package mounts the host's /, /proc, and /sys but not /run/udev/data, and passes no `--collector.diskstats.device-include` or udev path flag, so labels such as the disk serial are missing.
