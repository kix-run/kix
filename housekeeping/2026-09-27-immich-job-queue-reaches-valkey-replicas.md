# 2026-09-27 · `kix/packages/immich` · At availability "node" immich's job queue can connect to a read-only valkey replica.

immich sets `REDIS_HOSTNAME = valkey.out.fqdn`. From "node" up valkey runs
Sentinel with three pods, and the `valkey` Service selects all of them, so
a queue write that lands on a replica fails with READONLY. immich accepts a
Sentinel configuration through `REDIS_URL` (`ioredis://` with base64 JSON),
which the package does not set. n8n avoids this by asking for a standalone
valkey (`deps.valkey.config` in `kix/packages/n8n`).
