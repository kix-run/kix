# 2026-10-03 · `cli/kix/src/cluster/fetch.rs` · The discovery settle loop walks every group version again, one at a time, on each retry.

`discover_resources` repeats the whole `discovery_pass` until no listed group version answers 404. On a cluster with 200 group versions that is about 3,000 GETs inside `DISCOVERY_SETTLE` (30 s), and while CRDs are being added or removed some group version may 404 on every pass, so discovery never settles. Re-fetching only the group versions that were missing, concurrently, would avoid both.
