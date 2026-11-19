+++
kind = "fixed"
packages = ["experimental/clickhouse", "experimental/clickhouse-cluster", "experimental/clickhouse-keeper", "experimental/clickhouse-database"]
+++
ClickHouse 26.8.40.7 fixes these bugs in 26.8.39.19. A query that reads `_block_number`, `_block_offset`, or `_row_exists` through a projection that does not store them now returns the right values, and incremental refreshable materialized views (`APPEND INCREMENTAL`) no longer skip source rows. A malformed aggregate state that holds a `LowCardinality(String)` value no longer crashes the server. The error that AI functions return for an insecure endpoint no longer shows the endpoint, which can hold a secret. `SYSTEM SYNC DATABASE REPLICA` without `ON CLUSTER` now needs the `SYSTEM SYNC DATABASE REPLICA` grant on the database, so a user without that grant now gets an error. ClickHouse Keeper also removes old deduplication blocks of `ReplicatedMergeTree` tables in batches, which writes fewer entries to its log.
