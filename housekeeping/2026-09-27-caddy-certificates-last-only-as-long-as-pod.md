# 2026-09-27 · `kix/packages/caddy` · Each Caddy pod keeps its own certificate storage on an emptyDir, so every new pod issues certificates again.

Caddy stores certificates, OCSP staples and ACME account keys under
`/data`, which the package mounts as an emptyDir. A rollout, an HPA
scale-up to `hpa.maxReplicas` (10) or a rescheduled pod each start
empty and request new certificates, which can reach ACME rate limits
for sites that use automatic HTTPS. Caddy supports shared storage
modules for a replicated deployment.
