# Alert rules over ClickHouse's built-in Prometheus endpoint, shared by the
# clickhouse and clickhouse-cluster packages so both alert on the same
# conditions under the same names. Each package passes the selector of its
# own scrape and the facts it knows; this file derives the thresholds.
#
# Metric names are those ClickHouse 26.3 writes
# (src/Server/PrometheusMetricsWriter.cpp): `ClickHouseMetrics_*` from
# system.metrics, `ClickHouseAsyncMetrics_*` from system.asynchronous_metrics,
# and `ClickHouseProfileEvents_*` from system.events, counters without a
# `_total` suffix. The server writes every metric and event, zeros included,
# so a missing series means the endpoint or one of its sections is off.
#
# Arguments:
#   sel          PromQL label matchers for the instance's series, no braces
#   by           the labels that identify the scrape, "namespace, service"
#                or "namespace, job"; per-server rules add `pod`
#   instance     "<namespace>/<name>", for descriptions
#   memoryLimit  the container memory limit, or null for no memory rule
#   fragments    the merged serverConfig fragments, read for
#                merge_tree.parts_to_delay_insert, max_server_memory_usage,
#                and max_server_memory_usage_to_ram_ratio
#   maxReplicationLag  seconds, or null on a single replica, which turns off
#                the lag and fetch rules
{ lib, kix }:
{
  sel,
  by,
  instance,
  memoryLimit,
  fragments,
  maxReplicationLag ? null,
}:
let
  perServer = "${by}, pod";

  # ClickHouse merges config.d files in name order, so for a key set in two
  # fragments the one whose name sorts last wins. attrNames sorts the same way.
  setting =
    path: default:
    let
      found = builtins.filter (v: v != null) (
        map (fragment: lib.attrByPath path null fragments.${fragment}) (builtins.attrNames fragments)
      );
      value = lib.last found;
    in
    if found == [ ] then
      default
    else if builtins.isString value then
      builtins.fromJSON value
    else
      value;

  # Inserts are throttled at parts_to_delay_insert active parts in one
  # partition (1000 by default in 26.3) and refused at parts_to_throw_insert
  # (3000). A table's own SETTINGS can lower it; the rule reads the server
  # default only.
  partsToDelayInsert = setting [ "merge_tree" "parts_to_delay_insert" ] 1000;
  partsThreshold = partsToDelayInsert / 2;

  # The server's memory cap: max_server_memory_usage_to_ram_ratio (0.9) of
  # the cgroup limit, or max_server_memory_usage when that is set and lower.
  # A cap of 0 means no cap. Queries over it fail with MEMORY_LIMIT_EXCEEDED.
  limitBytes = if memoryLimit == null then null else kix.parseQuantity "memory" memoryLimit;
  ratioCap = builtins.floor (limitBytes * setting [ "max_server_memory_usage_to_ram_ratio" ] 0.9);
  fixedCap = setting [ "max_server_memory_usage" ] 0;
  memoryCap = if fixedCap == 0 then ratioCap else lib.min fixedCap ratioCap;
  memoryThreshold = builtins.floor (memoryCap * 0.9);
  mebibytes = bytes: "${toString (bytes / 1048576)} MiB";
in
{
  ClickHouseDown = {
    expr = "sum by (${by}) (up{${sel}}) == 0 or absent(up{${sel}})";
    "for" = "10m";
    severity = "critical";
    summary = "ClickHouse is down.";
    description = "Prometheus has scraped no ClickHouse server of ${instance} for 10 minutes, so it serves no queries and accepts no inserts. Check its pods and their logs.";
  };

  # One metric per section the rules below read; the endpoint can turn each
  # section off on its own.
  ClickHouseMetricsMissing = {
    expr = "count by (${by}) (up{${sel}} == 1) unless on (${by}) (count by (${by}) (ClickHouseMetrics_ReadonlyReplica{${sel}}) and on (${by}) count by (${by}) (ClickHouseAsyncMetrics_MaxPartCountForPartition{${sel}}) and on (${by}) count by (${by}) (ClickHouseProfileEvents_RejectedInserts{${sel}}))";
    "for" = "10m";
    severity = "warning";
    summary = "ClickHouse is scraped but lacks series its alerts read.";
    description = "The metrics endpoint of ${instance} answers but lacks ClickHouseMetrics_, ClickHouseAsyncMetrics_, or ClickHouseProfileEvents_ series, so its other alerts cannot fire. Check the prometheus section of its server config for metrics, asynchronous_metrics, and events.";
  };

  ClickHouseReplicaReadOnly = {
    expr = "max by (${perServer}) (ClickHouseMetrics_ReadonlyReplica{${sel}}) > 0";
    # A starting server holds its replicated tables read-only until it has a
    # Keeper session.
    "for" = "5m";
    severity = "critical";
    summary = "ClickHouse has read-only replicated tables.";
    description = "{{ $value }} replicated tables on {{ $labels.pod }} of ${instance} are read-only, so inserts into them fail. Check the server's Keeper session and its log for ZooKeeper errors.";
  };

  # Warning, because a lost session makes replicated tables read-only and
  # ClickHouseReplicaReadOnly pages for that.
  ClickHouseKeeperSessionLost = {
    expr = "max by (${perServer}) (ClickHouseMetrics_ZooKeeperSession{${sel}}) == 0";
    "for" = "5m";
    severity = "warning";
    summary = "ClickHouse has no Keeper session.";
    description = "{{ $labels.pod }} of ${instance} has had no Keeper session for 5 minutes, so replicated tables and ON CLUSTER DDL do not work. Check that Keeper is up and reachable from the pod.";
  };

  ClickHouseInsertsRejected = {
    expr = "sum by (${perServer}) (increase(ClickHouseProfileEvents_RejectedInserts{${sel}}[10m])) > 0";
    "for" = "5m";
    severity = "critical";
    summary = "ClickHouse rejects inserts with Too many parts.";
    description = "{{ $labels.pod }} of ${instance} rejected {{ $value | humanize }} inserts in 10 minutes because a partition reached parts_to_throw_insert. Merges are behind the insert rate; check system.parts for the partition and batch the inserts into fewer, larger ones.";
  };

  ClickHouseTooManyParts = {
    expr = "max by (${perServer}) (ClickHouseAsyncMetrics_MaxPartCountForPartition{${sel}}) > ${toString partsThreshold}";
    "for" = "15m";
    severity = "warning";
    summary = "A ClickHouse partition has many active parts.";
    description = "A partition on {{ $labels.pod }} of ${instance} has {{ $value }} active parts. Inserts are throttled at ${toString partsToDelayInsert} and refused at parts_to_throw_insert. Check system.parts for the table and whether its inserts are small and frequent.";
  };

  # Data in a part no replica holds is gone. The 1h window keeps a single
  # occurrence firing for an hour, so the rule needs no `for`.
  ClickHouseReplicatedDataLoss = {
    expr = "sum by (${perServer}) (increase(ClickHouseProfileEvents_ReplicatedDataLoss{${sel}}[1h])) > 0";
    severity = "critical";
    summary = "ClickHouse lost replicated data parts.";
    description = "{{ $labels.pod }} of ${instance} wanted {{ $value | humanize }} parts in the last hour that no replica has. That data is lost. Check the server log for the table and part names, and the history of the replicas that held them.";
  };
}
// lib.optionalAttrs (limitBytes != null && memoryCap > 0) {
  ClickHouseMemoryNearLimit = {
    expr = "max by (${perServer}) (ClickHouseMetrics_MemoryTracking{${sel}}) > ${toString memoryThreshold}";
    "for" = "15m";
    severity = "warning";
    summary = "ClickHouse memory use is near its server cap.";
    description = "{{ $labels.pod }} of ${instance} tracks {{ $value | humanize1024 }}B, over 90% of its ${mebibytes memoryCap} cap. Queries and merges past the cap fail with MEMORY_LIMIT_EXCEEDED. Check system.processes and system.merges, or raise resources.limits.memory.";
  };
}
// lib.optionalAttrs (maxReplicationLag != null) {
  ClickHouseReplicationLag = {
    expr = "max by (${perServer}) (ClickHouseAsyncMetrics_ReplicasMaxAbsoluteDelay{${sel}}) > ${toString maxReplicationLag}";
    "for" = "15m";
    severity = "warning";
    summary = "A ClickHouse replica is behind.";
    description = "{{ $labels.pod }} of ${instance} is {{ $value | humanizeDuration }} behind the newest part of a replicated table. Check system.replication_queue on it for entries with errors.";
  };

  ClickHouseReplicatedFetchesFailing = {
    expr = "sum by (${perServer}) (increase(ClickHouseProfileEvents_ReplicatedPartFailedFetches{${sel}}[15m])) > 0";
    "for" = "15m";
    severity = "warning";
    summary = "A ClickHouse replica keeps failing to fetch parts.";
    description = "{{ $labels.pod }} of ${instance} failed {{ $value | humanize }} part fetches from other replicas in 15 minutes, for at least 15 minutes. Check the server log for the fetch error and the interserver port between replicas.";
  };
}
