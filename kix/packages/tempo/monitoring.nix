# ServiceMonitor and PrometheusRule alerts for the tempo package.
{ release }:
{
  self,
  config,
  scope,
  lib,
  kix,
  storage,
  prometheus ? null,
  ...
}@args:
let
  name = scope.instanceName;
  sel = ''namespace="${scope.namespaceName}",service="${self.service.out.name}"'';
  by = "by (namespace, service)";
  instance = "Tempo ${scope.namespaceName}/${name}";
  runbook = "https://github.com/grafana/tempo/blob/v${release}/operations/tempo-mixin/runbook.md";

  memoryLimit = config.resources.limits.memory or null;
  memoryBytes = if memoryLimit == null then null else kix.parseQuantity "memory" memoryLimit;
  claimSize = storage.out.size or null;
  claimBytes = if claimSize == null then null else kix.parseQuantity "storage" claimSize;

  failingLately =
    grouping: counter:
    "sum by (${grouping}) (increase(${counter}{${sel}}[1h])) > 2 and sum by (${grouping}) (increase(${counter}{${sel}}[5m])) > 0";

  requests =
    filter:
    "sum by (namespace, service, route) (rate(tempo_request_duration_seconds_count{${sel}${filter}}[5m]))";
  failed = requests '',status_code=~"5.."'';
  total = requests "";
in
kix.monitor {
  service = "service";
  port = "http";
  alerts = {
    TempoDown = {
      expr = "sum ${by} (up{${sel}}) == 0 or absent(up{${sel}})";
      "for" = "10m";
      severity = "critical";
      summary = "Tempo is down.";
      description = "Prometheus has scraped no running ${instance} for 10 minutes, so it accepts no spans and answers no queries. Check statefulset/${name} and its pod's events.";
    };
    TempoBlockFlushFailing = {
      expr = "(sum ${by} (increase(tempo_live_store_failed_completions_total{${sel}}[10m])) > 0) or (sum ${by} (increase(tempo_live_store_local_failed_flushes_total{${sel}}[10m])) > 0)";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo fails to write completed trace blocks.";
      description = "${instance} has failed for 15 minutes to complete write-ahead log blocks or write them to its block store. The blocks stay in the write-ahead log, which grows on the same volume. Check the volume's free space and the pod's log.";
    };
    TempoDiscardingSpans = {
      expr = ''sum by (namespace, service, reason) (rate(tempo_discarded_spans_total{${sel},reason=~"rate_limited|live_traces_exceeded|trace_too_large"}[5m])) > 0'';
      "for" = "15m";
      severity = "warning";
      summary = "Tempo drops spans at a configured limit.";
      description = "${instance} has dropped spans for 15 minutes with reason {{ $labels.reason }}, {{ $value | humanize }} spans per second. Raise the matching limit under settings.overrides.defaults, or reduce what the senders ship.";
    };
    TempoBackendJobsFailing = {
      expr = failingLately "namespace, service, job_type" "tempo_backend_scheduler_jobs_failed_total";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo's backend jobs keep failing.";
      description = "${instance}'s {{ $labels.job_type }} jobs have failed more than twice in the last hour and are still failing. Failed compaction slows queries; failed retention lets the volume fill. Check the pod's log for the backend worker's errors.";
      runbook_url = "${runbook}#tempobackendschedulerjobsfailureratehigh";
    };
    TempoRetentionFailing = {
      expr = failingLately "namespace, service" "tempodb_retention_errors_total";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo fails to delete expired blocks.";
      description = "${instance} has failed to mark or delete blocks older than its retention more than twice in the last hour, so its volume keeps growing. Check the pod's log for retention errors.";
    };
    TempoPollsFailing = {
      expr = failingLately "namespace, service" "tempodb_blocklist_poll_errors_total";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo fails to list its blocks.";
      description = "${instance} has failed to poll its block list more than twice in the last hour and is still failing, so new blocks are not queryable and compaction works from a stale list. Check the volume and the pod's log.";
      runbook_url = "${runbook}#tempopollsfailing";
    };
    TempoCompactionBacklog = {
      expr = "sum ${by} (tempodb_compaction_outstanding_blocks{${sel}}) > 100";
      "for" = "6h";
      severity = "warning";
      summary = "Tempo's compaction is falling behind.";
      description = "${instance} has had {{ $value }} blocks waiting for compaction for 6 hours. Queries read more blocks and slow down. Raise resources.limits.cpu, or check TempoBackendJobsFailing.";
      runbook_url = "${runbook}#tempocompactiontoomanyoutstandingblocks";
    };
    TempoRequestErrors = {
      expr = "${failed} / ${total} > ${toString config.metrics.requestErrorRatio} and ${total} > ${toString config.metrics.requestErrorMinRate}";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo answers many requests with a server error.";
      description = "{{ $value | humanizePercentage }} of ${instance}'s requests on route {{ $labels.route }} have failed with a 5xx status for 15 minutes. Check the pod's log for the route's errors.";
    };
  }
  // lib.optionalAttrs (config.objectStorage == null && claimBytes != null && claimBytes > 0) {
    TempoBlocksNearClaimSize = {
      expr = "sum ${by} (tempodb_backend_bytes_total{${sel}}) / ${toString claimBytes} > 0.8";
      "for" = "30m";
      severity = "warning";
      summary = "Tempo's blocks nearly fill its volume.";
      description = "${instance}'s trace blocks take {{ $value | humanizePercentage }} of its ${toString claimSize} claim. When the volume fills, Tempo can no longer write blocks. Shorten retention or grow the claim.";
    };
  }
  // lib.optionalAttrs (memoryBytes != null && memoryBytes > 0) {
    TempoMemoryNearLimit = {
      expr = "max ${by} (process_resident_memory_bytes{${sel}}) / ${toString memoryBytes} > 0.9";
      "for" = "15m";
      severity = "warning";
      summary = "Tempo is near its memory limit.";
      description = "${instance} uses {{ $value | humanizePercentage }} of its ${toString memoryLimit} memory limit. An OOM kill replays the live store's write-ahead log on restart. Raise resources.limits.memory, or lower live_store.max_live_traces_bytes in settings.";
    };
  };
} args
