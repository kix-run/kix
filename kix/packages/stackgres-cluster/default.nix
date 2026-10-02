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
#   stackgresOperator (required)  the operator; its release decides the
#                                 PostgreSQL versions and operand images.
#   storageClasses (optional)     the class of the data volumes when
#                                 `persistentVolume.storageClass` is null.
#   sgObjectStorage (optional)    a stackgres-object-storage instance in this
#                                 namespace, read only when `backups` is set.
#   prometheus (optional)         a PodMonitor for the exporter sidecar.
#
# Defaults: `instances` from the availability level (1 at none, 2 at pod
# and node, 3 at zone), PostgreSQL 17, 1 CPU and 2Gi per instance, 20Gi
# volumes, TLS on, no connection pooler, no backups. When `instances` is above one, the pods
# spread over nodes and zones as the availability level asks, and StackGres's
# production profile keeps one pod per node.
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
# `pods.disableEnvoy = false` and `postgres.flavor`.
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

  postgresPort = 5432;
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
    }) config.scripts;

  warnings =
    { config, deps, ... }:
    lib.optional (config.backups == null && deps ? sgObjectStorage)
      "an sgObjectStorage instance resolved in ${ns} but backups is null, so this cluster takes no backups.";

  deps.stackgresOperator.assertions = dep: [
    {
      assertion = lib.versions.majorMinor dep.out.release == supportedRelease;
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

    metrics = kix.options.monitor;

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
        and `pods.disableEnvoy = false`.
      '';
    };
  };

  build =
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
      pg = stackgresOperator.out.resolvePostgres {
        inherit who;
        inherit (config.postgres) version;
      };
      operandSelector = stackgresOperator.out.operandSelectors.sgCluster name;
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
      // lib.optionalAttrs (config.scripts != [ ]) {
        managedSql.scripts = [ { sgScript = self.scripts.out.name; } ];
      };

      spec = builtins.seq _flavor (
        kix.mergeGuarded {
          inherit who locked;
        } baseSpec config.extraSpec
      );

      profile = spec.profile or "production";
      _profile =
        if config.instances > 1 && availability != "none" && profile != "production" then
          throw "${who}: extraSpec.profile is \"${profile}\" with ${toString config.instances} instances at availability ${availability}. Only the production profile keeps StackGres's one-pod-per-node rule; use it, or lower instances."
        else
          null;

      exporterOn = !((spec.pods or { }).disableMetricsExporter or false);

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

      crds = stackgresOperator.out.crds;

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
      tcp = port: [
        {
          ports = [
            {
              port = toString port;
              protocol = "TCP";
            }
          ];
        }
      ];
      worldTcp = port: (netpol.mkExternalEgressRule { }) // { toPorts = tcp port; };
      storagePort = if backupsOn then sgObjectStorage.out.worldEgressPort else null;
      operatorNamespace = (scope.forService stackgresOperator).namespaceName;
      patroniPorts = [
        {
          ports =
            map
              (port: {
                port = toString port;
                protocol = "TCP";
              })
              [
                8008
                8009
              ];
        }
      ];
      self' = netpol.mkSelfRules { selector = operandSelector; };
    in
    builtins.seq _storage (
      builtins.seq _profile {
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
              inherit name;
              spec = {
                selector.matchLabels = operandSelector;
                podMetricsEndpoints = [
                  (
                    {
                      port = "pgexporter";
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
            ++ lib.optional (extensions != [ ]) (worldTcp 443)
            ++ lib.optional (storagePort != null) (worldTcp storagePort);
          };
        };
        operandIngress = kix.operandPolicy {
          inherit scope;
          name = "${name}-operand-ingress";
          spec = {
            endpointSelector.matchLabels = operandSelector;
            ingress = self'.ingress ++ [
              {
                fromEndpoints = [
                  {
                    matchLabels = stackgresOperator.out.podSelector // {
                      "k8s:io.kubernetes.pod.namespace" = operatorNamespace;
                    };
                  }
                ];
                toPorts = patroniPorts;
              }
            ];
          };
        };
        # The other end of the operator rule, in the operator's namespace.
        operatorEgress = kix.operandPolicy {
          scope = scope.forService stackgresOperator;
          name = "${ns}-${name}-operator-egress";
          spec = {
            endpointSelector.matchLabels = stackgresOperator.out.podSelector;
            egress = [
              {
                toEndpoints = [
                  {
                    matchLabels = operandSelector // {
                      "k8s:io.kubernetes.pod.namespace" = ns;
                    };
                  }
                ];
                toPorts = patroniPorts;
              }
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
            ++ lib.optional poolingOn pg.images.pgbouncer;
          };
        };
      }
    );
}
