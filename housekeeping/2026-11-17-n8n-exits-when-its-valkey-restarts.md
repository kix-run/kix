# 2026-11-17 · `kix/packages/experimental/n8n` · n8n exits whenever its standalone valkey restarts for more than 10 seconds.

n8n requires a standalone valkey, which is down while its one pod restarts. In a kind deploy of a valkey version upgrade, the main and worker containers both logged "Unable to connect to Redis after trying to connect for 10s" and "Exiting process due to Redis connection error", then restarted once. Every valkey restart, upgrade, or node drain does the same, and the package header does not say so. n8n's `QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD` sets that 10-second limit.
