# Velero locations, schedules, root outputs, and Prometheus monitoring.

{
  self,
  config,
  scope,
  lib,
  kix,
  cloudCredentials,
  objectStorage ? null,
  prometheus ? null,
  ...
}@args:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    metricsPort
    componentLabels
    checkCloudCredentials
    ;

  creds = checkCloudCredentials cloudCredentials;
  bsl = config.backupStorageLocation;
  metricsOn = config.metrics.enabled && prometheus != null;

  # A key pair in the pods' environment needs no `credential` on the
  # locations: the AWS plugin and kopia fall back to the environment.
  credentialSpec = lib.optionalAttrs (creds.envKeys == null) {
    credential = {
      name = creds.dep.out.name;
      key = "cloud";
    };
  };

  # The dependency's URL is what forms the location's network policy
  # to the store, so a user `s3Url` may not replace it.
  locationConfig =
    if objectStorage == null then
      bsl.config
    else if bsl.config ? s3Url then
      scope.fail {
        package = "velero";
        option = "backupStorageLocation.config.s3Url";
        message = "backupStorageLocation.config.s3Url is set to \"${bsl.config.s3Url}\", and the objectStorage dependency supplies the store's URL. Velero would dial the address in s3Url, and no network policy would open it.";
        fix = "Remove s3Url to use the dependency's Service, or stop wiring an objectStorage dependency to use a store outside the cluster.";
      }
    else
      {
        s3Url =
          (objectStorage.out.url or (scope.fail {
            package = "velero";
            message = "deps.objectStorage has no out.url.";
            fix = "Wire an instance whose root is its S3 Service.";
          })
          )
            { };
        s3ForcePathStyle = "true";
      }
      // bsl.config;

  server = ''namespace="${ns}",service="${name}"'';
  ageOf =
    scheduleName: schedule:
    let
      derived = kix.schedules.staleAfter schedule.schedule;
    in
    if config.metrics.maxBackupAge ? ${scheduleName} then
      config.metrics.maxBackupAge.${scheduleName}
    else if derived != null then
      derived
    else
      scope.fail {
        package = "velero";
        option = "metrics.maxBackupAge.${scheduleName}";
        message = "schedules.${scheduleName}.schedule \"${schedule.schedule}\" does not show how often it runs, so VeleroBackupMissing has no threshold for it.";
        fix = "Set metrics.maxBackupAge.${scheduleName} to twice the longest gap between two runs plus the time a backup takes, such as \"64d\" for a monthly schedule.";
      };
  ages = lib.mapAttrs ageOf config.schedules;
  # The counter form reads a sample `age` ago, so the age must fit
  # inside the prometheus package's default retention of 7d.
  counterFormLimit = kix.durations.toSeconds "6d";
  # Velero creates a schedule's counters at 0 when it reconciles the
  # schedule, so they exist before the first run. The counter form
  # reports a schedule the server knew `age` ago and still knows,
  # with no success counted in between. The timestamp form returns
  # nothing while velero_backup_last_successful_timestamp is absent,
  # and Velero sets that gauge only when a backup succeeds, so after
  # a server restart the alert for such a schedule is silent until
  # its next success.
  missingFor =
    sel: age:
    let
      seconds = kix.durations.toSeconds age;
    in
    if seconds <= counterFormLimit then
      "((sum by (namespace, schedule) (velero_backup_attempt_total{${sel}} offset ${age}) and on (namespace, schedule) sum by (namespace, schedule) (velero_backup_attempt_total{${sel}})) unless on (namespace, schedule) (sum by (namespace, schedule) (increase(velero_backup_success_total{${sel}}[${age}])) > 0))"
    else
      "(time() - max by (namespace, schedule) (velero_backup_last_successful_timestamp{${sel}}) > ${toString seconds})";
  missing = scheduleName: missingFor ''${server},schedule="${scheduleName}"'';
  # Schedules built through out.mkSchedule, whose cron lines this
  # package never sees.
  otherSel =
    ''${server},schedule!=""''
    +
      lib.optionalString (config.schedules != { })
        '',schedule!~"${
          lib.concatMapStringsSep "|" lib.escapeRegex (builtins.attrNames config.schedules)
        }"'';
  otherAge = config.metrics.otherSchedulesMaxAge;
in
{
  service =
    if !metricsOn then
      null
    else
      lib.pipe self.deployment [
        (kix.service.fromWorkload {
          inherit name;
          labels = componentLabels "server";
          ports = [
            {
              name = "http-monitoring";
              port = metricsPort;
              targetPort = "http-monitoring";
            }
          ];
        })
        scope.mkResource
      ];

  nodeAgentService =
    if !(metricsOn && config.nodeAgent.enabled) then
      null
    else
      lib.pipe self.nodeAgent [
        (kix.service.fromWorkload {
          name = "${name}-node-agent";
          labels = componentLabels "node-agent";
          ports = [
            {
              name = "http-monitoring";
              port = metricsPort;
              targetPort = "http-monitoring";
            }
          ];
        })
        scope.mkResource
      ];

  backupStorageLocation = self.crds.backupStorageLocations.out.mkCR scope {
    name = "default";
    spec =
      removeAttrs bsl [
        "objectStorage"
        "config"
      ]
      // {
        objectStorage = lib.filterAttrs (k: v: !(k == "prefix" && v == null)) bsl.objectStorage;
        config = locationConfig;
        default = true;
      }
      // credentialSpec;
    requires = [ self.deployment ];
  };

  volumeSnapshotLocation =
    if config.volumeSnapshotLocation == null then
      null
    else
      self.crds.volumeSnapshotLocations.out.mkCR scope {
        name = "default";
        spec = config.volumeSnapshotLocation // credentialSpec;
        requires = [ self.deployment ];
      };

  schedules = lib.mapAttrs (
    scheduleName: schedule:
    self.crds.schedules.out.mkCR scope {
      name = scheduleName;
      spec = schedule // {
        template = schedule.template // {
          storageLocation =
            if schedule.template.storageLocation == null then
              self.backupStorageLocation.out.name
            else
              schedule.template.storageLocation;
        };
      };
      # A schedule on the default location already depends on it
      # through storageLocation; one on another location waits for the
      # default, so the server is running when it is applied.
      requires = lib.optional (schedule.template.storageLocation != null) self.backupStorageLocation;
    }
  ) config.schedules;

  root = {
    resource = self.deployment;
    # Dependents wait for an Available location, and for the data-path
    # policy before anything they build starts a backup. Listing the
    # monitoring parts keeps them referenced from root.
    requires = [
      self.backupStorageLocation
    ]
    ++ builtins.filter (part: part != null) [
      self.dataPathEgress
      self.service
      self.nodeAgentService
    ];
    out =
      let
        # Velero watches only its own namespace, so the CR is built
        # there and waits for an Available location.
        inVeleroNamespace =
          part: consumerScope: crArgs:
          self.crds.${part}.out.mkCR (consumerScope.forNamespace ns) (
            crArgs // { requires = (crArgs.requires or [ ]) ++ [ self.backupStorageLocation ]; }
          );
      in
      {
        version = kix.image.version config.image;
        crds = {
          Backup = self.crds.backups;
          BackupRepository = self.crds.backupRepositories;
          BackupStorageLocation = self.crds.backupStorageLocations;
          DataDownload = self.crds.dataDownloads;
          DataUpload = self.crds.dataUploads;
          DeleteBackupRequest = self.crds.deleteBackupRequests;
          DownloadRequest = self.crds.downloadRequests;
          PodVolumeBackup = self.crds.podVolumeBackups;
          PodVolumeRestore = self.crds.podVolumeRestores;
          Restore = self.crds.restores;
          Schedule = self.crds.schedules;
          ServerStatusRequest = self.crds.serverStatusRequests;
          VolumeSnapshotLocation = self.crds.volumeSnapshotLocations;
        };
        mkBackup = inVeleroNamespace "backups";
        mkSchedule = inVeleroNamespace "schedules";
      };
  };
}
// (kix.monitor {
  service = "service";
  port = "http-monitoring";
  alerts = {
    VeleroBackupFailed = {
      expr = "sum by (namespace, schedule) (increase(velero_backup_failure_total{${server}}[1h]) + increase(velero_backup_partial_failure_total{${server}}[1h])) > 0";
      severity = "warning";
      summary = "A Velero backup failed or partly failed in the last hour";
      description = "Velero in ${ns} recorded a failed or partially failed backup for schedule {{ $labels.schedule }}. Run velero backup describe on its latest backup.";
    };
    VeleroBackupMissing = {
      expr = lib.concatStringsSep " or " (
        lib.mapAttrsToList missing ages ++ [ (missingFor otherSel otherAge) ]
      );
      "for" = "15m";
      severity = "warning";
      summary = "A Velero schedule has no successful backup within its metrics.maxBackupAge";
      description = "Schedule {{ $labels.schedule }} of Velero in ${ns} has not completed a backup within its threshold (${
        lib.concatStringsSep ", " (
          lib.mapAttrsToList (n: a: "${n} ${a}") ages ++ [ "other schedules ${otherAge}" ]
        )
      }). Check the backup location with velero backup-location get and the schedule's latest backups.";
    };
    VeleroServerDown = {
      expr = "sum by (namespace, service) (up{${server}}) == 0 or absent(up{${server}})";
      "for" = "15m";
      severity = "warning";
      summary = "The Velero server is not being scraped";
      description = "Prometheus has scraped no running Velero server in ${ns} for 15 minutes, so no backup runs. Check deployment/velero.";
    };
  };
} args)
// lib.optionalAttrs config.nodeAgent.enabled (
  kix.monitor {
    name = "${name}-node-agent";
    service = "nodeAgentService";
    port = "http-monitoring";
    monitorPart = "nodeAgentMonitor";
    rulesPart = "nodeAgentRules";
  } args
)
