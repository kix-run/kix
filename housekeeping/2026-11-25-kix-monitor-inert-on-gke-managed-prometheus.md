# 2026-11-25 · `kix.monitor` · Nothing tells a GKE user that Managed Service for Prometheus ignores what `kix.monitor` writes.

GKE enables Google Cloud Managed Service for Prometheus by default. It reads `PodMonitoring` and other `monitoring.googleapis.com` resources, not ServiceMonitor or PrometheusRule. On a GKE cluster without a Prometheus that Kix knows, `kix.monitor` output does nothing, and no build warning says so. The flavor has no field to state which monitoring API the platform reads.
