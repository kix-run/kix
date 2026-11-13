# 2026-11-13 · `kix/src/cluster/client.rs` · The dry run retries a write whose webhook Service is missing 7 times before it reports it.

With `cnpg-webhook-service` deleted, `kix deploy --reconcile` printed `WARN giving up on apiserver request ... attempts=7 elapsed_ms=19976` once per CloudNativePG object before listing them as not checked. Each object costs about 20 seconds. A `service "…" not found` webhook error does not change on retry, so it could skip the retries.
