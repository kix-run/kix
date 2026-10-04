# cnpg-cluster: a PostgreSQL cluster run by the CloudNativePG operator, as
# one postgresql.cnpg.io Cluster.
#
# The operator creates the instance pods and their claims, the -rw, -ro,
# and -r Services, and the Secrets of the `app` role and database that
# initdb creates. The package references the -rw Service, which selects the
# primary, so consumers wait for the Cluster and get network policy to the
# PostgreSQL pods. Apps should depend on a cnpg-database instance (alias
# `database`), which creates a role and database for them, rather than on
# this package.
#
# Minimal instance, with an operator elsewhere in the cluster:
#
#   instances.data.postgres.package = packages.cnpg-cluster;
#
# DI deps:
#   cnpgOperator (required)    a cnpg-operator instance; the package reads
#                              its CRD handle, release, and pod labels. An
#                              imported operator is refused.
#   storageClasses (optional)  the class of the data volumes when
#                              `storage.storageClass` is null.
#   prometheus (optional)      a PodMonitor for the instance manager's
#                              metrics (TCP 9187) while `metrics.enabled`.
#   barmanCloud                a cnpg-barman-cloud instance. Required
#                              while `backup` is set, and read only then.
#   storageCredentials         a secret or secret-ref in this namespace
#                              with the S3 access key ID and secret key
#                              (keys `accessKeyId` and `secretAccessKey`,
#                              or those `backup.credentialKeys` names), as
#                              stackgres-object-storage reads them.
#                              Required while `backup` is set.
#   endpointService (optional) an S3 store in the cluster, as an instance
#                              whose root is its S3 Service. Read only
#                              while `backup` is set: the package sets the
#                              ObjectStore's endpointURL to the Service's
#                              URL (scheme from `backup.endpointScheme`),
#                              and the instance pods get network policy
#                              to the store. No package has the
#                              alias, so wire it with
#                              deps.endpointService = ref.<ns>.<instance>.
#
# Defaults: `instances` from the availability level (1 at none, 2 at pod
# and node, 3 at zone), PostgreSQL 18 from the operand image, 1 CPU and 2Gi
# per instance as requests and limits, 20Gi volumes. PostgreSQL serves TLS
# with a certificate the operator issues.
#
# Placement: with more than one instance, the pods spread over nodes and
# zones as the availability level asks. CloudNativePG's own pod
# anti-affinity is off (`affinity.enablePodAntiAffinity = false`), so the
# spread is the only placement rule. The operator's PodDisruptionBudgets
# are on only with more than one instance: with one, the primary's budget
# would block every node drain.
#
# Network policy: with an enforcer, the package opens the pods' DNS, API
# server, and peer traffic, and the operator's access to the status port
# (TCP 8000) and PostgreSQL (TCP 5432), as upstream's
# docs/src/samples/networkpolicy-example.yaml does. Clients get ingress
# through the -rw Service reference.
#
# Backups: with `backup` set, the package builds an ObjectStore named
# `<instance>-backup` through the barmanCloud dependency, enables the
# plugin on the Cluster as its WAL archiver (`spec.plugins`), and adds a
# ScheduledBackup named after the instance that takes a base backup at
# `backup.schedule` and once right after it is created. The plugin's
# sidecar in each instance pod writes under `backup.destinationPath`, in a
# folder named by `backup.serverName` (`<namespace>-<instance>` by default),
# and deletes what falls outside `backup.retention`. Without
# endpointService, the instance pods may open connections outside the
# cluster on the port of `backup.extraSpec.configuration.endpointURL` (from
# its scheme when it names none), or on 443 when it is unset, as for AWS
# S3; an endpointURL that names a Service in the cluster is refused.
#
#   backup = {
#     destinationPath = "s3://pg-backups/main";
#     retention = "30d";
#   };
#
# Pooling: a cnpg-pooler instance runs PgBouncer in front of the -rw
# Service, and a cnpg-database that takes it as its postgres dependency
# hands consumers the pooler's address.
#
# Escape hatches: `extraSpec`, merged over the Cluster spec, and
# `backup.extraSpec`, merged over the ObjectStore spec. The fields the
# options own are refused (listed on each), and so is
# `monitoring.enablePodMonitor`, which has the operator create a PodMonitor
# outside Kix.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the PodMonitor's series by
# `job="<namespace>/<instance>"`.
#   CNPGClusterDown (critical)             no instance reports PostgreSQL up.
#   CNPGClusterNoPrimary (critical)        every instance is in recovery,
#                                          outside replica mode.
#   CNPGClusterMultiplePrimaries (critical, instances > 1)
#                                          more than one instance accepts
#                                          writes.
#   CNPGStandbysNotStreaming (warning, instances > 1)
#                                          fewer WAL receivers than
#                                          `instances` - 1.
#   CNPGReplicationLagHigh (warning, instances > 1)
#                                          replay lag over
#                                          `metrics.maxReplicationLag`.
#   CNPGConnectionsHigh (warning)          backends over 90% of
#                                          max_connections.
#   CNPGTransactionIDAgeHigh (warning)     XID or multixact age over 1e9.
#   CNPGTransactionIDWraparoundImminent (critical)
#                                          the same over 1.6e9.
#   CNPGReplicationSlotInactive (warning)  an inactive slot on the primary
#                                          holds WAL over a quarter of
#                                          the WAL volume
#                                          (`extraSpec.walStorage.size`,
#                                          else `storage.size`).
#   CNPGMetricsCollectionFailing (warning) a monitoring query fails, so the
#                                          series the alerts read go missing.
# With `backup` set, from the Barman Cloud plugin's metrics, which its
# sidecar publishes through the instance's own metrics port:
#   CNPGWALArchivingFailing (warning)      the last WAL archive attempt
#                                          failed.
#   CNPGBackupMissing (warning)            the last completed base backup
#                                          is older than
#                                          `metrics.maxBackupAge`.
#   CNPGBackupNeverCompleted (warning)     no base backup has completed
#                                          within a day of the metrics
#                                          appearing (or within
#                                          `metrics.maxBackupAge`, when
#                                          shorter).
#   CNPGBackupFailed (warning)             the latest base backup failed.
#   CNPGBackupMetricsMissing (warning)     the plugin metrics are missing.
# `metrics.maxBackupAge` defaults to two of the schedule's periods plus two
# hours (50h for the default daily schedule), and must be
# set for a schedule whose period the package cannot read: `@every` or a
# cron expression with a day-of-month, month, or day-of-week field.
# Left to prometheus-default-rules: full data and WAL volumes
# (KubePersistentVolumeFillingUp), crash loops (KubePodCrashLooping), pods
# that do not start (KubePodNotReady), and one instance of several not
# scraped (TargetDown). Long transactions, deadlocks, and dead tuples
# depend on the workload and are left to the site.
#
# Limits: `backup` writes S3 access keys only; IAM-role credentials
# (`s3Credentials.inheritFromIAMRole`), Azure, and Google Cloud Storage are
# not modelled. Recovery from a backup into a
# new Cluster is not modelled.
#
# Exposes:
#   out.name, out.fqdn, out.port  the -rw Service (port 5432).
#   out.clusterName               the Cluster's name, for the `cluster`
#                                 reference of a Database or DatabaseRole.
#   out.selector                  the instance pods' labels.
#   out.tls                       true: PostgreSQL always serves TLS.
#   out.extraImages               the operand image.
#
# root = the Cluster.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cnpg-cluster ${ns}/${name}";

  # The Cluster fields this package writes are those of CloudNativePG 1.30.
  supportedRelease = "1.30";

  postgresPort = 5432;
  # The instance manager's status endpoint, which the operator calls
  # (pkg/management/url/url.go upstream).
  statusPort = 8000;
  metricsPort = 9187;

  # Cluster spec paths the options own. `plugins` is added while `backup`
  # is set.
  locked = [
    [ "instances" ]
    [ "imageName" ]
    [ "resources" ]
    [
      "storage"
      "size"
    ]
    [
      "storage"
      "storageClass"
    ]
  ];

  # CloudNativePG parses a schedule with robfig/cron v1.2.0's Parse, which
  # takes six fields with seconds first and reads a five-field expression as
  # one with no day-of-week field (internal/webhook/v1/scheduledbackup_webhook.go
  # upstream). A schedule starting with `@` is one of the descriptors in
  # parseDescriptor (parser.go in robfig/cron), `@every` taking a Go duration.
  scheduleFields =
    schedule:
    builtins.length (
      builtins.filter builtins.isString (builtins.split "[[:space:]]+" (lib.trim schedule))
    );
  descriptorOk =
    schedule:
    builtins.match "@(yearly|annually|monthly|weekly|daily|midnight|hourly)" schedule != null
    || builtins.match "@every ([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+" schedule != null;
  scheduleOk =
    schedule:
    if lib.hasPrefix "@" schedule then descriptorOk schedule else scheduleFields schedule == 6;

  # The PodMonitor's name. Its series carry job="<namespace>/<name>", which
  # the alerts select on.
  podMonitorName = name;

  # A Prometheus duration such as "26h" or "1h30m", in seconds.
  durationType = lib.types.strMatching "([0-9]+[smhdw])+";
  durationUnits = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
    w = 604800;
  };
  durationSeconds =
    d:
    lib.foldl' (
      acc: p: acc + lib.toInt (builtins.elemAt p 0) * durationUnits.${builtins.elemAt p 1}
    ) 0 (builtins.filter builtins.isList (builtins.split "([0-9]+)([smhdw])" d));

  # Two of the longest gaps between base backups of a schedule, so one
  # missed run does not fire CNPGBackupMissing (CNPGBackupFailed reports
  # the failed run), plus two hours for a backup to finish. A
  # six-field schedule whose day-of-month, month, and day-of-week fields are
  # all `*` runs at least daily. Null when the period cannot be read.
  descriptorMaxAge = {
    "@hourly" = "4h";
    "@daily" = "50h";
    "@midnight" = "50h";
    "@weekly" = "338h";
    "@monthly" = "1490h";
    "@yearly" = "17570h";
    "@annually" = "17570h";
  };
  scheduleMaxAge =
    schedule:
    let
      fields = builtins.filter builtins.isString (builtins.split "[[:space:]]+" (lib.trim schedule));
    in
    if descriptorMaxAge ? ${schedule} then
      descriptorMaxAge.${schedule}
    else if
      builtins.length fields == 6
      &&
        lib.drop 3 fields == [
          "*"
          "*"
          "*"
        ]
    then
      "50h"
    else
      null;

  # The S3 credential selectors every ObjectStore names. Each reads the
  # Secret key of its own name unless backup.credentialKeys names another;
  # `region` is added only when backup.credentialKeys.region is set.
  credentialSelectors = [
    "accessKeyId"
    "secretAccessKey"
  ];

  # An http or https URL as [ scheme host _ port rest ], or null.
  matchUrl = builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?";

  # Whether a URL's host is a Service name: `<svc>.<ns>.svc`, with or
  # without the cluster domain and a trailing dot.
  urlHostInCluster =
    clusterDomain: url:
    let
      m = matchUrl url;
      host = lib.toLower (lib.removeSuffix "." (builtins.elemAt m 1));
    in
    m != null && (lib.hasSuffix ".svc" host || lib.hasSuffix ".svc.${lib.toLower clusterDomain}" host);

  # The port of an http or https URL: the explicit one, else the scheme's.
  urlPort =
    url:
    let
      m = matchUrl url;
    in
    if m == null then
      throw "${who}: backup.extraSpec.configuration.endpointURL \"${url}\" is not an http or https URL, so the package cannot tell which port the store listens on. Write it as https://<host>[:<port>]."
    else if builtins.elemAt m 3 != null then
      lib.toInt (builtins.elemAt m 3)
    else if builtins.elemAt m 0 == "https" then
      443
    else
      80;
in
{
  meta = {
    description = "PostgreSQL cluster run by the CloudNativePG operator (Cluster)";
    owner = "platform";
    defaultAliases = [ "postgres" ];
    lifecycle = "stateful";
  };

  assertions =
    { config, ... }:
    [
      {
        assertion =
          builtins.stringLength name <= 50 && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
        message = "CloudNativePG requires a Cluster name of at most 50 characters that is a DNS-1035 label (^[a-z]([-a-z0-9]*[a-z0-9])?$); \"${name}\" is ${toString (builtins.stringLength name)} characters. Rename the instance.";
      }
      {
        # The operator reads the PostgreSQL version from the tag
        # (validateImageName in internal/webhook/v1/cluster_webhook.go).
        assertion = builtins.match "[0-9]+(\\.[0-9]+)?([-_].*)?" config.image.tag != null;
        message = "image.tag \"${config.image.tag}\" does not start with a PostgreSQL version. CloudNativePG reads the version from the tag and refuses `latest`; use a tag such as \"18.6-standard-trixie\".";
      }
      {
        assertion =
          config.backup == null
          || !lib.hasPrefix "@" config.backup.schedule
          || scheduleOk config.backup.schedule;
        message = "backup.schedule \"${config.backup.schedule}\" is not a descriptor CloudNativePG accepts. Use @yearly, @annually, @monthly, @weekly, @daily, @midnight, @hourly, or @every followed by a duration such as 12h or 1h30m.";
      }
      {
        assertion =
          config.backup == null
          || lib.hasPrefix "@" config.backup.schedule
          || scheduleOk config.backup.schedule;
        message = "backup.schedule \"${config.backup.schedule}\" has ${toString (scheduleFields config.backup.schedule)} fields. CloudNativePG reads six cron fields with seconds first and reads a five-field crontab as one without a day-of-week field, so it would run at other times than a crontab does. Add the seconds field (\"0 0 2 * * *\" for 02:00 every day), or use a descriptor such as \"@daily\".";
      }
      {
        assertion = !((config.extraSpec.monitoring or { }) ? enablePodMonitor);
        message = "extraSpec sets monitoring.enablePodMonitor, which has the operator create a PodMonitor that Kix does not track. Set metrics.enabled and wire a prometheus dependency instead.";
      }
    ];

  # An imported operator has no out.release; the build refuses it first.
  deps.cnpgOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the Cluster fields of CloudNativePG ${supportedRelease}, and the cnpgOperator dependency runs ${dep.out.release}. Update kix/packages/cnpg-cluster for that release.";
    }
  ];

  options = {
    instances = lib.mkOption {
      type = lib.types.ints.positive;
      # One instance cannot survive its own pod's restart, so `pod` needs a
      # second; three at `zone` keep a quorum of replicas through a zone
      # loss.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }";
      description = "PostgreSQL instances (`spec.instances`): one primary, the rest streaming replicas the operator fails over to.";
    };

    image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/postgresql";
      tag = "18.6-standard-trixie";
      digest = "sha256:f89a40f4d74aa6e0900917eaf6299b125a6382eb02fd4ee5d46f55bcbf7e5726";
      description = "PostgreSQL operand image (`spec.imageName`). The tag must start with the PostgreSQL version, which the operator reads from it. The `standard` images carry the contrib extensions, pgvector, pgaudit, and pg_failover_slots. Changing the major runs the operator's offline major upgrade.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "1";
        memory = "2Gi";
      };
      limits = {
        cpu = "1";
        memory = "2Gi";
      };
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "20Gi";
        description = "Size of each instance's data volume (`spec.storage.size`).";
      };
      storageClass = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one.";
      };
    };

    metrics = kix.options.monitor // {
      maxReplicationLag = lib.mkOption {
        type = durationType;
        default = "5m";
        example = "30s";
        description = "How far a standby's replay may fall behind the primary before CNPGReplicationLagHigh fires, as a Prometheus duration. A standby that cannot keep up loses that much committed data if it is promoted. The default is the threshold of CloudNativePG's sample rules.";
      };
      maxBackupAge = lib.mkOption {
        type = lib.types.nullOr durationType;
        default = null;
        example = "15d";
        description = "How long the cluster may go without a completed base backup before CNPGBackupMissing fires, as a Prometheus duration. Null derives it from `backup.schedule`: two periods plus two hours for a descriptor (`@daily` gives 50h), and 50h for a six-field schedule that runs every day, so one missed run does not fire it. Set it for `@every` and for other cron schedules: while the alerts render, the build fails without it. CNPGBackupMissing compares it with the last backup's timestamp, so it may be longer than the Prometheus retention.";
      };
    };

    backup = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            destinationPath = lib.mkOption {
              type = lib.types.strMatching "s3://[^/]+(/.*)?";
              example = "s3://pg-backups/main";
              description = "Where WAL and base backups go, as `s3://<bucket>[/<prefix>]` (the ObjectStore's `configuration.destinationPath`). The bucket must exist. The plugin writes under a folder named `serverName`, so clusters with different server names may share a path.";
            };
            serverName = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][-A-Za-z0-9._]*");
              default = null;
              example = "pg";
              description = ''
                Folder under `destinationPath` that this Cluster archives to
                (the plugin's `serverName` parameter). Null uses
                `<namespace>-<instance>`, so same-named instances in two
                namespaces do not share an archive. A new Cluster refuses to
                archive into a folder that already holds WAL, so a Cluster
                re-created over an old archive needs another name. Set it to
                the Cluster's name to keep the archive of a Cluster that
                already archives under CloudNativePG's default.
              '';
            };
            schedule = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "0 0 0 * * *";
              description = "When to take a base backup (the ScheduledBackup's `spec.schedule`): six cron fields with seconds first, or one of the descriptors `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`, and `@every <duration>` (`@every 12h`). A five-field crontab is refused. The default is midnight every day.";
            };
            endpointScheme = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "http"
                  "https"
                ]
              );
              default = null;
              description = "Scheme of the endpointService dependency's URL in the ObjectStore's `configuration.endpointURL`. Null means `http`. Set only with an endpointService dependency; for a store that serves TLS with a private CA, also set `extraSpec.configuration.endpointCA`.";
            };
            retention = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[1-9][0-9]*[dwm]");
              default = null;
              example = "30d";
              description = "How far back the backups reach (the ObjectStore's `retentionPolicy`): a number followed by `d`, `w`, or `m`. The sidecar deletes the base backups and WAL that are no longer needed to recover to a point in that window. Null keeps everything.";
            };
            credentialKeys =
              lib.genAttrs credentialSelectors (
                s:
                lib.mkOption {
                  type = lib.types.nullOr lib.types.nonEmptyStr;
                  default = null;
                  description = "Key of the storageCredentials Secret holding `${s}`; null reads the key `${s}`.";
                }
              )
              // {
                region = lib.mkOption {
                  type = lib.types.nullOr lib.types.nonEmptyStr;
                  default = null;
                  description = "Key of the storageCredentials Secret holding the S3 region. Null sets no region.";
                };
              };
            extraSpec = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              example = {
                configuration = {
                  endpointURL = "https://s3.example.com";
                  wal.compression = "gzip";
                };
              };
              description = ''
                Merged over the ObjectStore spec: `configuration.endpointURL`
                for a store other than AWS S3, `configuration.endpointCA`,
                `configuration.wal`, `configuration.data`, and
                `instanceSidecarConfiguration`. Refused:
                `configuration.destinationPath`,
                `configuration.s3Credentials`, `retentionPolicy`, and, with
                an endpointService dependency, `configuration.endpointURL`.
                An `endpointURL` whose host is a Service name in the cluster
                (ending in `.svc` or `.svc.<cluster domain>`) is refused, so
                wire that store as endpointService. A Secret selector must
                name a secret dependency's Secret.
              '';
            };
          };
        }
      );
      default = null;
      description = ''
        WAL archiving and scheduled base backups to S3 through the Barman
        Cloud plugin. Non-null needs the barmanCloud and storageCredentials
        dependencies. Null takes no backups.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        postgresql.parameters.max_connections = "200";
      };
      description = ''
        Merged over the Cluster spec. Refused: `instances`, `imageName`,
        `imageCatalogRef`, `resources`, `storage.size`,
        `storage.storageClass`, `affinity.enablePodAntiAffinity`,
        `monitoring.enablePodMonitor`, and, while `backup` is set,
        `plugins` and `backup.barmanObjectStore`. `topologySpreadConstraints` replaces
        the spread the package derives from the availability level, and
        `enablePDB` the package's choice.
      '';
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        cnpgOperator,
        storageClasses ? null,
        prometheus ? null,
        barmanCloud ? null,
        storageCredentials ? null,
        endpointService ? null,
        ...
      }:
      let
        operator =
          if cnpgOperator.out ? operandSelectors then
            cnpgOperator.out
          else
            throw "${who}: the cnpgOperator dependency has no out.operandSelectors, as with an import. This package reads the operator's CRD handle and pod labels from it. Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";
        crds = operator.crds;

        operandSelector = operator.operandSelectors.cluster name;
        # The instance pods, without the Cluster's Job pods.
        instanceSelector = operandSelector // {
          "cnpg.io/podRole" = "instance";
        };

        storageClass =
          if config.storage.storageClass != null then
            config.storage.storageClass
          else if storageClasses != null then
            storageClasses.out.storageClassName
          else
            null;

        spread = lib.optionals (config.instances > 1) (
          kix.availability.spreadConstraints {
            level = availability;
            selector = instanceSelector;
            topology = clusterConfig.cluster.topology;
          }
        );

        quantity = q: if builtins.isString q then q else toString q;

        backupOn = config.backup != null;
        bk = config.backup;
        plugin =
          if barmanCloud == null then
            throw "${who}: backup is set and no barmanCloud dependency resolved. Add a cnpg-barman-cloud instance in the operator's namespace, or set backup = null."
          else if !(barmanCloud.out ? mkObjectStore) then
            throw "${who}: the barmanCloud dependency has no out.mkObjectStore, as with an import. Wire a cnpg-barman-cloud instance with deps.barmanCloud = ref.<namespace>.<instance>."
          else
            barmanCloud.out;

        credentialKeys =
          lib.genAttrs credentialSelectors (
            s: if bk.credentialKeys.${s} != null then bk.credentialKeys.${s} else s
          )
          // lib.optionalAttrs (bk.credentialKeys.region != null) { region = bk.credentialKeys.region; };
        credentials = kix.checkSecretKeys {
          inherit who;
          arg = "storageCredentials";
          dep =
            if storageCredentials == null then
              throw "${who}: backup is set and no storageCredentials dependency resolved in namespace ${ns}. Add a secret or secret-ref instance there with the keys ${lib.concatStringsSep " and " (builtins.attrValues credentialKeys)} and the alias storageCredentials, or set backup = null."
            else
              storageCredentials;
          keys = builtins.attrValues credentialKeys;
        };

        inClusterStore = endpointService != null;
        objectStoreSpec = kix.mergeGuarded {
          inherit who;
          what = "backup.extraSpec";
          locked = [
            [
              "configuration"
              "destinationPath"
            ]
            [
              "configuration"
              "s3Credentials"
            ]
            [ "retentionPolicy" ]
          ]
          ++ lib.optional inClusterStore [
            "configuration"
            "endpointURL"
          ];
        } objectStoreBase bk.extraSpec;
        objectStoreBase = {
          configuration = {
            inherit (bk) destinationPath;
            s3Credentials = lib.mapAttrs (
              _: key: (credentials.out.keyRef key).valueFrom.secretKeyRef
            ) credentialKeys;
          }
          // lib.optionalAttrs inClusterStore {
            endpointURL =
              (endpointService.out.url
                or (throw "${who}: deps.endpointService has no out.url. Wire an instance whose root is its S3 Service.")
              )
                { scheme = if bk.endpointScheme != null then bk.endpointScheme else "http"; };
          };
        }
        // lib.optionalAttrs (bk.retention != null) { retentionPolicy = bk.retention; };

        serverName = if bk.serverName != null then bk.serverName else "${ns}-${name}";

        _endpointScheme =
          if !inClusterStore && bk.endpointScheme != null then
            throw "${who}: backup.endpointScheme is set and no endpointService dependency resolved, so nothing reads it. Wire the in-cluster store with deps.endpointService = ref.<namespace>.<instance>, or remove backup.endpointScheme and give the scheme in backup.extraSpec.configuration.endpointURL."
          else
            null;

        # The store's port outside the cluster; null for an in-cluster store,
        # whose address reaches the instance pods through the Cluster. A world
        # egress rule does not reach pods, so an endpointURL naming a Service
        # is refused.
        storeWorldPort =
          if inClusterStore then
            null
          else if objectStoreSpec.configuration ? endpointURL then
            let
              url = objectStoreSpec.configuration.endpointURL;
            in
            if urlHostInCluster clusterConfig.clusterDomain url then
              throw "${who}: backup.extraSpec.configuration.endpointURL \"${url}\" names a Service in the cluster, and the instance pods get network policy only to stores outside it. Wire the store with deps.endpointService = ref.<namespace>.<instance> and remove endpointURL; set backup.endpointScheme = \"https\" if it serves TLS."
            else
              urlPort url
          else
            443;

        baseSpec = {
          inherit (config) instances resources;
          imageName = kix.image.ref config.image;
          storage = {
            size = quantity config.storage.size;
          }
          // lib.optionalAttrs (storageClass != null) { inherit storageClass; };
          affinity.enablePodAntiAffinity = false;
          enablePDB = config.instances > 1;
        }
        // lib.optionalAttrs (config.image.pullPolicy != null) {
          imagePullPolicy = config.image.pullPolicy;
        }
        // lib.optionalAttrs (spread != [ ]) {
          topologySpreadConstraints = spread;
        }
        // lib.optionalAttrs backupOn {
          plugins = [
            {
              name = plugin.pluginName;
              isWALArchiver = true;
              parameters = {
                barmanObjectName = self.objectStore.out.name;
                inherit serverName;
              };
            }
          ];
        };

        # Paths the package sets that no option owns.
        _unownedPaths =
          if config.extraSpec ? imageCatalogRef then
            throw "${who}: extraSpec sets imageCatalogRef, and the package sets imageName from the image option. Set image instead."
          else if (config.extraSpec.affinity or { }) ? enablePodAntiAffinity then
            throw "${who}: extraSpec sets affinity.enablePodAntiAffinity, which the package sets to false: the pods spread by the topologySpreadConstraints derived from the availability level. Remove it, or set topologySpreadConstraints in extraSpec."
          # CloudNativePG refuses a WAL archiver plugin beside the in-tree
          # barmanObjectStore (internal/webhook/v1/cluster_webhook.go upstream).
          else if backupOn && (config.extraSpec.backup or { }) ? barmanObjectStore then
            throw "${who}: extraSpec sets backup.barmanObjectStore while the backup option enables the Barman Cloud plugin as WAL archiver, and CloudNativePG refuses both on one Cluster. Remove backup.barmanObjectStore and configure the store through the backup option."
          else
            null;

        spec = builtins.seq _unownedPaths (
          kix.mergeGuarded {
            inherit who;
            locked = locked ++ lib.optional backupOn [ "plugins" ];
          } baseSpec config.extraSpec
        );

        postgresService = scope.mkServiceRef {
          name = "${name}-rw";
          selector = instanceSelector;
          ports = [
            {
              port = postgresPort;
              protocol = "TCP";
            }
          ];
          requires = [ self.cluster ];
        };

        # Read only when the scope has an enforcer (kix.operandPolicy).
        netpol = scope.networkPolicyEnforcer.netpol;
        tcp = port: {
          inherit port;
          protocol = "TCP";
        };
        operatorPorts = map tcp [
          statusPort
          postgresPort
        ];
        operatorNamespace = (scope.forService cnpgOperator).namespaceName;
        self' = netpol.mkSelfRules { selector = operandSelector; };
      in
      {
        inherit postgresService;

        cluster = scope.mkCR crds.Cluster {
          inherit name spec;
          # `kix.mkImport { from = packages.cnpg-cluster; }` takes its out
          # from this resource, without the operator dependency that
          # postgresService needs.
          outputs.port = toString postgresPort;
        };

        objectStore =
          if backupOn then
            builtins.seq _endpointScheme (
              plugin.mkObjectStore scope {
                name = "${name}-backup";
                spec = objectStoreSpec;
              }
            )
          else
            null;

        # With backupOwnerReference `self`, the ScheduledBackup owns each
        # Backup object it creates, and Kubernetes deletes them with it.
        # `immediate` takes the first base backup when the ScheduledBackup is
        # created, so the archived WAL has a base to replay onto from the
        # start.
        scheduledBackup =
          if backupOn then
            scope.mkCR crds.ScheduledBackup {
              inherit name;
              spec = {
                cluster.name = self.cluster.out.name;
                inherit (bk) schedule;
                method = "plugin";
                pluginConfiguration.name = plugin.pluginName;
                backupOwnerReference = "self";
                immediate = true;
              };
            }
          else
            null;

        # The plugin's sidecar in each instance pod writes to the store.
        backupEgress =
          if backupOn && storeWorldPort != null then
            kix.operandPolicy {
              inherit scope;
              name = "${name}-backup-egress";
              spec = {
                endpointSelector.matchLabels = instanceSelector;
                egress =
                  (netpol.translateIntentRules {
                    intents.store.egress = [
                      {
                        to = "world";
                        ports = [ (tcp storeWorldPort) ];
                      }
                    ];
                  }).egressRules;
              };
            }
          else
            null;

        podMonitor =
          if config.metrics.enabled && prometheus != null then
            prometheus.out.mkPodMonitor scope {
              name = podMonitorName;
              spec = {
                selector.matchLabels = instanceSelector;
                podMetricsEndpoints = [
                  (
                    {
                      # The instance manager's exporter (port name
                      # `metrics`). The scrape egress rule needs the number,
                      # because Kix does not see the operator's pods.
                      portNumber = metricsPort;
                    }
                    // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                  )
                ];
              };
              requires = [ self.cluster ];
            }
          else
            null;

        # The operator creates these pods, so no policy is derived for them.
        operandEgress = kix.operandPolicy {
          inherit scope;
          name = "${name}-operand-egress";
          spec = {
            endpointSelector.matchLabels = operandSelector;
            egress = [
              netpol.dnsEgressRule
              netpol.apiServerEgressRule
            ]
            ++ self'.egress;
          };
        };
        operandIngress = kix.operandPolicy {
          inherit scope;
          name = "${name}-operand-ingress";
          spec = {
            endpointSelector.matchLabels = operandSelector;
            ingress = self'.ingress ++ [
              (netpol.mkCallerIngressRule {
                callerSelector = operator.podSelector;
                callerNamespace = operatorNamespace;
                ports = operatorPorts;
              })
            ];
          };
        };
        # The other end of the operator rule, in the operator's namespace.
        operatorEgress = kix.operandPolicy {
          scope = scope.forService cnpgOperator;
          name = "${ns}-${name}-operator-egress";
          spec = {
            endpointSelector.matchLabels = operator.podSelector;
            egress = [
              (netpol.mkServiceEgressRule {
                selector = operandSelector;
                namespace = ns;
                sourceNamespace = operatorNamespace;
                ports = operatorPorts;
              })
            ];
          };
        };

        root = {
          resource = self.cluster;
          requires = [
            self.postgresService
          ]
          ++ builtins.filter (r: r != null) [
            self.podMonitor
            self.scheduledBackup
            self.backupEgress
            self.operandEgress
            self.operandIngress
            self.operatorEgress
            self.prometheusRules
          ];
          out = {
            inherit (postgresService.out) name fqdn port;
            clusterName = self.cluster.out.name;
            selector = instanceSelector;
            tls = true;
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # this one names those kix.alerts reads.
    (
      {
        config,
        scope,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${ns}",job="${ns}/${podMonitorName}"'';
        cluster = "PostgreSQL cluster ${ns}/${name}";
        status = "kubectl cnpg status ${name} -n ${ns}";
        standbys = config.instances - 1;
        lag = config.metrics.maxReplicationLag;
        # CloudNativePG sets no max_slot_wal_keep_size by default, so an
        # inactive slot retains WAL until the volume fills. WAL lives on
        # spec.walStorage when extraSpec sets it, else on the data volume.
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
              derived = scheduleMaxAge config.backup.schedule;
            in
            if derived != null then
              derived
            else
              throw "${who}: backup.schedule \"${config.backup.schedule}\" does not show how often base backups run, so CNPGBackupMissing has no threshold. Set metrics.maxBackupAge to twice the longest gap between two runs plus the time a backup takes, such as \"15d\" for a weekly schedule.";
        # The ScheduledBackup sets `immediate`, so CloudNativePG starts the
        # first base backup when it creates the ScheduledBackup rather than
        # at the first scheduled run. A day covers that backup on any
        # schedule; an hourly schedule's shorter threshold applies as is.
        firstBackupWindow = if durationSeconds backupAge < durationSeconds "24h" then backupAge else "24h";
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
          # cnpg_collector_up is 0 while the instance manager answers and
          # PostgreSQL does not, which a scrape failure alone does not show.
          CNPGClusterDown = {
            expr = "sum by (namespace, job) (cnpg_collector_up{${sel}}) == 0 or absent(cnpg_collector_up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "A CloudNativePG cluster has no running PostgreSQL instance.";
            description = "No instance of ${cluster} has reported PostgreSQL up for 10 minutes, so clients cannot connect. Check ${status} and the instance pods' logs.";
            runbook_url = runbook "CNPGClusterOffline";
          };
          # A replica cluster (spec.replica in extraSpec) replays WAL from its
          # source, so every instance is in recovery and none is primary.
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
          # Five times the default autovacuum_freeze_max_age (200 million):
          # autovacuum has not frozen the database for a long time. Every
          # instance reports the same ages, so the rule drops `pod`.
          CNPGTransactionIDAgeHigh = {
            expr = xidAge "1e9";
            "for" = "15m";
            severity = "warning";
            summary = "A CloudNativePG database is not being frozen by autovacuum.";
            description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID or multixact age of {{ $value | humanize }}. Autovacuum is not freezing it; look for long transactions, prepared transactions, or replication slots that hold back the oldest XID.";
          };
          # 1.6 billion is the default vacuum_failsafe_age and
          # vacuum_multixact_failsafe_age. PostgreSQL stops assigning IDs
          # three million short of 2^31.
          CNPGTransactionIDWraparoundImminent = {
            expr = xidAge "1.6e9";
            "for" = "5m";
            severity = "critical";
            summary = "A CloudNativePG database is close to transaction ID wraparound.";
            description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID or multixact age of {{ $value | humanize }}. PostgreSQL refuses writes at about 2.1 billion. Run VACUUM (FREEZE) on the database's oldest tables now and end the transactions that hold back the oldest XID.";
          };
          # CloudNativePG copies the primary's HA slots to the standbys,
          # where they are inactive, so only the primary's slots count.
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
          # Counts WAL receivers rather than walsenders on the primary, which
          # also count logical replication subscribers.
          CNPGStandbysNotStreaming = {
            expr = "sum by (namespace, job) (cnpg_pg_replication_is_wal_receiver_up{${sel}}) < ${toString standbys}";
            "for" = "10m";
            severity = "warning";
            summary = "A CloudNativePG standby is not streaming from the primary.";
            description = "{{ $value }} of the ${toString standbys} standbys of ${cluster} receive WAL. A standby that does not stream falls behind, and a failover to it loses data. Check ${status} and the standby pods' logs.";
            runbook_url = runbook "CNPGClusterHAWarning";
          };
          # The lag is 0 while a standby has replayed all it received, so an
          # idle primary does not raise it.
          CNPGReplicationLagHigh = {
            expr = "max by (namespace, job, pod) (cnpg_pg_replication_lag{${sel}}) > ${toString (durationSeconds lag)}";
            "for" = "15m";
            severity = "warning";
            summary = "A CloudNativePG standby is far behind the primary.";
            description = "Standby {{ $labels.pod }} of ${cluster} replays WAL {{ $value | humanizeDuration }} behind the primary, over metrics.maxReplicationLag (${lag}). Check the standby's disk and CPU, and the network to the primary.";
            runbook_url = runbook "CNPGClusterPhysicalReplicationLag";
          };
        }
        // lib.optionalAttrs (config.backup != null) {
          # Both times are -1 until the archiver's first attempt of that kind.
          CNPGWALArchivingFailing = {
            expr = "max by (namespace, job, pod) (cnpg_pg_stat_archiver_last_failed_time{${sel}}) > max by (namespace, job, pod) (cnpg_pg_stat_archiver_last_archived_time{${sel}})";
            "for" = "15m";
            severity = "warning";
            summary = "A CloudNativePG instance fails to archive WAL.";
            description = "The last WAL archive attempt of {{ $labels.pod }} in ${cluster} failed and none has succeeded since. Unarchived WAL stays on the volume until it fills, and point-in-time recovery stops at the last archived segment. Check the plugin-barman-cloud container's log in that pod and the ObjectStore ${name}-backup.";
          };
          # The timestamp is the evidence, so the threshold may exceed the
          # Prometheus retention. The plugin reports 0 until a backup
          # completes; CNPGBackupNeverCompleted covers that case.
          CNPGBackupMissing = {
            expr = "time() - max by (namespace, job) (${backupTs} > 0) > ${toString (durationSeconds backupAge)}";
            "for" = "5m";
            severity = "warning";
            summary = "A CloudNativePG cluster has no recent base backup.";
            description = "The last completed base backup of ${cluster} is {{ $value | humanizeDuration }} old, over ${backupAge} (metrics.maxBackupAge). Check kubectl get backups -n ${ns} and the plugin-barman-cloud container's log.";
          };
          # The `offset` term holds the alert until the metric has existed
          # for `firstBackupWindow`, which stays below the 7d retention of the
          # prometheus package whatever the schedule.
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
          # Without this, the backup alerts evaluate to nothing when the
          # plugin's sidecar cannot read the ObjectStore.
          CNPGBackupMetricsMissing = {
            expr = "count by (namespace, job) (up{${sel}} == 1) unless on (namespace, job) count by (namespace, job) (${backupTs})";
            "for" = "15m";
            severity = "warning";
            summary = "A CloudNativePG cluster reports no backup metrics.";
            description = "The instances of ${cluster} are scraped but report no Barman Cloud backup metrics, so the backup alerts cannot fire. Check that each instance pod runs the plugin-barman-cloud container and that its log shows no error reading the ObjectStore ${name}-backup.";
          };
        };
      } args
    )
  ];
}
