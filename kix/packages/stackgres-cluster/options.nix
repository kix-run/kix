# Options of the stackgres-cluster package. Kept free of `scope` so
# `docs/nix/reference.nix` can evaluate options statically.
{
  lib,
  kix,
  availability,
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
    description = "PostgreSQL instances (`spec.instances`): one primary, the rest streaming replicas that Patroni fails over to.";
  };

  postgres.version = lib.mkOption {
    type = lib.types.str;
    default = "17";
    description = ''
      PostgreSQL major (`"17"`) or minor (`"17.11"`), checked against the
      versions the operator's release ships. A major selects its newest minor
      when the cluster is created. Changing the major requires an `SGDbOps` of
      type `majorVersionUpgrade`.
    '';
  };

  extensions = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Extension name in the StackGres extensions repository.";
          };
          version = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Extension version. Null takes the repository's default.";
          };
          publisher = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Extension publisher. Null takes the repository's default.";
          };
          repository = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Base URL of the extensions repository to install from. Null lets the operator choose from its `SGConfig`.";
          };
        };
      }
    );
    default = [ ];
    description = ''
      Extensions the operator installs (`spec.postgres.extensions`). A
      `stackgres-database` instance on this cluster injects the extensions it
      requests, so list here only extensions no database requests. Entries
      with the same name are merged; `vchord` adds `vector` and is preloaded.
    '';
  };

  instanceProfile = lib.mkOption {
    default = { };
    description = "The `SGInstanceProfile` spec: CPU and memory per instance, and any other `SGInstanceProfile` field.";
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf lib.types.anything;
      options = {
        cpu = lib.mkOption {
          type = kix.types.quantity;
          default = "1";
          description = "CPU per instance, for the PostgreSQL container and the sidecars StackGres sizes from it.";
        };
        memory = lib.mkOption {
          type = kix.types.quantity;
          default = "2Gi";
          description = "Memory per instance.";
        };
      };
    };
  };

  persistentVolume = {
    size = lib.mkOption {
      type = kix.types.quantity;
      default = "20Gi";
      description = "Size of each instance's data volume.";
    };
    storageClass = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one.";
    };
  };

  postgresqlConf = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
    default = { };
    example = {
      max_connections = "200";
      work_mem = "16MB";
    };
    description = ''
      `postgresql.conf` parameters, merged over StackGres's defaults and the
      keys the package sets (`archive_timeout` when `backups` is set, and
      `shared_preload_libraries` when an extension needs preloading). Null
      removes a package key.
    '';
  };

  pooling = lib.mkOption {
    type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
    default = null;
    example = {
      pgBouncer."pgbouncer.ini".pgbouncer.pool_mode = "transaction";
    };
    description = ''
      `SGPoolingConfig` spec. Non-null creates it and enables the PgBouncer
      sidecar (`{ }` uses StackGres's defaults). Null runs no pooler, so
      clients connect to PostgreSQL directly.
    '';
  };

  scripts = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options = {
          name = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Script name, shown in the `SGCluster` status.";
          };
          database = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Database the script runs in. Null runs it in `postgres`.";
          };
          script = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "SQL to run. Set this or `scriptFrom`.";
          };
          scriptFrom = lib.mkOption {
            type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
            default = null;
            description = "A `secretKeyRef` or `configMapKeyRef` holding the SQL. Set this or `script`.";
          };
        };
      }
    );
    default = [ ];
    description = "Entries of the `SGScript` the cluster runs once each (`spec.scripts`).";
  };

  backups = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.listOf (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            cronSchedule = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "When to take a base backup, in cron syntax (UTC). Null takes StackGres's default.";
            };
            retention = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              description = "Base backups to keep. Null takes StackGres's default.";
            };
            compression = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "lz4"
                  "lzma"
                  "zstd"
                  "brotli"
                ]
              );
              default = null;
              description = "Backup compression. Null takes StackGres's default.";
            };
          };
        }
      )
    );
    default = null;
    example = [
      {
        cronSchedule = "0 1 * * *";
        retention = 7;
      }
    ];
    description = ''
      Entries of `spec.configurations.backups`, each wired to the
      `sgObjectStorage` dependency's `SGObjectStorage`. Requires that
      dependency in this namespace when non-null. Takes at most one entry,
      because StackGres schedules backups only from the first entry.
    '';
  };

  metrics = kix.options.monitor // {
    maxReplicationLag = lib.mkOption {
      type = kix.types.promDuration;
      default = "5m";
      example = "30s";
      description = "Maximum replay lag before `StackGresReplicationLagHigh` fires, as a Prometheus duration.";
    };
  };

  extraSpec = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    example = {
      pods.scheduling.nodeSelector."example.com/database" = "true";
    };
    description = ''
      Merged over the `SGCluster` spec. Refused: `instances`,
      `postgres.version`, `postgres.extensions`, `postgres.flavor`,
      `sgInstanceProfile`, `configurations.sgPostgresConfig`,
      `configurations.sgPoolingConfig`, `configurations.backups`,
      `managedSql.scripts`, `pods.persistentVolume.size`,
      `pods.persistentVolume.storageClass`, `pods.disableConnectionPooling`,
      and `pods.disableEnvoy = false`. `pods.scheduling.topologySpreadConstraints`
      replaces the spread derived from the availability level. A
      non-production `profile` or
      `nonProductionOptions.disableClusterPodAntiAffinity = true` is refused
      at availability `node` or `zone` with more than one instance.
    '';
  };
}
