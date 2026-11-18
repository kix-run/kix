# 2026-11-18 · `experimental/tempo` · Tempo deletes a WAL block without meta.json on every restart, and logs only a warning.

On each pod start, Tempo 3.1.0 and 3.1.1 log `failed to replay block. removing.` for a 4 KB block in `/var/tempo/live-store/traces` that has no `meta.json`. The same warning appears after a restart of 3.1.1 on 3.1.1, so the bump does not cause it. We did not check whether the removed block held spans. Source: `tempodb/wal/wal.go:117` in grafana/tempo v3.1.1. Seen on the `test-tempo` kind cluster.
