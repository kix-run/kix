# PrometheusRule alerts for the cnpg-cluster package.
{
  config,
  scope,
  lib,
  kix,
  prometheus ? null,
  ...
}@args:
let
  name = scope.instanceName;
  ns = scope.namespaceName;
  sel = ''namespace="${ns}",job="${ns}/${name}"'';
  cluster = "PostgreSQL cluster ${ns}/${name}";
  status = "kubectl cnpg status ${name} -n ${ns}";
  standbys = config.instances - 1;
  lag = config.metrics.maxReplicationLag;
  walSize = config.extraSpec.walStorage.size or null;
  walVolume =
    if walSize != null then
      {
        size = walSize;
        what = "WAL volume";
      }
    else
      {
        size = config.storage.size;
        what = "data volume";
      };
  slotBytes = kix.parseQuantity "memory" walVolume.size / 4;
  backupAge =
    if config.metrics.maxBackupAge != null then
      config.metrics.maxBackupAge
    else
      let
        derived = kix.schedules.staleAfter config.backup.schedule;
      in
      if derived != null then
        derived
      else
        scope.fail {
          package = "cnpg-cluster";
          option = "metrics.maxBackupAge";
          message = "backup.schedule \"${config.backup.schedule}\" does not show how often base backups run, so CNPGBackupMissing has no threshold.";
          fix = "Set metrics.maxBackupAge to twice the longest gap between two runs plus the time a backup takes, such as \"15d\" for a weekly schedule.";
        };
  firstBackupWindow =
    if kix.durations.toSeconds backupAge < kix.durations.toSeconds "24h" then backupAge else "24h";
  backupTs = "barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{${sel}}";
  failedTs = "barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp{${sel}}";
  runbook =
    alert:
    "https://github.com/cloudnative-pg/charts/blob/main/charts/cluster/docs/runbooks/${alert}.md";
  xidAge =
    threshold:
    "max by (namespace, job, datname) (cnpg_pg_database_xid_age{${sel}}) > ${threshold} or max by (namespace, job, datname) (cnpg_pg_database_mxid_age{${sel}}) > ${threshold}";
in
kix.alerts {
  alerts = {
    CNPGClusterDown = {
      expr = "sum by (namespace, job) (cnpg_collector_up{${sel}}) == 0 or absent(cnpg_collector_up{${sel}})";
      "for" = "10m";
      severity = "critical";
      summary = "A CloudNativePG cluster has no running PostgreSQL instance.";
      description = "No instance of ${cluster} has reported PostgreSQL up for 10 minutes, so clients cannot connect. Check ${status} and the instance pods' logs.";
      runbook_url = runbook "CNPGClusterOffline";
    };
    CNPGClusterNoPrimary = {
      expr = "sum by (namespace, job) (1 - cnpg_pg_replication_in_recovery{${sel}}) == 0 unless on (namespace, job) max by (namespace, job) (cnpg_collector_replica_mode{${sel}}) == 1";
      "for" = "5m";
      severity = "critical";
      summary = "A CloudNativePG cluster has no primary.";
      description = "Every running instance of ${cluster} is in recovery, so none accepts writes. Check ${status} and the operator's log for a failover that did not finish.";
    };
    CNPGConnectionsHigh = {
      expr = ''sum by (namespace, job, pod) (cnpg_backends_total{${sel}}) / max by (namespace, job, pod) (cnpg_pg_settings_setting{${sel},name="max_connections"}) > 0.9'';
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG instance is close to max_connections.";
      description = "Instance {{ $labels.pod }} of ${cluster} uses {{ $value | humanizePercentage }} of max_connections, and new connections fail when none is left. Look for clients that hold idle connections, or put a cnpg-pooler in front of the cluster.";
      runbook_url = runbook "CNPGClusterHighConnectionsWarning";
    };
    CNPGTransactionIDAgeHigh = {
      expr = xidAge "1e9";
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG database is not being frozen by autovacuum.";
      description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID or multixact age of {{ $value | humanize }}. Autovacuum is not freezing it; look for long transactions, prepared transactions, or replication slots that hold back the oldest XID.";
    };
    CNPGTransactionIDWraparoundImminent = {
      expr = xidAge "1.6e9";
      "for" = "5m";
      severity = "critical";
      summary = "A CloudNativePG database is close to transaction ID wraparound.";
      description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID or multixact age of {{ $value | humanize }}. PostgreSQL refuses writes at about 2.1 billion. Run VACUUM (FREEZE) on the database's oldest tables now and end the transactions that hold back the oldest XID.";
    };
    CNPGReplicationSlotInactive = {
      expr = "max by (namespace, job, pod, slot_name) (cnpg_pg_replication_slots_pg_wal_lsn_diff{${sel}} and on (namespace, job, pod, slot_name) cnpg_pg_replication_slots_active{${sel}} == 0 and on (namespace, job, pod) cnpg_pg_replication_in_recovery{${sel}} == 0) > ${toString slotBytes}";
      "for" = "30m";
      severity = "warning";
      summary = "An inactive replication slot holds back WAL on a CloudNativePG primary.";
      description = "Replication slot {{ $labels.slot_name }} on primary {{ $labels.pod }} of ${cluster} is inactive and retains {{ $value | humanize }}B of WAL, over a quarter of the ${toString walVolume.size} ${walVolume.what}. PostgreSQL keeps that WAL until the slot's consumer reconnects or the slot is dropped.";
    };
    CNPGMetricsCollectionFailing = {
      expr = "max by (namespace, job, pod) (cnpg_collector_last_collection_error{${sel}}) == 1";
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG instance fails to collect its metrics.";
      description = "The instance manager in {{ $labels.pod }} of ${cluster} fails a monitoring query, so the series it produces are missing and the alerts that read them cannot fire. Its log names the failing query.";
    };
  }
  // lib.optionalAttrs (config.instances > 1) {
    CNPGClusterMultiplePrimaries = {
      expr = "sum by (namespace, job) (1 - cnpg_pg_replication_in_recovery{${sel}}) > 1";
      "for" = "5m";
      severity = "critical";
      summary = "A CloudNativePG cluster has more than one primary.";
      description = "{{ $value }} instances of ${cluster} are out of recovery, so more than one may accept writes. Check ${status} and fence the instance that is not the cluster's current primary.";
    };
    CNPGStandbysNotStreaming = {
      expr = "sum by (namespace, job) (cnpg_pg_replication_is_wal_receiver_up{${sel}}) < ${toString standbys}";
      "for" = "10m";
      severity = "warning";
      summary = "A CloudNativePG standby is not streaming from the primary.";
      description = "{{ $value }} of the ${toString standbys} standbys of ${cluster} receive WAL. A standby that does not stream falls behind, and a failover to it loses data. Check ${status} and the standby pods' logs.";
      runbook_url = runbook "CNPGClusterHAWarning";
    };
    CNPGReplicationLagHigh = {
      expr = "max by (namespace, job, pod) (cnpg_pg_replication_lag{${sel}}) > ${toString (kix.durations.toSeconds lag)}";
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG standby is far behind the primary.";
      description = "Standby {{ $labels.pod }} of ${cluster} replays WAL {{ $value | humanizeDuration }} behind the primary, over metrics.maxReplicationLag (${lag}). Check the standby's disk and CPU, and the network to the primary.";
      runbook_url = runbook "CNPGClusterPhysicalReplicationLag";
    };
  }
  // lib.optionalAttrs (config.backup != null) {
    CNPGWALArchivingFailing = {
      expr = "max by (namespace, job, pod) (cnpg_pg_stat_archiver_last_failed_time{${sel}}) > max by (namespace, job, pod) (cnpg_pg_stat_archiver_last_archived_time{${sel}})";
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG instance fails to archive WAL.";
      description = "The last WAL archive attempt of {{ $labels.pod }} in ${cluster} failed and none has succeeded since. Unarchived WAL stays on the volume until it fills, and point-in-time recovery stops at the last archived segment. Check the plugin-barman-cloud container's log in that pod and the ObjectStore ${name}-backup.";
    };
    CNPGBackupMissing = {
      expr = "time() - max by (namespace, job) (${backupTs} > 0) > ${toString (kix.durations.toSeconds backupAge)}";
      "for" = "5m";
      severity = "warning";
      summary = "A CloudNativePG cluster has no recent base backup.";
      description = "The last completed base backup of ${cluster} is {{ $value | humanizeDuration }} old, over ${backupAge} (metrics.maxBackupAge). Check kubectl get backups -n ${ns} and the plugin-barman-cloud container's log.";
    };
    CNPGBackupNeverCompleted = {
      expr = "max by (namespace, job) (${backupTs}) == 0 and on (namespace, job) count by (namespace, job) (${backupTs} offset ${firstBackupWindow})";
      "for" = "5m";
      severity = "warning";
      summary = "A CloudNativePG cluster has never completed a base backup.";
      description = "${cluster} has reported backup metrics for ${firstBackupWindow} and has no completed base backup. Check kubectl get backups -n ${ns} and the plugin-barman-cloud container's log.";
    };
    CNPGBackupFailed = {
      expr = "max by (namespace, job) (${failedTs}) > max by (namespace, job) (${backupTs})";
      "for" = "5m";
      severity = "warning";
      summary = "The latest base backup of a CloudNativePG cluster failed.";
      description = "The latest base backup of ${cluster} failed, and none has completed since. The alert clears when a backup completes. kubectl get backups -n ${ns} shows the failed Backup's error.";
    };
    CNPGBackupMetricsMissing = {
      expr = "count by (namespace, job) (up{${sel}} == 1) unless on (namespace, job) count by (namespace, job) (${backupTs})";
      "for" = "15m";
      severity = "warning";
      summary = "A CloudNativePG cluster reports no backup metrics.";
      description = "The instances of ${cluster} are scraped but report no Barman Cloud backup metrics, so the backup alerts cannot fire. Check that each instance pod runs the plugin-barman-cloud container and that its log shows no error reading the ObjectStore ${name}-backup.";
    };
  };
} args
