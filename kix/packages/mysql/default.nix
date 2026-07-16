# MySQL — single-instance server + application database/user.
#
# Implements the `sql-database` capability (the same contract
# stackgres-database exposes), so consumers wire it identically:
#
#   build = { database, ... }: {
#     env = database.out.connectionEnv "DB_";
#   };
#
# Deliberately single-instance. Replication, Group Replication and InnoDB
# Cluster are out of scope: they need an operator, and this package exists
# for the "one database for one app" case (PRINCIPLES §14 — three similar
# lines beat a premature abstraction). `replicas` is therefore validated,
# not offered — see `_replicaCheck`.
#
# The server owns its datadir via the StatefulSet's volumeClaimTemplate
# rather than a `storage` dep: the volume's identity is tied to the pod
# ordinal, so it is not a swappable cluster-operator concern the way an
# app's data volume is. (scorecard:architecture.capabilityOwnership only
# fingerprints standalone PersistentVolumeClaim resources, so this is
# compliant.)
#
# Dependencies:
#   backupStorage — optional; required when `backup.enabled`. A PVC the
#                   dump CronJob writes to. Keeping dumps on a PVC lets an
#                   existing cluster backup tool (Velero et al.) ship them
#                   offsite, instead of this package growing S3 credentials.
#
# root = Service (port 3306).

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
in
{
  meta = {
    version = "8.4.3";
    description = "MySQL — single-instance server with an application database";
    lifecycle = "stateful"; # other packages depend on this database existing
    scope = "namespace";
    provides = [ "sql-database" ];
    # NOT `database`: that alias belongs to stackgres-database, and kix's
    # phase-1 dep pre-pass throws on an ambiguous alias before a consumer's
    # explicit `deps` override can disambiguate (BEST-PRACTICES §8.4). A
    # cluster running both must stay resolvable.
    defaultAliases = [ "mysql" ];
    maintainer = "platform";
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "mysql";
        tag = "8.4.3-oracle";
        pullPolicy = "IfNotPresent";
      };
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Database created on first initialisation. Defaults to the instance name.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = ''
        Application user, granted ALL PRIVILEGES on `database` by the image's
        entrypoint. Defaults to the instance name.
      '';
    };

    # The image's entrypoint honours MYSQL_DATABASE / MYSQL_USER /
    # MYSQL_PASSWORD only on *first* initialisation of an empty datadir.
    # Changing these later has no effect on an existing volume — the values
    # are baked into the data at init. Rotating the password afterwards is a
    # manual ALTER USER; `rotationPolicy = "manual"` records that.
    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Literal application-user password (development only). Mutually
        exclusive with passwordSource. The plaintext lands in the Nix store
        and the rendered Secret manifest.
      '';
    };

    passwordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a SOPS-encrypted file containing a `password` key.";
    };

    rootPassword = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Literal root password (development only). Mutually exclusive with rootPasswordSource.";
    };

    rootPasswordSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a SOPS-encrypted file containing a `root-password` key.";
    };

    existingSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = ''kix.untrackedRef "mysql-credentials"'';
      description = ''
        Name of an existing Secret carrying `username`, `password` and
        `root-password`, used instead of this package creating one. Suits
        clusters where a controller materialises Secrets from an external
        secrets manager. Mutually exclusive with password / rootPassword and
        their *Source variants.

        Pass `kix.untrackedRef "..."` when the Secret is created outside kix:
        a raw string literal is rejected, since nothing in the graph would
        then guarantee the Secret exists.

        `username` must match the `user` option — the entrypoint reads
        MYSQL_USER from config, and the key exists so consumers of the
        `sql-database` contract can read it from the Secret.
      '';
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = ''
        Must be 1. Present only so that asking for more fails at build time
        with an explanation, rather than silently starting N independent
        servers on N datadirs that never replicate.
      '';
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 3306;
    };

    myCnf = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        [mysqld]
        max_allowed_packet=128M
      '';
      description = ''
        Extra server configuration, mounted into /etc/mysql/conf.d. Include
        the section header ([mysqld], [client], …) yourself.
      '';
    };

    initSql = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        SQL run once, on first initialisation of an empty datadir, via
        /docker-entrypoint-initdb.d. Ignored on an existing volume — it is
        not a migration mechanism.
      '';
    };

    persistence = lib.mkOption {
      type = lib.types.anything;
      default = {
        size = "10Gi";
        storageClass = null;
      };
      description = "Datadir volume. storageClass = null uses the cluster default.";
    };

    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
        requests = {
          cpu = "250m";
          memory = "512Mi";
        };
        limits = {
          cpu = "2";
          memory = "2Gi";
        };
      };
    };

    backup = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
        schedule = "0 2 * * *";
        retentionDays = 7;
        resources = {
          requests = {
            cpu = "100m";
            memory = "256Mi";
          };
          limits = {
            cpu = "1";
            memory = "1Gi";
          };
        };
      };
      description = ''
        Scheduled logical backup. Runs `mysqldump --single-transaction`,
        which is transaction-consistent for InnoDB without locking, and
        gzips the result onto the `backupStorage` volume.

        Consistency does NOT extend to MyISAM/Aria tables. A volume snapshot
        of a running server is only crash-consistent, so this is what makes
        a restore trustworthy.
      '';
    };
  };

  build =
    {
      self,
      config,
      scope,
      lib,
      kix,
      backupStorage ? null,
      ...
    }:
    let
      dbName = config.database;
      userName = config.user;

      # --- Compile-time sanity checks (PRINCIPLES §6) ----------------------
      # Each of these is a silent-data-loss or silent-no-op at runtime, so
      # they fail the build with an actionable reason instead.
      _replicaCheck =
        if config.replicas != 1 then
          throw (
            "mysql '${name}': replicas must be 1 (got ${toString config.replicas}). This package runs a "
            + "single server with no replication — additional replicas would each initialise their own "
            + "independent datadir behind one Service, silently splitting reads and writes. For a "
            + "replicated topology use an operator-backed package."
          )
        else
          null;

      usesExistingSecret = config.existingSecret != null;

      _passwordCheck =
        if usesExistingSecret then
          if
            config.password != null
            || config.passwordSource != null
            || config.rootPassword != null
            || config.rootPasswordSource != null
          then
            throw (
              "mysql '${name}': `existingSecret` is set, so password / rootPassword (and their "
              + "*Source variants) must all be null — the existing Secret is the only source of "
              + "credentials."
            )
          else
            null
        else if config.password == null && config.passwordSource == null then
          throw "mysql '${name}': set `password` (literal), `passwordSource` (SOPS path), or `existingSecret`."
        else if config.password != null && config.passwordSource != null then
          throw "mysql '${name}': set `password` OR `passwordSource`, not both."
        else if config.rootPassword == null && config.rootPasswordSource == null then
          throw "mysql '${name}': set `rootPassword` (literal), `rootPasswordSource` (SOPS path), or `existingSecret`."
        else if config.rootPassword != null && config.rootPasswordSource != null then
          throw "mysql '${name}': set `rootPassword` OR `rootPasswordSource`, not both."
        else
          null;

      _backupCheck =
        if config.backup.enabled && backupStorage == null then
          throw (
            "mysql '${name}': `backup.enabled` is true but no `backupStorage` dep resolved. Declare a "
            + "persistent-volume-claim instance for the dumps and wire it, e.g. "
            + "`deps.backupStorage = ref.<namespace>.<pvc-instance>`."
          )
        else
          null;

      checks = builtins.seq _replicaCheck (builtins.seq _passwordCheck _backupCheck);

      labels = scope.selectorLabels // {
        "app.kubernetes.io/name" = "mysql";
      };

      # Only actual secrets live here. stackgres-database also carries
      # host/port/database in its credentials Secret, but it can: its host
      # comes from a *dep* (the postgres cluster). Ours would come from this
      # package's own Service, which is reachable from the StatefulSet that
      # consumes this Secret — putting them here would invert that edge into
      # a cycle. Non-secret connection details are published on `out` instead.
      credentialKeys = [
        "username"
        "password"
        "root-password"
      ];

      credentials =
        if usesExistingSecret then
          scope.mkSecretRef {
            name = config.existingSecret;
            keys = credentialKeys;
          }
        else
          scope.mkSecret {
            name = "${name}-credentials";
            keys = credentialKeys;
            stringData = {
              username = userName;
            }
            // lib.optionalAttrs (config.password != null) { password = config.password; }
            // lib.optionalAttrs (config.rootPassword != null) { root-password = config.rootPassword; };
            # Both passwords are hydrated from the same SOPS file when sourced,
            # keyed `password` / `root-password`.
            source = if config.passwordSource != null then config.passwordSource else config.rootPasswordSource;
            inherit labels;
            meta = {
              classification = "credential";
              rotationPolicy = "manual";
            };
          };

      configMap = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-config";
        inherit labels;
        data =
          lib.optionalAttrs (config.myCnf != "") {
            "custom.cnf" = config.myCnf;
          }
          // lib.optionalAttrs (config.initSql != "") {
            "init.sql" = config.initSql;
          };
      };

      hasConfig = config.myCnf != "";
      hasInitSql = config.initSql != "";

      serverEnv =
        credentials.out.mkEnv {
          MYSQL_ROOT_PASSWORD = "root-password";
          MYSQL_PASSWORD = "password";
        }
        ++ kix.mkEnvVars {
          MYSQL_DATABASE = dbName;
          MYSQL_USER = userName;
        };

      # Probes talk over the local socket rather than TCP: a socket
      # connection authenticates as root@localhost, which the entrypoint
      # always creates. Going via 127.0.0.1 would instead depend on
      # root@'%' existing (it does by default, but MYSQL_ROOT_HOST can
      # remove it) and interacts badly with `skip-name-resolve`.
      #
      # `mysqladmin ping` answers on the socket before the server accepts
      # real queries, so readiness runs an actual query instead.
      readinessCmd = ''mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null'';
      livenessCmd = ''mysqladmin ping -u root -p"$MYSQL_ROOT_PASSWORD"'';

      serverContainer = {
        name = "mysql";
        image = "${config.image.repository}:${config.image.tag}";
        imagePullPolicy = config.image.pullPolicy;
        ports = [ (kix.port "mysql" config.port) ];
        env = serverEnv;
        inherit (config) resources;
        # initdb on an empty datadir can take a while; keep liveness off the
        # pod until startup has genuinely completed.
        startupProbe = {
          exec.command = [
            "sh"
            "-c"
            readinessCmd
          ];
          periodSeconds = 5;
          timeoutSeconds = 5;
          failureThreshold = 60;
        };
        readinessProbe = {
          exec.command = [
            "sh"
            "-c"
            readinessCmd
          ];
          periodSeconds = 10;
          timeoutSeconds = 5;
          failureThreshold = 3;
        };
        livenessProbe = {
          exec.command = [
            "sh"
            "-c"
            livenessCmd
          ];
          periodSeconds = 20;
          timeoutSeconds = 5;
          failureThreshold = 5;
        };
        volumeMounts = [
          {
            name = "data";
            mountPath = "/var/lib/mysql";
          }
        ]
        ++ lib.optional hasConfig {
          name = "config";
          mountPath = "/etc/mysql/conf.d/custom.cnf";
          subPath = "custom.cnf";
        }
        ++ lib.optional hasInitSql {
          name = "config";
          mountPath = "/docker-entrypoint-initdb.d/init.sql";
          subPath = "init.sql";
        };
      };

      # mysqldump over the network — it never mounts the datadir, so it is
      # unaffected by the RWO/same-node constraints a physical backup has.
      backupScript = ''
        set -eu
        stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
        out="/backup/${dbName}-$stamp.sql.gz"

        echo "dumping ${dbName} -> $out"
        # Password comes from MYSQL_PWD, not --password=, to keep it out of
        # the container's process list.
        mysqldump \
          --host="$MYSQL_HOST" \
          --port="$MYSQL_PORT" \
          --user=root \
          --single-transaction \
          --events \
          --routines \
          --triggers \
          "${dbName}" \
          | gzip -c > "$out.tmp"

        # Rename only after a clean dump, so a failed run can never leave a
        # truncated file that looks like a valid backup.
        mv "$out.tmp" "$out"
        echo "wrote $out ($(stat -c %s "$out") bytes)"

        echo "pruning dumps older than ${toString config.backup.retentionDays} days"
        find /backup -name '${dbName}-*.sql.gz' -type f -mtime +${toString config.backup.retentionDays} -print -delete
      '';

      backupCronJob = scope.mkResource {
        apiVersion = "batch/v1";
        kind = "CronJob";
        name = "${name}-backup";
        inherit labels;
        spec = {
          schedule = config.backup.schedule;
          # A dump that overruns its window must not stack up behind itself.
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 3;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 2;
            template = {
              metadata.labels = labels;
              spec = {
                restartPolicy = "OnFailure";
                containers = [
                  {
                    name = "mysqldump";
                    image = "${config.image.repository}:${config.image.tag}";
                    imagePullPolicy = config.image.pullPolicy;
                    command = [
                      "/bin/sh"
                      "-c"
                    ];
                    args = [ backupScript ];
                    resources = config.backup.resources;
                    # The dump connects over TCP from its own pod, so it
                    # authenticates as root@'%' (created by the image's
                    # entrypoint from MYSQL_ROOT_HOST, default '%') rather
                    # than root@localhost.
                    env =
                      (credentials.out.mkEnv {
                        MYSQL_PWD = "root-password";
                      })
                      ++ kix.mkEnvVars {
                        MYSQL_HOST = self.service.out.fqdn;
                        MYSQL_PORT = toString config.port;
                      };
                    volumeMounts = [
                      {
                        name = "backup";
                        mountPath = "/backup";
                      }
                    ];
                  }
                ];
                volumes = [
                  {
                    name = "backup";
                    persistentVolumeClaim.claimName = backupStorage.out.name;
                  }
                ];
              };
            };
          };
        };
      };

      # Connection env under a caller-chosen prefix. Mirrors
      # stackgres-database's helper so the two `sql-database` providers are
      # drop-in for consumers that use it.
      mkConnectionEnv =
        prefix:
        (kix.mkEnvVars {
          "${prefix}HOSTNAME" = self.service.out.fqdn;
          "${prefix}PORT" = toString config.port;
          "${prefix}DATABASENAME" = dbName;
        })
        ++ (credentials.out.mkEnv {
          "${prefix}USERNAME" = "username";
          "${prefix}PASSWORD" = "password";
        });
    in
    builtins.seq checks (
      {
        inherit credentials;
        config = configMap;

        statefulSet =
          {
            inherit name;
            inherit labels;
            spec = {
              serviceName = self.headlessService.out.name;
              replicas = 1;
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  containers = [ serverContainer ];
                  # The image's entrypoint starts as root and drops to the
                  # mysql user (uid 999); fsGroup makes the datadir writable
                  # to it on a freshly provisioned volume.
                  securityContext.fsGroup = 999;
                  volumes = lib.optional (hasConfig || hasInitSql) {
                    name = "config";
                    configMap.name = self.config.out.name;
                  };
                };
              };
              volumeClaimTemplates = [
                {
                  metadata = {
                    name = "data";
                    inherit labels;
                  };
                  spec = {
                    accessModes = [ "ReadWriteOnce" ];
                    resources.requests.storage = config.persistence.size;
                  }
                  // lib.optionalAttrs (config.persistence.storageClass != null) {
                    storageClassName = config.persistence.storageClass;
                  };
                }
              ];
            };
          }
          |> scope.mkStatefulSet;

        # Headless Service for the StatefulSet's stable pod DNS.
        headlessService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-headless";
          inherit labels;
          spec = {
            type = "ClusterIP";
            clusterIP = "None";
            selector = labels;
            ports = [
              {
                name = "mysql";
                port = config.port;
                targetPort = "mysql";
                protocol = "TCP";
              }
            ];
          };
        };

        # Derived from the workload rather than hand-built, so the Service
        # carries the StatefulSet's store-path context. That single edge is
        # what makes the whole package reachable from the PI closure
        # (root → service → statefulSet → credentials/config/headless);
        # a hand-rolled Service has no edge to its workload and strands them.
        service = self.statefulSet |> kix.service.fromWorkload { inherit name; } |> scope.mkResource;

        root = {
          resource = self.service;
          # `service` is derived from the StatefulSet, which in turn reaches
          # config and headlessService through its volume / serviceName refs.
          # The credentials Secret is *not* otherwise reachable from the PI
          # closure (kix/pi-checks.nix invariant 4 fails without this), so it
          # is declared explicitly — the same thing valkey does for its auth
          # secret. Required in both modes: when `existingSecret` is set this
          # is a mkSecretRef, whose marker still has to be in the closure for
          # the deploy CLI to verify the Secret exists.
          requires = [ self.credentials ];
          # The `sql-database` contract, matching stackgres-database.
          out = {
            host = self.service.out.fqdn;
            port = toString config.port;
            database = dbName;
            username = userName;
            credentials = self.credentials;
            connectionEnv = mkConnectionEnv;
          };
        };
      }
      // lib.optionalAttrs config.backup.enabled {
        backup = backupCronJob;
      }
    );
}
