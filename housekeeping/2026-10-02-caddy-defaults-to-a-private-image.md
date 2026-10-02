# 2026-10-02 · `kix/packages/caddy` · caddy defaults to a private image in a customer's registry, so it does not work as a public package.

The `image` option defaults to `ghcr.io/northwind/shopfront/caddy:2.10.0-cf`, a custom build. The rest of its interface differs from other packages: `hpa` takes renamed HorizontalPodAutoscaler fields (`targetCPUUtilization`) instead of the HPA `spec`, `replicaCount` is not the `replicas` name other packages use, and the Caddyfile arrives through a Secret named by the string option `configSecretName`, wrapped in `scope.mkSecretRef`. No cluster in kixpkgs or kix-examples instantiates it. Certificates: `2026-09-27-caddy-certificates-last-only-as-long-as-pod.md`.

Decision required from Adam: rework caddy as a public package (upstream image, HPA `spec`, the Caddyfile through a dependency) or delete it.
