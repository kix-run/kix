# Options of the cnpg-cluster package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  availability,
  credentialSelectors,
}:
{
  instances = lib.mkOption {
    type = lib.types.ints.positive;
    default = kix.availability.pick availability {
      none = 1;
      pod = 2;
      node = 2;
      zone = 2;
    };
    defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; }";
    description = "PostgreSQL instances (`spec.instances`): one primary, the rest streaming replicas the operator fails over to.";
  };

  image = kix.options.image {
    repository = "ghcr.io/cloudnative-pg/postgresql";
    tag = "18.6-standard-trixie";
    digest = "sha256:f89a40f4d74aa6e0900917eaf6299b125a6382eb02fd4ee5d46f55bcbf7e5726";
    description = "PostgreSQL operand image (`spec.imageName`). The tag must start with the PostgreSQL version. The `standard` images include contrib extensions, `pgvector`, `pgaudit`, and `pg_failover_slots`.";
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
      type = kix.types.promDuration;
      default = "5m";
      example = "30s";
      description = "Maximum replay lag before `CNPGReplicationLagHigh` fires, as a Prometheus duration.";
    };
    maxBackupAge = lib.mkOption {
      type = lib.types.nullOr kix.types.promDuration;
      default = null;
      example = "15d";
      description = "Maximum age of the last completed base backup before `CNPGBackupMissing` fires, as a Prometheus duration. Null derives it from `backup.schedule` via `kix.schedules.staleAfter` (two periods plus two hours). Must be set explicitly when `backup.schedule` has no derivable period.";
    };
  };

  backup = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          destinationPath = lib.mkOption {
            type = lib.types.strMatching "s3://[^/]+(/.*)?";
            example = "s3://pg-backups/main";
            description = "Where WAL and base backups go, as `s3://<bucket>[/<prefix>]` (`configuration.destinationPath`). The plugin writes under `serverName`.";
          };
          serverName = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][-A-Za-z0-9._]*");
            default = null;
            example = "pg";
            description = ''
              Folder under `destinationPath` that this Cluster archives to
              (the plugin's `serverName` parameter). Null uses
              `<namespace>-<instance>`.
            '';
          };
          schedule = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "0 0 0 * * *";
            description = "When to take a base backup (`spec.schedule` on ScheduledBackup): six cron fields with seconds first, or `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`, or `@every <duration>`.";
          };
          endpointScheme = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "http"
                "https"
              ]
            );
            default = null;
            description = "Scheme of the `endpointService` dependency's URL in `configuration.endpointURL` (null means `http`). Set only with an `endpointService` dependency.";
          };
          retention = lib.mkOption {
            type = lib.types.nullOr (lib.types.strMatching "[1-9][0-9]*[dwm]");
            default = null;
            example = "30d";
            description = "Retention window (`retentionPolicy` on ObjectStore): a number followed by `d`, `w`, or `m`. Null keeps everything.";
          };
          credentialKeys =
            lib.genAttrs credentialSelectors (
              s:
              lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Key of the `storageCredentials` Secret holding `${s}`; null reads `${s}`.";
              }
            )
            // {
              region = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Key of the `storageCredentials` Secret holding the S3 region. Null sets no region.";
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
              Merged over the `ObjectStore` spec. Refused:
              `configuration.destinationPath`, `configuration.s3Credentials`,
              `retentionPolicy`, and, with an `endpointService` dependency,
              `configuration.endpointURL`. An `endpointURL` pointing to an
              in-cluster `.svc` hostname is refused; wire `endpointService`
              instead.
            '';
          };
        };
      }
    );
    default = null;
    description = ''
      WAL archiving and scheduled base backups to S3 through the Barman Cloud
      plugin. Requires the `barmanCloud` and `storageCredentials` dependencies
      when non-null.
    '';
  };

  extraSpec = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    example = {
      postgresql.parameters.max_connections = "200";
    };
    description = ''
      Merged over the `Cluster` spec. Refused: `instances`, `imageName`,
      `imageCatalogRef`, `resources`, `storage.size`, `storage.storageClass`,
      `affinity.enablePodAntiAffinity`, `monitoring.enablePodMonitor`, and,
      when `backup` is set, `plugins` and `backup.barmanObjectStore`.
      `topologySpreadConstraints` replaces the spread derived from the
      availability level, and `enablePDB` replaces the package default.
    '';
  };
}
