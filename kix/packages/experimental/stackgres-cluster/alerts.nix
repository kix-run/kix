# PrometheusRule alerts for the stackgres-cluster package.
{ exporterOnFor }:
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
  patronictl = "kubectl exec -n ${ns} <pod> -c patroni -- patronictl list";
  standbys = config.instances - 1;
  lag = config.metrics.maxReplicationLag;
  slotBytes = kix.parseQuantity "memory" config.persistentVolume.size / 4;
  xidAge =
    threshold: "max by (namespace, job, datname) (pg_database_datfrozenxid_age{${sel}}) > ${threshold}";
in
kix.alerts {
  alerts = lib.optionalAttrs (exporterOnFor config) (
    {
      StackGresClusterDown = {
        expr = "sum by (namespace, job) (pg_up{${sel}}) == 0 or absent(pg_up{${sel}})";
        "for" = "10m";
        severity = "critical";
        summary = "A StackGres cluster has no running PostgreSQL instance.";
        description = "No exporter of ${cluster} has reached PostgreSQL for 10 minutes, so clients cannot connect. Check kubectl describe sgcluster ${name} -n ${ns} and the patroni container's log in the instance pods.";
      };
      StackGresConnectionsHigh = {
        expr = ''sum by (namespace, job, pod) (pg_stat_activity_count{${sel},backend_type="client backend"}) / max by (namespace, job, pod) (pg_settings_max_connections{${sel}}) > 0.9'';
        "for" = "15m";
        severity = "warning";
        summary = "A StackGres instance is close to max_connections.";
        description = "Instance {{ $labels.pod }} of ${cluster} uses {{ $value | humanizePercentage }} of max_connections, and new connections fail when none is left. Look for clients that hold idle connections, or set `pooling` to run PgBouncer.";
      };
      StackGresTransactionIDAgeHigh = {
        expr = xidAge "1e9";
        "for" = "15m";
        severity = "warning";
        summary = "A StackGres database is not being frozen by autovacuum.";
        description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID age of {{ $value | humanize }}. Autovacuum is not freezing it; look for long transactions, prepared transactions, or replication slots that hold back the oldest XID.";
      };
      StackGresTransactionIDWraparoundImminent = {
        expr = xidAge "1.6e9";
        "for" = "5m";
        severity = "critical";
        summary = "A StackGres database is close to transaction ID wraparound.";
        description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID age of {{ $value | humanize }}. PostgreSQL refuses writes at about 2.1 billion. Run VACUUM (FREEZE) on the database's oldest tables now and end the transactions that hold back the oldest XID.";
      };
      StackGresReplicationSlotInactive = {
        expr = "max by (namespace, job, pod, slot_name) (pg_replication_slots_pg_wal_lsn_diff{${sel}} and on (namespace, job, pod, slot_name) pg_replication_slots_active{${sel}} == 0 and on (namespace, job, pod) pg_replication_is_replica{${sel}} == 0) > ${toString slotBytes}";
        "for" = "30m";
        severity = "warning";
        summary = "An inactive replication slot holds back WAL on a StackGres primary.";
        description = "Replication slot {{ $labels.slot_name }} on primary {{ $labels.pod }} of ${cluster} is inactive and retains {{ $value | humanize }}B of WAL, over a quarter of the ${toString config.persistentVolume.size} volume. PostgreSQL keeps that WAL until the slot's consumer reconnects or the slot is dropped.";
      };
      StackGresExporterErrors = {
        expr = "max by (namespace, job, pod) (pg_exporter_last_scrape_error{${sel}}) == 1";
        "for" = "15m";
        severity = "warning";
        summary = "A StackGres exporter fails its queries.";
        description = "The exporter in {{ $labels.pod }} of ${cluster} fails a query, so the series it produces are missing and the alerts that read them cannot fire. The prometheus-postgres-exporter container's log names the failing query.";
      };
    }
    // lib.optionalAttrs (!(config.extraSpec ? replicateFrom)) {
      StackGresClusterNoPrimary = {
        expr = "sum by (namespace, job) (1 - pg_replication_is_replica{${sel}}) == 0";
        "for" = "5m";
        severity = "critical";
        summary = "A StackGres cluster has no primary.";
        description = "Every running instance of ${cluster} is a replica, so none accepts writes. Check ${patronictl} and the patroni container's log for a failover that did not finish.";
      };
    }
    // lib.optionalAttrs (config.instances > 1) {
      StackGresClusterMultiplePrimaries = {
        expr = "sum by (namespace, job) (1 - pg_replication_is_replica{${sel}}) > 1";
        "for" = "5m";
        severity = "critical";
        summary = "A StackGres cluster has more than one primary.";
        description = "{{ $value }} instances of ${cluster} are out of recovery, so more than one may accept writes. Check ${patronictl}.";
      };
      StackGresStandbysNotStreaming = {
        expr = ''(count by (namespace, job) (pg_stat_replication_pg_wal_lsn_diff{${sel},state="streaming"}) or sum by (namespace, job) (pg_replication_is_replica{${sel}}) * 0) < ${toString standbys}'';
        "for" = "10m";
        severity = "warning";
        summary = "A StackGres standby is not streaming from the primary.";
        description = "The primary of ${cluster} streams WAL to {{ $value }} of ${toString standbys} standbys. A standby that does not stream falls behind, and a failover to it loses data. Check ${patronictl} and the standby pods' logs.";
      };
      StackGresReplicationLagHigh = {
        expr = "max by (namespace, job, pod) (pg_replication_lag_seconds{${sel}}) > ${toString (kix.durations.toSeconds lag)}";
        "for" = "15m";
        severity = "warning";
        summary = "A StackGres standby is far behind the primary.";
        description = "Standby {{ $labels.pod }} of ${cluster} replays WAL {{ $value | humanizeDuration }} behind the primary, over metrics.maxReplicationLag (${lag}). Check the standby's disk and CPU, and the network to the primary.";
      };
    }
    // lib.optionalAttrs (config.backups != null) {
      StackGresWALArchivingFailing = {
        expr = "sum by (namespace, job, pod) (increase(pg_stat_archiver_failed_count{${sel}}[15m])) > 0 unless on (namespace, job, pod) sum by (namespace, job, pod) (increase(pg_stat_archiver_archived_count{${sel}}[15m])) > 0";
        "for" = "15m";
        severity = "warning";
        summary = "A StackGres instance fails to archive WAL.";
        description = "{{ $labels.pod }} of ${cluster} failed to archive WAL in the last 15 minutes and archived none. Unarchived WAL stays on the volume until it fills, and point-in-time recovery stops at the last archived segment. Check that the SGObjectStorage's bucket exists and its credentials are valid, and look for archive_command errors in PostgreSQL's log.";
      };
    }
  );
} args
