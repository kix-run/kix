# stackgres-cluster: a PostgreSQL cluster run by the StackGres operator, as
# one SGCluster with its instance profile, PostgreSQL configuration, and
# optional pooling configuration and init scripts.
#
# The operator creates the pods, the Services, and the Secret named after the
# instance holding superuser credentials. The package references the primary
# Service and that Secret so consumers wait for them and get network policy to
# the PostgreSQL pods. Apps should depend on a `stackgres-database` instance
# (alias `database`) rather than directly on this package.
#
#   instances.data.postgres.package = packages.stackgres-cluster;
#
# Dependencies:
#   stackgresOperator (required)  Managed `stackgres-operator` instance.
#   storageClasses (optional)     StorageClass when
#                                 `persistentVolume.storageClass` is null.
#   sgObjectStorage (optional)    `stackgres-object-storage` in this namespace,
#                                 read when `backups` is set.
#   prometheus (optional)         PodMonitor and PrometheusRule alerts.
#
# Network policy, with an enforcer: the PostgreSQL pods reach DNS, the API
# server, each other, and the object store; the operator reaches Patroni.
# The Job pods of every SGDbOps and manually created SGBackup in the
# namespace reach DNS and the API server, and SGDbOps Jobs reach PostgreSQL.
#
# Exposes (`root.out`, `root` = the `SGCluster`):
#   out.name, out.fqdn, out.port  Primary Service (port 5432).
#   out.selector                  PostgreSQL pod labels.
#   out.superuserSecret           Superuser credentials Secret reference.
#   out.extensions                Installed extension names.
#   out.tls                       Whether PostgreSQL serves TLS.
#   out.extraImages               Operand images run by the operator.

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

  supportedRelease = "1.19";

  extensionNeeds = {
    vchord = {
      preload = true;
      requires = [ "vector" ];
    };
  };
  defaultPreload = [
    "pg_stat_statements"
    "auto_explain"
  ];

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

  exporterOnFor =
    config:
    !(
      (config.extraSpec.pods.disableMetricsExporter or false)
      || (config.extraSpec.configurations.observability.disableMetrics or false)
    );

  podMonitorName = name;
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

  deps.stackgresOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the SGCluster fields of StackGres ${supportedRelease}, and the stackgresOperator dependency runs ${dep.out.release}. Update kix/packages/stackgres-cluster for that release.";
    }
  ];

  options = import ./options.nix {
    inherit lib kix availability;
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
                (netpol.mkCallerIngressRule {
                  callerSelector = operator.operandSelectors.dbOps;
                  callerNamespace = ns;
                  ports = [ (tcp postgresPort) ];
                })
              ];
            };
          };
          # SGDbOps Job pods carry no cluster label, so this selects every
          # one in the namespace. They exec into the PostgreSQL pods through
          # the API server, and vacuum and benchmark connect to PostgreSQL.
          dbOpsEgress = kix.operandPolicy {
            inherit scope;
            name = "${name}-dbops-egress";
            spec = {
              endpointSelector.matchLabels = operator.operandSelectors.dbOps;
              egress = [
                netpol.dnsEgressRule
                netpol.apiServerEgressRule
                (netpol.mkServiceEgressRule {
                  selector = operandSelector;
                  namespace = ns;
                  sourceNamespace = ns;
                  ports = [ (tcp postgresPort) ];
                })
              ];
            };
          };
          # The Job of a manually created SGBackup runs the backup through
          # the API server, by exec into the primary.
          backupJobEgress = kix.operandPolicy {
            inherit scope;
            name = "${name}-backup-job-egress";
            spec = {
              endpointSelector.matchLabels = operator.operandSelectors.backup;
              egress = [
                netpol.dnsEgressRule
                netpol.apiServerEgressRule
              ];
            };
          };
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
              self.operandEgress
              self.operandIngress
              self.dbOpsEgress
              self.backupJobEgress
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
              ++ lib.optional poolingOn pg.images.pgbouncer
              ++ lib.optionals backupsOn operator.kubectlImages;
            };
          };
        }
      )
    )

    (import ./alerts.nix { inherit exporterOnFor; })
  ];
}
