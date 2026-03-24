# StackGres Cluster package — PostgreSQL cluster via StackGres CRDs.
#
# Creates the custom resources that the StackGres operator manages:
# SGInstanceProfile (sizing), SGPostgresConfig (tuning),
# SGObjectStorage (S3 backup destination), SGCluster (the cluster),
# and optionally SGPoolingConfig (connection pooling) and SGScript
# (init scripts).
#
# Designed for NW1's 7 PostgreSQL clusters — each instance of this
# package produces one complete PostgreSQL cluster.
#
# main = SGCluster, with outputs for port and service DNS name.

{
  scope,
  lib,
}:

let
  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "stackgres-cluster";
    "app.kubernetes.io/instance" = name;
  };

in
{
  options = {
    instances = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    postgres = lib.mkOption {
      type = lib.types.anything;
      default = {
        version = "16";
        extensions = [ ];
        flavor = "vanilla";
        ssl.enabled = true;
      };
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = {
        size = "20Gi";
        storageClass = "localzfs-retain";
      };
    };
    instanceProfile = lib.mkOption {
      type = lib.types.anything;
      default = {
        cpu = "1";
        memory = "2Gi";
      };
    };
    pgConfig = lib.mkOption {
      type = lib.types.anything;
      default = {
        name = null;
        maxConnections = "200";
        sharedBuffers = null;
        postgresqlConf = { };
      };
    };
    backup = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        retention = 5;
        cronSchedule = "30 04 * * *";
        compression = "lz4";
        s3 = {
          bucket = null;
          endpoint = null;
          region = "gra";
          credentialsSecret = null;
          accessKeyField = "accesskey";
          secretKeyField = "secretkey";
        };
      };
    };
    pooling = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        pgbouncerConf = { };
      };
    };
    prometheusAutobind = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    profile = lib.mkOption {
      type = lib.types.str;
      default = "production";
    };
    replication = lib.mkOption {
      type = lib.types.anything;
      default = {
        mode = "async";
        role = "ha-read";
      };
    };
    postgresServices = lib.mkOption {
      type = lib.types.anything;
      default = {
        primary = {
          enabled = true;
          type = "ClusterIP";
        };
        replicas = {
          enabled = true;
          type = "ClusterIP";
        };
      };
    };
    scripts = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    let
      # Parse memory to MB for calculations.
      memoryMB =
        let
          mem = config.instanceProfile.memory;
          numericGi = lib.removeSuffix "Gi" mem;
        in
        if lib.hasSuffix "Gi" mem then lib.toInt numericGi * 1024 else 2048;

      # Calculate shared_buffers from memory if not explicitly set.
      # Convention: ~25% of instance memory.
      sharedBuffers =
        if config.pgConfig.sharedBuffers != null then
          config.pgConfig.sharedBuffers
        else
          "${toString (memoryMB / 4)}MB";

      # effective_cache_size: ~75% of instance memory.
      effectiveCacheSize = "${toString (memoryMB * 3 / 4)}MB";

      # Default postgresql.conf — sensible baseline for a managed PostgreSQL cluster.
      defaultPostgresqlConf = {
        max_connections = config.pgConfig.maxConnections;
        shared_buffers = sharedBuffers;
        effective_cache_size = effectiveCacheSize;
        maintenance_work_mem = "128MB";
        checkpoint_completion_target = "0.9";
        checkpoint_timeout = "15min";
        wal_buffers = "16MB";
        default_statistics_target = "100";
        random_page_cost = "1.1";
        effective_io_concurrency = "200";
        work_mem = "100MB";
        huge_pages = "off";
        max_wal_senders = "20";
        max_replication_slots = "20";
        max_wal_size = "4GB";
        min_wal_size = "1GB";
        wal_keep_size = "1536MB";
        log_min_duration_statement = "1s";
        log_checkpoints = "on";
        log_connections = "on";
        log_disconnections = "on";
        log_lock_waits = "on";
        log_temp_files = "0kB";
        log_statement = "none";
        log_line_prefix = "%t [%p]: db=%d,user=%u,app=%a,client=%h ";
        log_autovacuum_min_duration = "0ms";
        autovacuum_max_workers = "3";
        autovacuum_vacuum_cost_delay = "2ms";
        autovacuum_vacuum_scale_factor = "0.04";
        autovacuum_work_mem = "512MB";
        default_toast_compression = "lz4";
        max_locks_per_transaction = "128";
        max_pred_locks_per_transaction = "128";
        max_prepared_transactions = "32";
        max_parallel_workers_per_gather = "1";
        max_parallel_maintenance_workers = "1";
        max_parallel_workers = "2";
        max_worker_processes = "2";
        superuser_reserved_connections = "8";
        vacuum_cost_limit = "400";
        track_activity_query_size = "4kB";
        track_commit_timestamp = "on";
        track_functions = "pl";
        track_io_timing = "on";
        shared_preload_libraries = "pg_stat_statements, auto_explain";
        "pg_stat_statements.track_utility" = "off";
        "timescaledb.license" = "timescale";
        jit_inline_above_cost = "-1";
        enable_partitionwise_join = "on";
        enable_partitionwise_aggregate = "on";
        lc_monetary = "C.UTF-8";
        lc_numeric = "C.UTF-8";
        lc_time = "C.UTF-8";
      };

      # Merge user overrides on top of defaults.
      postgresqlConf = defaultPostgresqlConf // config.pgConfig.postgresqlConf;

    in
    {

      # ===== SGInstanceProfile (CPU/memory sizing) =====

      instanceProfile = scope.mkResource {
        apiVersion = "stackgres.io/v1";
        kind = "SGInstanceProfile";
        name = "${name}-profile";
        labels = selectorLabels;
        spec = {
          cpu = config.instanceProfile.cpu;
          memory = config.instanceProfile.memory;
        };
      };

      # ===== SGPostgresConfig (PostgreSQL parameters) =====

      pgConfig = scope.mkResource {
        apiVersion = "stackgres.io/v1";
        kind = "SGPostgresConfig";
        name = if config.pgConfig.name != null then config.pgConfig.name else "${name}-config";
        labels = selectorLabels;
        spec = {
          postgresVersion = config.postgres.version;
          "postgresql.conf" = postgresqlConf;
        };
      };

      # ===== SGObjectStorage (S3 backup destination) =====

      objectStorage = lib.optionalAttrs config.backup.enabled (
        scope.mkResource ({
          apiVersion = "stackgres.io/v1beta1";
          kind = "SGObjectStorage";
          name = config.backup.s3.bucket;
          labels = selectorLabels;
          spec = {
            type = "s3Compatible";
            s3Compatible = {
              bucket = config.backup.s3.bucket;
              region = config.backup.s3.region;
              enablePathStyleAddressing = true;
            }
            // lib.optionalAttrs (config.backup.s3.endpoint != null) {
              endpoint = config.backup.s3.endpoint;
            }
            // lib.optionalAttrs (config.backup.s3.credentialsSecret != null) {
              awsCredentials = {
                secretKeySelectors = {
                  accessKeyId = {
                    name = config.backup.s3.credentialsSecret;
                    key = config.backup.s3.accessKeyField;
                  };
                  secretAccessKey = {
                    name = config.backup.s3.credentialsSecret;
                    key = config.backup.s3.secretKeyField;
                  };
                };
              };
            };
          };
        })
      );

      # ===== SGPoolingConfig (optional connection pooling) =====

      poolingConfig = lib.optionalAttrs config.pooling.enabled (
        scope.mkResource {
          apiVersion = "stackgres.io/v1";
          kind = "SGPoolingConfig";
          name = "${name}-pooling-config";
          labels = selectorLabels;
          spec = {
            pgBouncer = {
              "pgbouncer.ini" = {
                pgbouncer = {
                  pool_mode = "session";
                  max_client_conn = "200";
                  default_pool_size = 180;
                  ignore_startup_parameters = "extra_float_digits";
                  max_db_connections = "0";
                  max_user_connections = "0";
                }
                // config.pooling.pgbouncerConf;
              };
            };
          };
        }
      );

      # ===== SGScript (optional initialization scripts) =====

      initScript = lib.optionalAttrs (config.scripts != [ ]) (
        scope.mkResource {
          apiVersion = "stackgres.io/v1";
          kind = "SGScript";
          name = "${name}-init";
          labels = selectorLabels;
          spec = {
            scripts = lib.imap0 (i: script: {
              name = script.name or "script-${toString i}";
              database = script.database or "postgres";
              script = script.sql;
            }) config.scripts;
          };
        }
      );

      # ===== SGCluster (the PostgreSQL cluster) =====

      cluster = scope.mkResource {
        apiVersion = "stackgres.io/v1";
        kind = "SGCluster";
        name = name;
        labels = selectorLabels;
        spec = {
          instances = config.instances;
          postgres = {
            version = config.postgres.version;
            flavor = config.postgres.flavor;
            ssl = {
              enabled = config.postgres.ssl.enabled;
            };
          }
          // lib.optionalAttrs (config.postgres.extensions != [ ]) {
            extensions = config.postgres.extensions;
          };
          sgInstanceProfile = self.instanceProfile.out.name;
          profile = config.profile;
          prometheusAutobind = config.prometheusAutobind;
          replication = {
            mode = config.replication.mode;
            role = config.replication.role;
          };
          postgresServices = config.postgresServices;
          configurations = {
            sgPostgresConfig = self.pgConfig.out.name;
          }
          // lib.optionalAttrs config.backup.enabled {
            sgObjectStorage = self.objectStorage.out.name;
            backups = [
              {
                sgObjectStorage = self.objectStorage.out.name;
                cronSchedule = config.backup.cronSchedule;
                retention = config.backup.retention;
                compression = config.backup.compression;
              }
            ];
          }
          // lib.optionalAttrs config.pooling.enabled {
            sgPoolingConfig = self.poolingConfig.out.name;
          };
          pods = {
            persistentVolume = {
              size = config.storage.size;
              storageClass = config.storage.storageClass;
            };
          };
        }
        // lib.optionalAttrs (config.scripts != [ ]) {
          managedSql = {
            scripts = [
              {
                sgScript = self.initScript.out.name;
              }
            ];
          };
        };
        outputs = {
          port = "5432";
          serviceName = "${name}.${scope.namespaceName}.svc";
          serviceNamePrimary = "${name}-primary.${scope.namespaceName}.svc";
          serviceNameReplicas = "${name}-replicas.${scope.namespaceName}.svc";
        };
      };

      # ===== Entry point =====

      main = {
        resource = self.cluster;
        requires = [
          self.instanceProfile
          self.pgConfig
        ]
        ++ lib.optional config.backup.enabled self.objectStorage
        ++ lib.optional config.pooling.enabled self.poolingConfig
        ++ lib.optional (config.scripts != [ ]) self.initScript;

        # Package-level out: expose configured extension names for consumer validation.
        out = {
          extensionNames = map (e: e.name) config.postgres.extensions;
        };
      };
    };
}
