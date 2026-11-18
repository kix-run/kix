# 2026-11-18 · `kix/packages/experimental/prometheus` · The Prometheus server discovers ServiceMonitor targets through the deprecated Endpoints API.

The package leaves `serviceDiscoveryRole` unset, so the operator writes `role: endpoints` scrape configs. On Kubernetes 1.37 (kind), Prometheus 3.16.0 logs "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice" at start. The package already grants the `endpointslices` permission, so the operator's `serviceDiscoveryRole: EndpointSlice` would work. Kubernetes has not said when it removes Endpoints.
