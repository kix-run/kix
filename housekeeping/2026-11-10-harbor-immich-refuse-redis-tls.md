# 2026-11-10 · `kix/packages/harbor`, `kix/packages/immich` · Harbor and Immich refuse a Redis server with TLS, so they cannot use ElastiCache with encryption in transit.

Both call `kix.contracts.redis.requirePlaintext`, because their packages build plain `redis://` addresses and ioredis options without `tls`. Harbor documents `rediss://` URLs and Immich passes ioredis options through, so both can likely connect over TLS. Check the upstream clients at the pinned releases, then map `out.tls` onto them, as n8n does with `QUEUE_BULL_REDIS_TLS`.
