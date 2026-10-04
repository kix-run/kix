# 2026-10-04 · `kix/lib/vocab` · Packages parse Prometheus durations into seconds with their own copy of the same helper.

cnpg-cluster and stackgres-cluster each define `durationType` and
`durationSeconds`, because an alert compares a gauge in seconds with a
threshold option written as a duration ("5m", "26h"). kix/lib has no shared
type or parser for Prometheus durations, so the next package with a duration
threshold will copy it again, and the copies can drift in which units they
accept.

- Hit again 2026-10-04 while deriving Loki's stale-compaction threshold: loki now parses `compactor.compaction_interval` with its own `intervalSeconds` and formats seconds back with `promDuration`.
