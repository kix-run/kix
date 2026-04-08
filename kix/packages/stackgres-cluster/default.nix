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
# root = SGCluster, with outputs for port and service DNS name.

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
  meta = {
    version = "1.0.0";
    defaultAliases = [ "postgres" ];
    lifecycle = "stateful";
  };

  options = {
    instances = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };
    postgres = lib.mkOption {
      type = lib.types.anything;
      default = {
        version = "16";
        flavor = "vanilla";
        ssl.enabled = true;
      };
    };
    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = "PostgreSQL extensions to install (e.g. pgvecto.rs). Uses listOf for merge semantics with dep config injection.";
    };
    storage = lib.mkOption {
      type = lib.types.anything;
      default = {
        size = "20Gi";
        storageClass = null;
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
        backups = [
          {
            cronSchedule = "0 1 * * *";
            retention = 7;
            compression = "lz4";
          }
          {
            cronSchedule = "0 12 * * 1";
            retention = 3;
            compression = "lz4";
          }
        ];
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
    pgConfigIncludeVersion = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    pooling = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        pgbouncerConf = { };
      };
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
    # Pod update strategy method.
    # InPlace = upgrade without pod restart; ReducedImpact = rolling restart.
    updateMethod = lib.mkOption {
      type = lib.types.str;
      default = "ReducedImpact";
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
      storageClasses ? null,
      stackgresOperator, # runtime dep — ensures operator is deployed before clusters
      reflector ? null, # optional — when present, the superuser secret is
      # opted into cross-namespace propagation via emberstack/reflector and
      # this package emits a one-shot annotator Job that adds the reflector
      # annotations to the operator-managed source secret.
      ...
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

      # Merge user overrides on top of defaults, filtering out null values
      # (set a key to null in postgresqlConf to remove a default).
      postgresqlConf = lib.filterAttrs (_: v: v != null) (
        defaultPostgresqlConf // config.pgConfig.postgresqlConf
      );

      # Resolve effective storageClass: explicit config > DI > error.
      effectiveStorageClass =
        if config.storage.storageClass != null then
          config.storage.storageClass
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          throw "stackgres-cluster: config.storage.storageClass must be set or a storageClasses dependency must be available";

      # CRD refs exposed by the operator — each has .mkCR for building CRs
      # with per-resource dependencies on the CRD import marker.
      sgCrds = stackgresOperator.out.crds;

      # StackGres auto-creates a secret named after the cluster holding
      # superuser/replication/authenticator credentials. Expose a ref so
      # consumers can pull `superuser-username` / `superuser-password`.
      #
      # `reflect` is wired from DI: when an emberstack/reflector instance is
      # discovered in the cluster, helpers produced from this ref get a
      # `_kix.reflected = true` marker and the cross-namespace check in
      # `checkNamespacedRefs` is relaxed. Without reflector in the cluster,
      # consumption stays strictly same-namespace and any cross-namespace
      # consumer fails the build with the usual error. The annotator Job
      # below is also gated on `reflectionEnabled`.
      reflectionEnabled = reflector != null;

      superuserSecret = scope.mkSecretRef {
        inherit name;
        keys = [
          "superuser-username"
          "superuser-password"
        ];
        reflect = reflectionEnabled;
        requires = [ self.cluster ];
      };

    in
    {

      # ===== SGInstanceProfile (CPU/memory sizing) =====

      instanceProfile = scope.mkCR sgCrds.sgInstanceProfile {
        name = "${name}-profile";
        labels = selectorLabels;
        spec = {
          cpu = config.instanceProfile.cpu;
          memory = config.instanceProfile.memory;
        };
      };

      # ===== SGPostgresConfig (PostgreSQL parameters) =====

      pgConfig = scope.mkCR sgCrds.sgPostgresConfig {
        name =
          if config.pgConfig.name != null then
            config.pgConfig.name
          else if config.pgConfigIncludeVersion then
            "${name}-pg${config.postgres.version}-config"
          else
            "${name}-config";
        labels = selectorLabels;
        spec = {
          postgresVersion = config.postgres.version;
          "postgresql.conf" = postgresqlConf;
        };
      };

      # ===== SGObjectStorage (S3 backup destination) =====

      objectStorage = lib.optionalAttrs config.backup.enabled (
        scope.mkCR sgCrds.sgObjectStorage ({
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
        scope.mkCR sgCrds.sgPoolingConfig {
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
        scope.mkCR sgCrds.sgScript {
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

      cluster = scope.mkCR sgCrds.sgCluster {
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
          // lib.optionalAttrs (config.extensions != [ ]) {
            extensions = config.extensions;
          };
          sgInstanceProfile = self.instanceProfile.out.name;
          profile = config.profile;
          replication = {
            mode = config.replication.mode;
            role = config.replication.role;
          };
          postgresServices = config.postgresServices;
          configurations = {
            sgPostgresConfig = self.pgConfig.out.name;
          }
          // lib.optionalAttrs config.backup.enabled {
            backups = map (
              b:
              {
                sgObjectStorage = self.objectStorage.out.name;
                compression = b.compression;
                retention = b.retention;
              }
              // lib.optionalAttrs (b ? cronSchedule) {
                cronSchedule = b.cronSchedule;
              }
            ) config.backup.backups;
          }
          // lib.optionalAttrs config.pooling.enabled {
            sgPoolingConfig = self.poolingConfig.out.name;
          };
          pods = {
            persistentVolume = {
              size = config.storage.size;
              storageClass = effectiveStorageClass;
            };
            updateStrategy = {
              method = config.updateMethod;
            };
            # StackGres ships a pgbouncer sidecar by default even without an
            # SGPoolingConfig. Its auth_query path needs an `authenticator`
            # role in the DB, and when that role is missing every login gets
            # cached as a failure ("server_login_retry"), breaking even the
            # superuser bootstrap Job. When consumers haven't explicitly
            # opted into pooling, disable the sidecar so the main cluster
            # service talks to postgres directly.
            disableConnectionPooling = !config.pooling.enabled;
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
          # StackGres creates `${name}-primary` (ExternalName alias) and
          # `${name}-replicas` services. The auto-derived fqdn points at
          # `${name}`, which is the real ClusterIP backing `${name}-primary`
          # — clients can use either.
          serviceName = "${name}.${scope.namespaceName}.svc";
          serviceNamePrimary = "${name}-primary.${scope.namespaceName}.svc";
          serviceNameReplicas = "${name}-replicas.${scope.namespaceName}.svc";
        };
      };

      # ===== Reflector annotator (cross-namespace secret propagation) =====
      #
      # The StackGres operator creates `${name}` Secret in this namespace
      # holding superuser/replication credentials. To make those credentials
      # consumable from other namespaces (immich, vaultwarden, …) we use the
      # emberstack/reflector controller, which copies a Secret into target
      # namespaces when its source carries `reflector.v1.k8s.emberstack.com/*`
      # annotations.
      #
      # We can't add those annotations declaratively because kix doesn't own
      # the source manifest (the operator does). Instead we run a one-shot
      # Job that waits for the secret to exist and then `kubectl annotate`s
      # it. The Job has its own ServiceAccount + Role limited to
      # patching this single secret.

      reflectorAnnotatorSA =
        if reflectionEnabled then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-reflector-annotator";
            labels = selectorLabels;
          }
        else
          null;

      reflectorAnnotatorRole =
        if reflectionEnabled then
          scope.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "Role";
            name = "${name}-reflector-annotator";
            labels = selectorLabels;
            extra.rules = [
              {
                apiGroups = [ "" ];
                resources = [ "secrets" ];
                resourceNames = [ name ];
                verbs = [
                  "get"
                  "patch"
                  "update"
                ];
              }
            ];
          }
        else
          null;

      reflectorAnnotatorBinding =
        if reflectionEnabled then
          scope.mkResource {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "RoleBinding";
            name = "${name}-reflector-annotator";
            labels = selectorLabels;
            extra = {
              roleRef = {
                apiGroup = "rbac.authorization.k8s.io";
                kind = "Role";
                name = self.reflectorAnnotatorRole.out.name;
              };
              subjects = [
                {
                  kind = "ServiceAccount";
                  name = self.reflectorAnnotatorSA.out.name;
                  namespace = scope.namespaceName;
                }
              ];
            };
          }
        else
          null;

      reflectorAnnotatorJob =
        if reflectionEnabled then
          scope.mkResource {
            apiVersion = "batch/v1";
            kind = "Job";
            name = "${name}-reflector-annotator";
            labels = selectorLabels;
            annotations = {
              # Re-run on every apply so the annotation is reapplied if the
              # operator ever recreates the secret.
              "kix.dev/hook" = "post-deploy";
              "kix.dev/hook-delete-policy" = "before-hook-creation,hook-succeeded";
            };
            spec = {
              backoffLimit = 20;
              ttlSecondsAfterFinished = 600;
              template = {
                metadata.labels = selectorLabels;
                spec = {
                  restartPolicy = "OnFailure";
                  serviceAccountName = self.reflectorAnnotatorSA.out.name;
                  containers = [
                    {
                      name = "annotate";
                      # Bitnami sunset their free Docker Hub repos in Aug 2025
                      # (`bitnami/kubectl` is gone). `bitnamilegacy/*` is the
                      # frozen snapshot they pushed for migration; fine for a
                      # one-shot annotator that just needs `kubectl annotate`.
                      image = "bitnamilegacy/kubectl:1.30";
                      command = [
                        "/bin/sh"
                        "-c"
                      ];
                      args = [
                        ''
                          set -e
                          echo "waiting for secret ${name} in namespace ${scope.namespaceName}..."
                          for i in $(seq 1 120); do
                            if kubectl get secret ${name} -n ${scope.namespaceName} >/dev/null 2>&1; then
                              break
                            fi
                            sleep 5
                          done
                          kubectl get secret ${name} -n ${scope.namespaceName} >/dev/null
                          kubectl annotate secret ${name} -n ${scope.namespaceName} --overwrite \
                            reflector.v1.k8s.emberstack.com/reflection-allowed=true \
                            reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces='.*' \
                            reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
                            reflector.v1.k8s.emberstack.com/reflection-auto-namespaces='.*'
                          echo "annotated."
                        ''
                      ];
                    }
                  ];
                };
              };
            };
          }
        else
          null;

      # ===== Entry point =====

      root = {
        resource = self.cluster;
        requires = [
          self.instanceProfile
          self.pgConfig
        ]
        ++ lib.optionals reflectionEnabled [
          self.reflectorAnnotatorSA
          self.reflectorAnnotatorRole
          self.reflectorAnnotatorBinding
          self.reflectorAnnotatorJob
        ]
        ++ lib.optional config.backup.enabled self.objectStorage
        ++ lib.optional config.pooling.enabled self.poolingConfig
        ++ lib.optional (config.scripts != [ ]) self.initScript;

        # Package-level out: expose configured extension names for consumer validation.
        out = {
          extensionNames = map (e: e.name) config.extensions;
          # Handle to the operator-created credentials secret. Consumers use
          # `postgres.out.superuserSecret.out.mkEnv { DB_USER = "superuser-username"; ... }`.
          superuserSecret = superuserSecret;
        };
      };
    };
}
