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
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    instances = 2;
    postgres.version = "16";
    storage = {
      size = "20Gi";
      storageClass = "localzfs-retain";
    };
    instanceProfile = {
      cpu = "1";
      memory = "2Gi";
    };
    pgConfig = {
      maxConnections = "200";
      sharedBuffers = null;
    };
    backup = {
      enabled = true;
      retention = 5;
      cronSchedule = "30 04 * * *";
      s3 = {
        bucket = null;
        endpoint = null;
        region = "gra";
      };
    };
    pooling = {
      enabled = false;
      mode = "transaction";
      maxClientConnections = "200";
    };
    scripts = [ ];
  };

  name = scope.instanceName;

  selectorLabels = {
    "app.kubernetes.io/name" = "stackgres-cluster";
    "app.kubernetes.io/instance" = name;
  };

  # Calculate shared_buffers from memory if not explicitly set.
  # Convention: ~25% of instance memory.
  sharedBuffers =
    if cfg.pgConfig.sharedBuffers != null then
      cfg.pgConfig.sharedBuffers
    else
      let
        # Parse memory string (e.g., "2Gi" -> 512MB for shared_buffers)
        mem = cfg.instanceProfile.memory;
        # Convert Gi to MB, take 25%.  "2Gi" -> 2*1024/4 = 512MB.
        numericGi = lib.removeSuffix "Gi" mem;
        mbValue = lib.toInt numericGi * 1024 / 4;
      in
      if lib.hasSuffix "Gi" mem then "${toString mbValue}MB" else "512MB";

in
self: {

  # ===== SGInstanceProfile (CPU/memory sizing) =====

  instanceProfile = scope.mkResource {
    apiVersion = "stackgres.io/v1";
    kind = "SGInstanceProfile";
    name = "${name}-profile";
    labels = selectorLabels;
    spec = {
      cpu = cfg.instanceProfile.cpu;
      memory = cfg.instanceProfile.memory;
    };
  };

  # ===== SGPostgresConfig (PostgreSQL parameters) =====

  pgConfig = scope.mkResource {
    apiVersion = "stackgres.io/v1";
    kind = "SGPostgresConfig";
    name = "${name}-pgconfig";
    labels = selectorLabels;
    spec = {
      postgresVersion = cfg.postgres.version;
      postgresql.conf = {
        max_connections = cfg.pgConfig.maxConnections;
        shared_buffers = sharedBuffers;
        # Sensible defaults for a managed PostgreSQL cluster.
        wal_level = "replica";
        max_wal_senders = "10";
        max_replication_slots = "10";
        hot_standby = "on";
        effective_cache_size = sharedBuffers;
        maintenance_work_mem = "128MB";
        checkpoint_completion_target = "0.9";
        wal_buffers = "16MB";
        default_statistics_target = "100";
        random_page_cost = "1.1";
        effective_io_concurrency = "200";
        work_mem = "4MB";
        huge_pages = "try";
        log_min_duration_statement = "1000";
        log_checkpoints = "on";
        log_connections = "on";
        log_disconnections = "on";
        log_lock_waits = "on";
        log_temp_files = "0";
      };
    };
  };

  # ===== SGObjectStorage (S3 backup destination) =====

  objectStorage = scope.mkResource ({
    apiVersion = "stackgres.io/v1beta1";
    kind = "SGObjectStorage";
    name = "${name}-backup-storage";
    labels = selectorLabels;
    spec = {
      type = "s3Compatible";
      s3Compatible = {
        bucket = cfg.backup.s3.bucket;
        region = cfg.backup.s3.region;
        enablePathStyleAddressing = true;
      }
      // lib.optionalAttrs (cfg.backup.s3.endpoint != null) {
        endpoint = cfg.backup.s3.endpoint;
      };
    };
  });

  # ===== SGPoolingConfig (optional connection pooling) =====

  poolingConfig = lib.optionalAttrs cfg.pooling.enabled (
    scope.mkResource {
      apiVersion = "stackgres.io/v1";
      kind = "SGPoolingConfig";
      name = "${name}-pooling";
      labels = selectorLabels;
      spec = {
        pgBouncer = {
          pgbouncer.ini = {
            pgbouncer = {
              pool_mode = cfg.pooling.mode;
              max_client_conn = cfg.pooling.maxClientConnections;
              default_pool_size = "25";
              min_pool_size = "5";
              reserve_pool_size = "5";
              reserve_pool_timeout = "3";
              server_round_robin = "1";
              stats_period = "60";
            };
          };
        };
      };
    }
  );

  # ===== SGScript (optional initialization scripts) =====

  initScript = lib.optionalAttrs (cfg.scripts != [ ]) (
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
        }) cfg.scripts;
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
      instances = cfg.instances;
      postgres = {
        version = cfg.postgres.version;
      };
      sgInstanceProfile = "${self.instanceProfile}";
      configurations = {
        sgPostgresConfig = "${self.pgConfig}";
      }
      // lib.optionalAttrs cfg.backup.enabled {
        sgObjectStorage = "${self.objectStorage}";
        backups = [
          {
            sgObjectStorage = "${self.objectStorage}";
            cronSchedule = cfg.backup.cronSchedule;
            retention = cfg.backup.retention;
          }
        ];
      }
      // lib.optionalAttrs cfg.pooling.enabled {
        sgPoolingConfig = "${self.poolingConfig}";
      };
      pods = {
        persistentVolume = {
          size = cfg.storage.size;
          storageClass = cfg.storage.storageClass;
        };
      };
    }
    // lib.optionalAttrs (cfg.scripts != [ ]) {
      managedSql = {
        scripts = [
          {
            sgScript = "${self.initScript}";
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
    ++ lib.optional cfg.backup.enabled self.objectStorage
    ++ lib.optional cfg.pooling.enabled self.poolingConfig
    ++ lib.optional (cfg.scripts != [ ]) self.initScript;
  };
}
