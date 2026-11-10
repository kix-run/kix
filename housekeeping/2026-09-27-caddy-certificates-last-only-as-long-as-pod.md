# 2026-09-27 · `kix/packages/caddy` · Each Caddy pod keeps its own certificate storage on an emptyDir by default, so every new pod issues certificates again.

Caddy stores certificates, OCSP staples and ACME account keys under
`/data`, which the package mounts as an emptyDir unless the instance
has a `storage` dependency. A rollout, an HPA scale-up to
`hpa.maxReplicas` (10) or a rescheduled pod each start empty and
request new certificates, which can reach ACME rate limits for sites
that use automatic HTTPS. The optional `storage` dependency now gives
`/data` a claim that every replica shares, but it is not the default,
and with more than one replica it needs a ReadWriteMany class, which
Kix does not check. Caddy's shared storage modules are another route.
