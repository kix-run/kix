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
    tag = "18.7-standard-trixie";
    digest = "sha256:37fdeea29a4d3ed14570f719488ba55bd21e8975eaea864be5ce74d25a9a13de";
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
                description = "Key in the `storageCredentials` Secret that holds `${s}`. Defaults to `${s}` when `null`. Cannot be set when `storageCredentials` is a cloud identity.";
              }
            )
            // {
              region = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                default = null;
                description = "Key in the `storageCredentials` Secret that holds the S3 region. When `null`, no region key is read from the Secret. Cannot be set when `storageCredentials` is a cloud identity.";
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
      when set. Pass a Secret instance with S3 access keys or an AWS IAM role
      (`kix.cloudIdentity.aws { roleArn = "..."; }`) as `storageCredentials`.
    '';
  };

  import = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum [
              "microservice"
              "monolith"
            ];
            default = "microservice";
            description = ''
              `microservice` copies one database into the application
              database (`bootstrap.initdb.database`, owned by
              `bootstrap.initdb.owner`) and no roles. `monolith` copies the
              listed databases and roles and keeps their owners.
            '';
          };
          databases = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
            example = [ "registry" ];
            description = "Databases to copy from the source. `microservice` takes exactly one; `monolith` also takes `*` for every database.";
          };
          roles = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
            default = [ ];
            description = "Roles to copy, with `monolith` only. `*` copies every role.";
          };
          user = lib.mkOption {
            type = lib.types.nonEmptyStr;
            example = "postgres";
            description = "Role the import connects as. It must be able to read every object in the databases, and with `monolith`, the roles.";
          };
          sourceDatabase = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "postgres";
            description = "Database the import first connects to on the source (`connectionParameters.dbname`).";
          };
          sslMode = lib.mkOption {
            type = lib.types.enum [
              "disable"
              "allow"
              "prefer"
              "require"
              "verify-ca"
              "verify-full"
            ];
            default = "verify-full";
            description = ''
              libpq `sslmode` for the connection to the source. `verify-ca`
              and `verify-full` check the source's certificate against the
              `importCa` dependency, so they need one. `require` encrypts
              the connection without checking whose certificate it is.
            '';
          };
          passwordKey = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "password";
            description = "Key of the `importPassword` Secret that holds the password of `user`.";
          };
          extraSpec = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = {
              pgDumpExtraOptions = [ "--jobs=2" ];
              postImportApplicationSQL = [ "ANALYZE" ];
            };
            description = "Merged over `bootstrap.initdb.import`. Refused: `type`, `databases`, `roles`, and `source`. CloudNativePG runs `postImportApplicationSQL` after a microservice import only, so it is refused on a monolith import.";
          };
        };
      }
    );
    default = null;
    description = ''
      Copy databases from another PostgreSQL server when the Cluster is
      created (`bootstrap.initdb.import`). CloudNativePG runs `pg_dump`
      against the source and `pg_restore` into the new primary, once,
      before the instance starts. Writes to the source after that are not
      copied, so stop them before the first deploy. The source can run an
      older major version. Requires the `importSource` and `importPassword`
      dependencies when non-null.
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
      `affinity.enablePodAntiAffinity`, `monitoring.enablePodMonitor`,
      `bootstrap.initdb.import` (set `import` instead), when `backup` is
      set, `plugins` and `backup.barmanObjectStore`, and, when `import` is
      set, `externalClusters`, `bootstrap.recovery`, and
      `bootstrap.pg_basebackup`.
      `topologySpreadConstraints` replaces the spread derived from the
      availability level, and `enablePDB` replaces the package default.
    '';
  };
}
