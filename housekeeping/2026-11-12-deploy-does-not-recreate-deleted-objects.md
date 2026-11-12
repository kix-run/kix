# 2026-11-12 · `kix deploy` · A deploy with no build change does not recreate a Kix object someone deleted.

After `kubectl delete svc cnpg-webhook-service`, `kix deploy` printed "activation identical to active. Nothing to apply." and a deploy with an unrelated change wrote only the changed objects, so the Service stayed missing until `--reconcile`. `kix diff` and `kix health` show the missing object; the deploy output does not mention it.
