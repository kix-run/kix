# 2026-09-27 · `kix/packages/cert-manager` · The cert-manager controller has no readiness probe and cainjector has no probes at all.

cert-manager v1.17.1 serves only `/livez` on the controller's port 9403
(`/readyz` and `/healthz` answer 404), and cainjector serves only
`/metrics` on 9402. The upstream chart probes the controller's liveness and
nothing on cainjector, so `reliability.hasProbes` warns three times for the
package. Both are leader-elected controllers with no Service traffic, so a
readiness probe would gate nothing; the gap that matters is that
`kix deploy` counts cainjector Ready as soon as its process starts.
