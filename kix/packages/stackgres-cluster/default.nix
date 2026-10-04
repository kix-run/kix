# stackgres-cluster: a PostgreSQL cluster run by the StackGres operator, as
# one SGCluster with its instance profile, PostgreSQL configuration, and
# optional pooling configuration and init scripts.
#
# The operator creates the pods, the Services, and the Secret named after the
# instance that holds the superuser credentials. The package references the
# primary Service and that Secret, so consumers wait for them and get network
# policy to the PostgreSQL pods. Apps should depend on a stackgres-database
# instance (alias `database`), which creates a role and database for them,
# rather than on this package.
#
# Minimal instance, with an operator elsewhere in the cluster:
#
#   instances.data.postgres.package = packages.stackgres-cluster;
#
# DI deps:
#   stackgresOperator (required)  a stackgres-operator instance; its release
#                                 decides the PostgreSQL versions and operand
#                                 images. An imported operator is refused:
#                                 an import has no out.resolvePostgres.
#   storageClasses (optional)     the class of the data volumes when
#                                 `persistentVolume.storageClass` is null.
#   sgObjectStorage (optional)    a stackgres-object-storage instance in this
#                                 namespace, read only when `backups` is set.
#   prometheus (optional)         a PodMonitor for the exporter sidecar,
#                                 and the alerts below.
#
# Defaults: `instances` from the availability level (1 at none, 2 at pod
# and node, 3 at zone), PostgreSQL 17, 1 CPU and 2Gi per instance, 20Gi
# volumes, TLS on, no connection pooler, no backups.
#
# Placement: with more than one instance, the pods spread over nodes and
# zones as the availability level asks. StackGres's production profile also
# requires every SGCluster pod of a namespace, of any cluster, to run on its
# own node, so the clusters of one namespace need as many nodes as they have
# instances together. On a single-node cluster the package turns that rule
# off (nonProductionOptions.disableClusterPodAntiAffinity).
#
# Network policy: with an enforcer, the package opens the PostgreSQL pods'
# DNS, API server, and peer traffic, the operator's access to Patroni (TCP
# 8008 and 8009), TCP 443 to the internet when `extensions` is set (the
# extensions repository), and the object storage's port when `backups` is
# set and the storage is outside the cluster. Clients get ingress through the
# primary Service reference.
#
# Escape hatch: `extraSpec`, merged over the SGCluster spec. The fields the
# options own are refused (listed on `extraSpec`), and so are
# `pods.disableEnvoy = false`, `postgres.flavor`, and turning the
# one-pod-per-node rule off at availability node or zone.
#
# Alerts: with a prometheus dependency, `metrics.enabled`, and the exporter
# sidecar on, a PrometheusRule `<instance>-alerts` selects the PodMonitor's
# series by `job="<namespace>/<instance>"`.
#   StackGresClusterDown (critical)          no instance's exporter reaches
#                                            PostgreSQL.
#   StackGresClusterNoPrimary (critical)     every instance is a replica;
#                                            not rendered with
#                                            `extraSpec.replicateFrom`.
#   StackGresClusterMultiplePrimaries (critical, instances > 1)
#                                            more than one instance accepts
#                                            writes.
#   StackGresStandbysNotStreaming (warning, instances > 1)
#                                            the primary streams to fewer
#                                            than `instances` - 1 standbys.
#   StackGresReplicationLagHigh (warning, instances > 1)
#                                            replay lag over
#                                            `metrics.maxReplicationLag`.
#   StackGresConnectionsHigh (warning)       client backends over 90% of
#                                            max_connections.
#   StackGresTransactionIDAgeHigh (warning)  XID age over 1e9.
#   StackGresTransactionIDWraparoundImminent (critical)
#                                            XID age over 1.6e9.
#   StackGresReplicationSlotInactive (warning)
#                                            an inactive slot on the
#                                            primary holds WAL over a quarter
#                                            of `persistentVolume.size`.
#   StackGresExporterErrors (warning)        the exporter's queries fail,
#                                            so series go missing.
#   StackGresWALArchivingFailing (warning, with `backups`)
#                                            WAL archive attempts fail and
#                                            none succeeds.
# The exporter publishes no backup metric. A failed backup Job is left to
# KubeJobFailed; "no successful backup recently" would need the backup
# CronJob's last success time from kube-state-metrics, so no rule covers it.
# Left to prometheus-default-rules: full volumes
# (KubePersistentVolumeFillingUp), crash loops (KubePodCrashLooping), unready
# instances (KubeStatefulSetReplicasMismatch), and one instance of several
# not scraped (TargetDown). Long transactions, deadlocks, and dead tuples
# depend on the workload and are left to the site.
#
# Limits: the operator also creates pods for SGDbOps and manually created
# SGBackups. Their labels differ from the cluster's pods, so under a
# network policy enforcer they get no policy from this package.
#
# Exposes:
#   out.name, out.fqdn, out.port  the primary Service (port 5432).
#   out.selector                  the PostgreSQL pods' labels.
#   out.superuserSecret           the operator's credentials Secret, keys
#                                 `superuser-username` and
#                                 `superuser-password`, for consumers in this
#                                 namespace.
#   out.extensions                the extension names in the SGCluster.
#   out.tls                       whether PostgreSQL serves TLS
#                                 (spec.postgres.ssl.enabled).
#   out.extraImages               the operand images the operator runs.
#
# root = the SGCluster.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "stackgres-cluster ${ns}/${name}";

  # The SGCluster fields this package writes are those of StackGres 1.19.
  supportedRelease = "1.19";

  # Extensions that need more than an entry in spec.postgres.extensions.
  extensionNeeds = {
    vchord = {
      preload = true;
      requires = [ "vector" ];
    };
  };
  # StackGres's default shared_preload_libraries.
  defaultPreload = [
    "pg_stat_statements"
    "auto_explain"
  ];

  # SGCluster spec paths the options own.
  locked = [
    [ "instances" ]
    [
      "postgres"
      "version"
    ]
    [
      "postgres"
      "extensions"
    ]
    [ "sgInstanceProfile" ]
    [
      "configurations"
      "sgPostgresConfig"
    ]
    [
      "configurations"
      "sgPoolingConfig"
    ]
    [
      "configurations"
      "backups"
    ]
    [
      "managedSql"
      "scripts"
    ]
    [
      "pods"
      "persistentVolume"
      "size"
    ]
    [
      "pods"
      "persistentVolume"
      "storageClass"
    ]
    [
      "pods"
      "disableConnectionPooling"
    ]
  ];

  dropNulls = lib.filterAttrs (_: v: v != null);

  # The requested extensions, one entry per name, with the extensions they
  # require added.
  extensionsOf =
    config:
    let
      requested = config.extensions;
      names = lib.unique (
        map (e: e.name) requested ++ lib.concatMap (e: extensionNeeds.${e.name}.requires or [ ]) requested
      );
      firstNonNull = list: lib.findFirst (v: v != null) null list;
    in
    map (
      n:
      let
        entries = builtins.filter (e: e.name == n) requested;
      in
      dropNulls {
        name = n;
        version = firstNonNull (map (e: e.version) entries);
        publisher = firstNonNull (map (e: e.publisher) entries);
        repository = firstNonNull (map (e: e.repository) entries);
      }
    ) names;

  versionConflicts =
    config:
    lib.concatMap (
      n:
      let
        versions = lib.unique (
          builtins.filter (v: v != null) (
            map (e: e.version) (builtins.filter (e: e.name == n) config.extensions)
          )
        );
      in
      lib.optional (builtins.length versions > 1)
        "extension ${n} is requested at versions ${lib.concatStringsSep " and " versions}. The packages that inject extensions through stackgres-database have to agree on one version."
    ) (lib.unique (map (e: e.name) config.extensions));

  quantity = q: if builtins.isString q then q else toString q;

  # The StackGres CRDs accept a narrower quantity grammar than Kubernetes.
  quantityChecks = config: [
    {
      option = "instanceProfile.cpu";
      value = config.instanceProfile.cpu;
      pattern = "[1-9][0-9]*m?";
      shown = "^[1-9][0-9]*[m]?$";
      fix = "Write whole cores (\"2\") or millicores (\"1500m\").";
    }
    {
      option = "instanceProfile.memory";
      value = config.instanceProfile.memory;
      pattern = "[0-9]+([.][0-9]+)?(Mi|Gi)";
      shown = "^[0-9]+(\\.[0-9]+)?(Mi|Gi)$";
      fix = "Use Mi or Gi, such as \"2Gi\".";
    }
    {
      option = "persistentVolume.size";
      value = config.persistentVolume.size;
      pattern = "[0-9]+([.][0-9]+)?(Mi|Gi|Ti)";
      shown = "^[0-9]+(\\.[0-9]+)?(Mi|Gi|Ti)$";
      fix = "Use Mi, Gi, or Ti, such as \"20Gi\".";
    }
  ];

  postgresPort = 5432;

  # The exporter sidecar runs unless extraSpec turns it off. StackGres 1.19
  # reads `configurations.observability.disableMetrics` and still accepts the
  # deprecated `pods.disableMetricsExporter`; either one removes the sidecar.
  exporterOnFor =
    config:
    !(
      (config.extraSpec.pods.disableMetricsExporter or false)
      || (config.extraSpec.configurations.observability.disableMetrics or false)
    );

  # The PodMonitor's name. Its series carry job="<namespace>/<name>", which
  # the alerts select on.
  podMonitorName = name;

  # A Prometheus duration such as "5m" or "1h30m", in seconds.
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
in
{
  meta = {
    description = "PostgreSQL cluster run by the StackGres operator (SGCluster)";
    owner = "platform";
    defaultAliases = [ "postgres" ];
    lifecycle = "stateful";
  };

  assertions =
    { config, ... }:
    map (message: {
      assertion = false;
      inherit message;
    }) (versionConflicts config)
    ++ [
      {
        assertion =
          builtins.stringLength name <= 44 && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
        message = "StackGres limits an SGCluster name to 44 characters matching ^[a-z]([-a-z0-9]*[a-z0-9])?$; \"${name}\" is ${toString (builtins.stringLength name)} characters. Rename the instance.";
      }
      {
        assertion = (config.extraSpec.pods or { }).disableEnvoy or true != false;
        message = "extraSpec sets pods.disableEnvoy = false. The Service reference and the network policy assume PostgreSQL on 5432 with no Envoy sidecar.";
      }
      {
        assertion = config.backups == null || builtins.all (b: !(b ? sgObjectStorage)) config.backups;
        message = "backups entries take sgObjectStorage from the sgObjectStorage dependency. Remove it.";
      }
    ]
    ++ lib.imap0 (i: s: {
      assertion = (s.script == null) != (s.scriptFrom == null);
      message = "scripts entry ${toString i} must set exactly one of script or scriptFrom.";
    }) config.scripts
    ++ map (c: {
      assertion = builtins.match c.pattern (quantity c.value) != null;
      message = "${c.option} is \"${quantity c.value}\", which StackGres refuses: it must match ${c.shown}. ${c.fix}";
    }) (quantityChecks config);

  warnings =
    { config, deps, ... }:
    lib.optional (config.backups == null && deps ? sgObjectStorage)
      "an sgObjectStorage instance resolved in ${ns} but backups is null, so this cluster takes no backups.";

  # An imported operator has no out.release; the build refuses it first.
  deps.stackgresOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the SGCluster fields of StackGres ${supportedRelease}, and the stackgresOperator dependency runs ${dep.out.release}. Update kix/packages/stackgres-cluster for that release.";
    }
  ];

  options = {
    instances = lib.mkOption {
      type = lib.types.ints.positive;
      # One instance cannot survive its own pod's restart, so `pod` needs a
      # second; three at `zone` keep a Patroni majority through a zone loss.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }";
      description = "PostgreSQL instances (`spec.instances`): one primary, the rest streaming replicas that Patroni fails over to.";
    };

    postgres.version = lib.mkOption {
      type = lib.types.str;
      default = "17";
      description = ''
        PostgreSQL major ("17") or minor ("17.11"), checked against the
        versions the operator's release ships. A major means its newest
        minor when the cluster is created. Changing the major needs an
        SGDbOps of type majorVersionUpgrade.
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
              description = "Base URL of the extensions repository to install the extension from. Null lets the operator choose among the repositories of its SGConfig (`extensions.repositoryUrls`).";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Extensions the operator installs (`spec.postgres.extensions`). A
        stackgres-database instance on this cluster adds the extensions it
        is asked for, so list here only what no database requests. Entries
        with the same name are merged; `vchord` adds `vector` and is
        preloaded.
      '';
    };

    instanceProfile = lib.mkOption {
      default = { };
      description = "The SGInstanceProfile spec: CPU and memory per instance, and any other SGInstanceProfile field.";
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
        description = "StorageClass of the data volumes. Null takes the `storageClasses` dependency's class, or the cluster's default class without one. StackGres does not move an existing volume to another class.";
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
        postgresql.conf parameters, over StackGres's defaults and the keys the
        package sets (`archive_timeout` with backups, and
        `shared_preload_libraries` for an extension that needs preloading,
        which keeps the libraries listed here). Null removes a package key.
        StackGres refuses some parameters it manages itself.
      '';
    };

    pooling = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = null;
      example = {
        pgBouncer."pgbouncer.ini".pgbouncer.pool_mode = "transaction";
      };
      description = ''
        SGPoolingConfig spec. Non-null creates it and turns on the pgbouncer
        sidecar; `{ }` takes StackGres's defaults. Null runs no pooler, so
        clients connect to PostgreSQL directly: the sidecar's auth_query
        needs an `authenticator` role and caches failed logins.
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
              description = "Script name, shown in the SGCluster status.";
            };
            database = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Database the script runs in. Null runs it in `postgres`.";
            };
            script = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "SQL to run. Set this or scriptFrom.";
            };
            scriptFrom = lib.mkOption {
              type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
              default = null;
              description = "A `secretKeyRef` or `configMapKeyRef` holding the SQL. Set this or script.";
            };
          };
        }
      );
      default = [ ];
      description = "Entries of the SGScript the cluster runs once each (`spec.scripts`). Other SGScript entry fields pass through.";
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
        Entries of `spec.configurations.backups`, each written with the
        `sgObjectStorage` dependency's SGObjectStorage. Non-null needs that
        dependency in this namespace. Other entry fields (`path`,
        `performance`, `useVolumeSnapshot`, ...) pass through. Null takes no
        backups.
      '';
    };

    metrics = kix.options.monitor // {
      maxReplicationLag = lib.mkOption {
        type = durationType;
        default = "5m";
        example = "30s";
        description = "How far a standby's replay may fall behind the primary before StackGresReplicationLagHigh fires, as a Prometheus duration. A standby that cannot keep up loses that much committed data if it is promoted. The default is the threshold of CloudNativePG's sample rules, as in cnpg-cluster.";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        pods.scheduling.nodeSelector."example.com/database" = "true";
      };
      description = ''
        Merged over the SGCluster spec. Refused: `instances`,
        `postgres.version`, `postgres.extensions`, `postgres.flavor`,
        `sgInstanceProfile`, `configurations.sgPostgresConfig`,
        `configurations.sgPoolingConfig`, `configurations.backups`,
        `managedSql.scripts`, `pods.persistentVolume.size`,
        `pods.persistentVolume.storageClass`, `pods.disableConnectionPooling`,
        and `pods.disableEnvoy = false`. `pods.scheduling.topologySpreadConstraints`
        replaces the spread the package derives from the availability level.
        A non-production `profile`, or
        `nonProductionOptions.disableClusterPodAntiAffinity = true`, is
        refused at availability node or zone with more than one instance.
      '';
    };
  };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        stackgresOperator,
        storageClasses ? null,
        sgObjectStorage ? null,
        prometheus ? null,
        ...
      }:
      let
        operator =
          if stackgresOperator.out ? resolvePostgres then
            stackgresOperator.out
          else
            throw "${who}: the stackgresOperator dependency has no out.resolvePostgres, as with an import. This package reads the operator's release, operand images, and pod labels from it. Wire a managed stackgres-operator instance with deps.stackgresOperator = ref.<namespace>.<instance>.";
        pg = operator.resolvePostgres {
          inherit who;
          inherit (config.postgres) version;
        };
        operandSelector = operator.operandSelectors.sgCluster name;
        extensions = extensionsOf config;
        extensionNames = map (e: e.name) extensions;
        backupsOn = config.backups != null;
        poolingOn = config.pooling != null;

        _flavor =
          if (config.extraSpec.postgres or { }) ? flavor then
            throw "${who}: postgres.flavor is not supported: the version check and the operand images assume vanilla PostgreSQL."
          else
            null;
        _storage =
          if backupsOn && sgObjectStorage == null then
            throw "${who}: backups is set but no sgObjectStorage dependency resolved in namespace ${ns}. Add a stackgres-object-storage instance there, or set backups = null."
          else
            null;

        storageClass =
          if config.persistentVolume.storageClass != null then
            config.persistentVolume.storageClass
          else if storageClasses != null then
            storageClasses.out.storageClassName
          else
            null;

        spread = lib.optionals (config.instances > 1) (
          kix.availability.spreadConstraints {
            level = availability;
            selector = operandSelector;
            topology = clusterConfig.cluster.topology;
          }
        );

        # The production profile's required anti-affinity matches every
        # SGCluster pod in the namespace on kubernetes.io/hostname, so on one
        # node a second pod of any cluster in the namespace stays Pending.
        singleNode = clusterConfig.cluster.topology.failureDomainKeys == [ ];

        baseSpec = {
          inherit (config) instances;
          postgres = {
            inherit (config.postgres) version;
          }
          // lib.optionalAttrs (extensions != [ ]) { inherit extensions; };
          sgInstanceProfile = self.instanceProfile.out.name;
          configurations = {
            sgPostgresConfig = self.postgresConfig.out.name;
          }
          // lib.optionalAttrs backupsOn {
            backups = map (
              b:
              dropNulls b
              // {
                sgObjectStorage = sgObjectStorage.out.name;
              }
            ) config.backups;
          }
          // lib.optionalAttrs poolingOn {
            sgPoolingConfig = self.poolingConfig.out.name;
          };
          pods = {
            persistentVolume = {
              size = quantity config.persistentVolume.size;
            }
            // lib.optionalAttrs (storageClass != null) { inherit storageClass; };
            disableConnectionPooling = !poolingOn;
          }
          // lib.optionalAttrs (spread != [ ]) {
            scheduling.topologySpreadConstraints = spread;
          };
        }
        // lib.optionalAttrs singleNode {
          nonProductionOptions.disableClusterPodAntiAffinity = true;
        }
        // lib.optionalAttrs (config.scripts != [ ]) {
          managedSql.scripts = [ { sgScript = self.scripts.out.name; } ];
        };

        spec = builtins.seq _flavor (
          kix.mergeGuarded {
            inherit who locked;
          } baseSpec config.extraSpec
        );

        # StackGres turns the anti-affinity off when
        # nonProductionOptions.disableClusterPodAntiAffinity is true, or when
        # it is unset and the profile is not production.
        profile = spec.profile or "production";
        antiAffinityFlag = (spec.nonProductionOptions or { }).disableClusterPodAntiAffinity or null;
        antiAffinityOff = if antiAffinityFlag != null then antiAffinityFlag else profile != "production";
        _antiAffinity =
          if kix.availability.atLeast "node" availability && config.instances > 1 && antiAffinityOff then
            throw "${who}: extraSpec turns off StackGres's one-pod-per-node anti-affinity (profile \"${profile}\", nonProductionOptions.disableClusterPodAntiAffinity ${
              if antiAffinityFlag == null then "unset" else "= true"
            }) with ${toString config.instances} instances at availability ${availability}, which needs the instances on different nodes. Use the production profile or set nonProductionOptions.disableClusterPodAntiAffinity = false, or lower the instance's availability."
          else
            null;

        exporterOn = exporterOnFor config;

        preloadNeeded = lib.filter (n: extensionNeeds.${n}.preload or false) extensionNames;
        userPreload = config.postgresqlConf.shared_preload_libraries or null;
        preload = lib.unique (
          (
            if userPreload != null then
              builtins.filter (l: l != "") (map lib.trim (lib.splitString "," userPreload))
            else
              defaultPreload
          )
          ++ preloadNeeded
        );

        postgresqlConf = dropNulls (
          lib.optionalAttrs backupsOn {
            # WAL reaches backup storage only when a 16 MB segment fills, so a
            # quiet database can hold hours of commits that no backup has. This
            # switches segments at least once a minute while anything is
            # written; an idle database switches nothing. A switched segment is
            # zero-padded, and stored as about 85 KB with lz4 (measured on a
            # test cluster).
            archive_timeout = "60";
          }
          // config.postgresqlConf
          // lib.optionalAttrs (preloadNeeded != [ ]) {
            shared_preload_libraries = lib.concatStringsSep ", " preload;
          }
        );

        crds = operator.crds;

        postgresService = scope.mkServiceRef {
          inherit name;
          selector = operandSelector;
          ports = [
            {
              port = postgresPort;
              protocol = "TCP";
            }
          ];
          requires = [ self.cluster ];
        };

        superuserSecret = scope.mkSecretRef {
          inherit name;
          keys = [
            "superuser-username"
            "superuser-password"
          ];
          requires = [ self.cluster ];
        };

        # Read only when the scope has an enforcer (kix.operandPolicy).
        netpol = scope.networkPolicyEnforcer.netpol;
        tcp = port: {
          inherit port;
          protocol = "TCP";
        };
        worldEgress =
          ports:
          (netpol.translateIntentRules {
            intents.operand.egress = [
              {
                to = "world";
                ports = map tcp ports;
              }
            ];
          }).egressRules;
        storagePort = if backupsOn then sgObjectStorage.out.worldEgressPort else null;
        operatorNamespace = (scope.forService stackgresOperator).namespaceName;
        # Patroni's REST API, which the operator calls.
        patroniPorts = map tcp [
          8008
          8009
        ];
        self' = netpol.mkSelfRules { selector = operandSelector; };
      in
      builtins.seq _storage (
        builtins.seq _antiAffinity {
          inherit postgresService superuserSecret;

          instanceProfile = scope.mkCR crds.SGInstanceProfile {
            name = "${name}-profile";
            spec = config.instanceProfile // {
              cpu = quantity config.instanceProfile.cpu;
              memory = quantity config.instanceProfile.memory;
            };
          };

          # The name carries the major: an SGPostgresConfig's postgresVersion
          # cannot change.
          postgresConfig = scope.mkCR crds.SGPostgresConfig {
            name = "${name}-pg${pg.major}-config";
            spec = {
              postgresVersion = pg.major;
              "postgresql.conf" = postgresqlConf;
            };
          };

          poolingConfig =
            if poolingOn then
              scope.mkCR crds.SGPoolingConfig {
                name = "${name}-pooling-config";
                # The API requires a spec, and Kix drops an empty one, so
                # `pooling = { }` writes an empty pgbouncer.ini for StackGres
                # to default.
                spec = lib.recursiveUpdate { pgBouncer."pgbouncer.ini" = { }; } config.pooling;
              }
            else
              null;

          scripts =
            if config.scripts != [ ] then
              scope.mkCR crds.SGScript {
                name = "${name}-init";
                spec.scripts = map dropNulls config.scripts;
              }
            else
              null;

          cluster = scope.mkCR crds.SGCluster {
            inherit name spec;
            # `kix.mkImport { from = packages.stackgres-cluster; }` takes its
            # out from this resource, without the operator dependency that
            # postgresService needs.
            outputs.port = toString postgresPort;
          };

          podMonitor =
            if config.metrics.enabled && prometheus != null && exporterOn then
              prometheus.out.mkPodMonitor scope {
                name = podMonitorName;
                spec = {
                  selector.matchLabels = operandSelector;
                  podMetricsEndpoints = [
                    (
                      {
                        # The operator's exporter sidecar listens on 9187 (port
                        # name pgexporter). The scrape egress rule needs the
                        # number, because Kix does not see the operator's pods.
                        portNumber = 9187;
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
              ++ self'.egress
              # The extensions repository.
              ++ lib.optionals (extensions != [ ]) (worldEgress [ 443 ])
              ++ lib.optionals (storagePort != null) (worldEgress [ storagePort ]);
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
                  ports = patroniPorts;
                })
              ];
            };
          };
          # The other end of the operator rule, in the operator's namespace.
          operatorEgress = kix.operandPolicy {
            scope = scope.forService stackgresOperator;
            name = "${ns}-${name}-operator-egress";
            spec = {
              endpointSelector.matchLabels = operator.podSelector;
              egress = [
                (netpol.mkServiceEgressRule {
                  selector = operandSelector;
                  namespace = ns;
                  sourceNamespace = operatorNamespace;
                  ports = patroniPorts;
                })
              ];
            };
          };

          root = {
            resource = self.cluster;
            requires = [
              self.instanceProfile
              self.postgresConfig
              self.postgresService
            ]
            ++ builtins.filter (r: r != null) [
              self.poolingConfig
              self.scripts
              self.podMonitor
              self.operandEgress
              self.operandIngress
              self.operatorEgress
              self.prometheusRules
            ];
            out = {
              inherit (postgresService.out) name fqdn port;
              selector = operandSelector;
              inherit superuserSecret;
              extensions = extensionNames;
              tls = (spec.postgres.ssl or { }).enabled or true;
              extraImages = [
                pg.images.patroni
                pg.images.postgresUtil
                pg.images.clusterController
              ]
              ++ lib.optional exporterOn pg.images.prometheusPostgresExporter
              ++ lib.optional poolingOn pg.images.pgbouncer
              # The backup CronJob runs kubectl.
              ++ lib.optionals backupsOn operator.kubectlImages;
            };
          };
        }
      )
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
        patronictl = "kubectl exec -n ${ns} <pod> -c patroni -- patronictl list";
        standbys = config.instances - 1;
        lag = config.metrics.maxReplicationLag;
        # StackGres sets no max_slot_wal_keep_size by default, so an
        # inactive slot retains WAL until the volume fills.
        slotBytes = kix.parseQuantity "memory" config.persistentVolume.size / 4;
        xidAge =
          threshold: "max by (namespace, job, datname) (pg_database_datfrozenxid_age{${sel}}) > ${threshold}";
      in
      kix.alerts {
        alerts = lib.optionalAttrs (exporterOnFor config) (
          {
            # pg_up is 0 while the exporter runs and cannot connect to
            # PostgreSQL, which a scrape failure alone does not show.
            StackGresClusterDown = {
              expr = "sum by (namespace, job) (pg_up{${sel}}) == 0 or absent(pg_up{${sel}})";
              "for" = "10m";
              severity = "critical";
              summary = "A StackGres cluster has no running PostgreSQL instance.";
              description = "No exporter of ${cluster} has reached PostgreSQL for 10 minutes, so clients cannot connect. Check kubectl describe sgcluster ${name} -n ${ns} and the patroni container's log in the instance pods.";
            };
            # Client backends only: the exporter also counts autovacuum,
            # WAL senders, and background workers, which max_connections
            # does not limit.
            StackGresConnectionsHigh = {
              expr = ''sum by (namespace, job, pod) (pg_stat_activity_count{${sel},backend_type="client backend"}) / max by (namespace, job, pod) (pg_settings_max_connections{${sel}}) > 0.9'';
              "for" = "15m";
              severity = "warning";
              summary = "A StackGres instance is close to max_connections.";
              description = "Instance {{ $labels.pod }} of ${cluster} uses {{ $value | humanizePercentage }} of max_connections, and new connections fail when none is left. Look for clients that hold idle connections, or set `pooling` to run PgBouncer.";
            };
            # Five times the default autovacuum_freeze_max_age (200 million):
            # autovacuum has not frozen the database for a long time. Every
            # instance reports the same ages, so the rule drops `pod`.
            StackGresTransactionIDAgeHigh = {
              expr = xidAge "1e9";
              "for" = "15m";
              severity = "warning";
              summary = "A StackGres database is not being frozen by autovacuum.";
              description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID age of {{ $value | humanize }}. Autovacuum is not freezing it; look for long transactions, prepared transactions, or replication slots that hold back the oldest XID.";
            };
            # 1.6 billion is the default vacuum_failsafe_age. PostgreSQL stops
            # assigning IDs three million short of 2^31.
            StackGresTransactionIDWraparoundImminent = {
              expr = xidAge "1.6e9";
              "for" = "5m";
              severity = "critical";
              summary = "A StackGres database is close to transaction ID wraparound.";
              description = "Database {{ $labels.datname }} of ${cluster} has a transaction ID age of {{ $value | humanize }}. PostgreSQL refuses writes at about 2.1 billion. Run VACUUM (FREEZE) on the database's oldest tables now and end the transactions that hold back the oldest XID.";
            };
            # Patroni keeps copies of the slots on the replicas, where they
            # are inactive, so only the primary's slots count.
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
          # A standby cluster replicates from elsewhere and has no primary.
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
            # The primary's pg_stat_replication rows in state `streaming`.
            # count() over no rows is empty, so the second branch gives 0
            # while any instance reports. A logical replication subscriber
            # also has a row and hides a missing standby.
            StackGresStandbysNotStreaming = {
              expr = ''(count by (namespace, job) (pg_stat_replication_pg_wal_lsn_diff{${sel},state="streaming"}) or sum by (namespace, job) (pg_replication_is_replica{${sel}}) * 0) < ${toString standbys}'';
              "for" = "10m";
              severity = "warning";
              summary = "A StackGres standby is not streaming from the primary.";
              description = "The primary of ${cluster} streams WAL to {{ $value }} of ${toString standbys} standbys. A standby that does not stream falls behind, and a failover to it loses data. Check ${patronictl} and the standby pods' logs.";
            };
            # The lag is 0 while a standby has replayed all it received, so
            # an idle primary does not raise it.
            StackGresReplicationLagHigh = {
              expr = "max by (namespace, job, pod) (pg_replication_lag_seconds{${sel}}) > ${toString (durationSeconds lag)}";
              "for" = "15m";
              severity = "warning";
              summary = "A StackGres standby is far behind the primary.";
              description = "Standby {{ $labels.pod }} of ${cluster} replays WAL {{ $value | humanizeDuration }} behind the primary, over metrics.maxReplicationLag (${lag}). Check the standby's disk and CPU, and the network to the primary.";
            };
          }
          // lib.optionalAttrs (config.backups != null) {
            # pg_stat_archiver has no last-failure time in this exporter, so
            # the rule compares the counters over the window. An idle
            # database archives nothing and fails nothing.
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
    )
  ];
}
