# 2026-10-03 · `kix/lib/flavors/ovh.nix`, `scaleway.nix` · The OVH and Scaleway flavours leave the metricsApi role unbound, and nobody has checked whether those environments ship metrics-server.

With the binding unknown, a metrics-server instance evaluates without a
warning on either flavour and renders APIService v1beta1.metrics.k8s.io. If
OVH Managed Kubernetes or Scaleway Kapsule already runs metrics-server, the
instance replaces the environment's APIService. Check each provider's
documentation, then bind the role `exclusive` or `absent`.
