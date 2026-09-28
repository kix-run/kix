# 2026-09-27 · `kix/packages/valkey` · With Sentinel off and `replicaCount` above one, valkey runs that many unrelated primaries.

Every pod of the `<name>-primary` StatefulSet runs `start-primary.sh`, and
the `<name>` Service balances across them, so clients see a different
dataset per connection. Nothing rejects the combination. It needs either an
assertion that standalone means one pod, or replicas that follow pod 0.
