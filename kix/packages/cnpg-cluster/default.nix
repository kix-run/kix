# cnpg-cluster: a PostgreSQL cluster run by the CloudNativePG operator, as
# one postgresql.cnpg.io Cluster.
#
# The operator creates the instance pods and their claims, the -rw, -ro,
# and -r Services, and the Secrets of the `app` role and database that
# initdb creates. The package references the -rw Service, which selects the
# primary, so consumers wait for the Cluster and get network policy to the
# PostgreSQL pods. Apps should depend on a cnpg-database instance (alias
# `database`), which creates a role and database for them, rather than on
# this package.
#
# Minimal instance, with an operator elsewhere in the cluster:
#
#   instances.data.postgres.package = packages.cnpg-cluster;
#
# DI deps:
#   cnpgOperator (required)    a cnpg-operator instance; the package reads
#                              its CRD handle, release, and pod labels. An
#                              imported operator is refused.
#   storageClasses (optional)  the class of the data volumes when
#                              `storage.storageClass` is null.
#   prometheus (optional)      a PodMonitor for the instance manager's
#                              metrics (TCP 9187) while `metrics.enabled`.
#   barmanCloud                a cnpg-barman-cloud instance. Required
#                              while `backup` is set, and read only then.
#   storageCredentials         a secret or secret-ref in this namespace
#                              with the S3 access key ID and secret key
#                              (keys `accessKeyId` and `secretAccessKey`,
#                              or those `backup.credentialKeys` names), as
#                              stackgres-object-storage reads them.
#                              Required while `backup` is set.
#   endpointService (optional) an S3 store in the cluster, as an instance
#                              whose root is its S3 Service. Read only
#                              while `backup` is set: the package sets the
#                              ObjectStore's endpointURL to the Service's
#                              URL, and the instance pods get network
#                              policy to the store. No package has the
#                              alias, so wire it with
#                              deps.endpointService = ref.<ns>.<instance>.
#
# Defaults: `instances` from the availability level (1 at none, 2 at pod
# and node, 3 at zone), PostgreSQL 18 from the operand image, 1 CPU and 2Gi
# per instance as requests and limits, 20Gi volumes. PostgreSQL serves TLS
# with a certificate the operator issues.
#
# Placement: with more than one instance, the pods spread over nodes and
# zones as the availability level asks. CloudNativePG's own pod
# anti-affinity is off (`affinity.enablePodAntiAffinity = false`), so the
# spread is the only placement rule. The operator's PodDisruptionBudgets
# are on only with more than one instance: with one, the primary's budget
# would block every node drain.
#
# Network policy: with an enforcer, the package opens the pods' DNS, API
# server, and peer traffic, and the operator's access to the status port
# (TCP 8000) and PostgreSQL (TCP 5432), as upstream's
# docs/src/samples/networkpolicy-example.yaml does. Clients get ingress
# through the -rw Service reference.
#
# Backups: with `backup` set, the package builds an ObjectStore named
# `<instance>-backup` through the barmanCloud dependency, enables the
# plugin on the Cluster as its WAL archiver (`spec.plugins`), and adds a
# ScheduledBackup named after the instance that takes a base backup at
# `backup.schedule` and once right after it is created. The plugin's
# sidecar in each instance pod writes under `backup.destinationPath`, in a
# folder named after the Cluster, and deletes what falls outside
# `backup.retention`. Without endpointService, the instance pods may open
# connections outside the cluster on the port of
# `backup.extraSpec.configuration.endpointURL` (from its scheme when it
# names none), or on 443 when it is unset, as for AWS S3.
#
#   backup = {
#     destinationPath = "s3://pg-backups/main";
#     retention = "30d";
#   };
#
# Pooling: a cnpg-pooler instance runs PgBouncer in front of the -rw
# Service, and a cnpg-database that takes it as its postgres dependency
# hands consumers the pooler's address.
#
# Escape hatches: `extraSpec`, merged over the Cluster spec, and
# `backup.extraSpec`, merged over the ObjectStore spec. The fields the
# options own are refused (listed on each), and so is
# `monitoring.enablePodMonitor`, which has the operator create a PodMonitor
# outside Kix.
#
# Limits: the package ships no alerts. `backup` writes S3 credentials
# only; Azure and Google Cloud Storage are not modelled. Recovery from a
# backup into a new Cluster is not modelled.
#
# Exposes:
#   out.name, out.fqdn, out.port  the -rw Service (port 5432).
#   out.clusterName               the Cluster's name, for the `cluster`
#                                 reference of a Database or DatabaseRole.
#   out.selector                  the instance pods' labels.
#   out.tls                       true: PostgreSQL always serves TLS.
#   out.extraImages               the operand image.
#
# root = the Cluster.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cnpg-cluster ${ns}/${name}";

  # The Cluster fields this package writes are those of CloudNativePG 1.30.
  supportedRelease = "1.30";

  postgresPort = 5432;
  # The instance manager's status endpoint, which the operator calls
  # (pkg/management/url/url.go upstream).
  statusPort = 8000;
  metricsPort = 9187;

  # Cluster spec paths the options own. `plugins` is added while `backup`
  # is set.
  locked = [
    [ "instances" ]
    [ "imageName" ]
    [ "resources" ]
    [
      "storage"
      "size"
    ]
    [
      "storage"
      "storageClass"
    ]
  ];

  # CloudNativePG parses a schedule with robfig/cron's Parse, which takes
  # six fields with seconds first and reads a five-field expression as one
  # with no day-of-week field (internal/webhook/v1/scheduledbackup_webhook.go
  # upstream).
  scheduleFields =
    schedule: builtins.length (builtins.filter builtins.isString (builtins.split "[[:space:]]+" (lib.trim schedule)));
  scheduleOk = schedule: lib.hasPrefix "@" schedule || scheduleFields schedule == 6;

  # The S3 credential selectors every ObjectStore names. Each reads the
  # Secret key of its own name unless backup.credentialKeys names another;
  # `region` is added only when backup.credentialKeys.region is set.
  credentialSelectors = [
    "accessKeyId"
    "secretAccessKey"
  ];

  # The port of an http or https URL: the explicit one, else the scheme's.
  urlPort =
    url:
    let
      m = builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?" url;
    in
    if m == null then
      throw "${who}: backup.extraSpec.configuration.endpointURL \"${url}\" is not an http or https URL, so the package cannot tell which port the store listens on. Write it as https://<host>[:<port>]."
    else if builtins.elemAt m 3 != null then
      lib.toInt (builtins.elemAt m 3)
    else if builtins.elemAt m 0 == "https" then
      443
    else
      80;
in
{
  meta = {
    description = "PostgreSQL cluster run by the CloudNativePG operator (Cluster)";
    owner = "platform";
    defaultAliases = [ "postgres" ];
    lifecycle = "stateful";
  };

  assertions =
    { config, ... }:
    [
      {
        assertion =
          builtins.stringLength name <= 50 && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
        message = "CloudNativePG requires a Cluster name of at most 50 characters that is a DNS-1035 label (^[a-z]([-a-z0-9]*[a-z0-9])?$); \"${name}\" is ${toString (builtins.stringLength name)} characters. Rename the instance.";
      }
      {
        # The operator reads the PostgreSQL version from the tag
        # (validateImageName in internal/webhook/v1/cluster_webhook.go).
        assertion = builtins.match "[0-9]+(\\.[0-9]+)?([-_].*)?" config.image.tag != null;
        message = "image.tag \"${config.image.tag}\" does not start with a PostgreSQL version. CloudNativePG reads the version from the tag and refuses `latest`; use a tag such as \"18.6-standard-trixie\".";
      }
      {
        assertion = config.backup == null || scheduleOk config.backup.schedule;
        message = "backup.schedule \"${config.backup.schedule}\" has ${toString (scheduleFields config.backup.schedule)} fields. CloudNativePG reads six cron fields with seconds first and reads a five-field crontab as one without a day-of-week field, so it would run at other times than a crontab does. Add the seconds field (\"0 0 2 * * *\" for 02:00 every day), or use a descriptor such as \"@daily\".";
      }
      {
        assertion = !((config.extraSpec.monitoring or { }) ? enablePodMonitor);
        message = "extraSpec sets monitoring.enablePodMonitor, which has the operator create a PodMonitor that Kix does not track. Set metrics.enabled and wire a prometheus dependency instead.";
      }
    ];

  # An imported operator has no out.release; the build refuses it first.
  deps.cnpgOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the Cluster fields of CloudNativePG ${supportedRelease}, and the cnpgOperator dependency runs ${dep.out.release}. Update kix/packages/cnpg-cluster for that release.";
    }
  ];

  options = {
    instances = lib.mkOption {
      type = lib.types.ints.positive;
      # One instance cannot survive its own pod's restart, so `pod` needs a
      # second; three at `zone` keep a quorum of replicas through a zone
      # loss.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 3;
      };
      defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }";
      description = "PostgreSQL instances (`spec.instances`): one primary, the rest streaming replicas the operator fails over to.";
    };

    image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/postgresql";
      tag = "18.6-standard-trixie";
      digest = "sha256:f89a40f4d74aa6e0900917eaf6299b125a6382eb02fd4ee5d46f55bcbf7e5726";
      description = "PostgreSQL operand image (`spec.imageName`). The tag must start with the PostgreSQL version, which the operator reads from it. The `standard` images carry the contrib extensions, pgvector, pgaudit, and pg_failover_slots. Changing the major runs the operator's offline major upgrade.";
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

    metrics = kix.options.monitor;

    backup = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            destinationPath = lib.mkOption {
              type = lib.types.strMatching "s3://[^/]+(/.*)?";
              example = "s3://pg-backups/main";
              description = "Where WAL and base backups go, as `s3://<bucket>[/<prefix>]` (the ObjectStore's `configuration.destinationPath`). The bucket must exist. The plugin writes under a folder named after the Cluster, so clusters may share a path.";
            };
            schedule = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "0 0 0 * * *";
              description = "When to take a base backup (the ScheduledBackup's `spec.schedule`): six cron fields with seconds first, or a descriptor such as `@daily` or `@every 12h`. A five-field crontab is refused. The default is midnight every day.";
            };
            retention = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[1-9][0-9]*[dwm]");
              default = null;
              example = "30d";
              description = "How far back the backups reach (the ObjectStore's `retentionPolicy`): a number followed by `d`, `w`, or `m`. The sidecar deletes the base backups and WAL that are no longer needed to recover to a point in that window. Null keeps everything.";
            };
            credentialKeys =
              lib.genAttrs credentialSelectors (
                s:
                lib.mkOption {
                  type = lib.types.nullOr lib.types.nonEmptyStr;
                  default = null;
                  description = "Key of the storageCredentials Secret holding `${s}`; null reads the key `${s}`.";
                }
              )
              // {
                region = lib.mkOption {
                  type = lib.types.nullOr lib.types.nonEmptyStr;
                  default = null;
                  description = "Key of the storageCredentials Secret holding the S3 region. Null sets no region.";
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
                Merged over the ObjectStore spec: `configuration.endpointURL`
                for a store other than AWS S3, `configuration.endpointCA`,
                `configuration.wal`, `configuration.data`, and
                `instanceSidecarConfiguration`. Refused:
                `configuration.destinationPath`,
                `configuration.s3Credentials`, `retentionPolicy`, and, with
                an endpointService dependency, `configuration.endpointURL`.
                A Secret selector must name a secret dependency's Secret.
              '';
            };
          };
        }
      );
      default = null;
      description = ''
        WAL archiving and scheduled base backups to S3 through the Barman
        Cloud plugin. Non-null needs the barmanCloud and storageCredentials
        dependencies. Null takes no backups.
      '';
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        postgresql.parameters.max_connections = "200";
      };
      description = ''
        Merged over the Cluster spec. Refused: `instances`, `imageName`,
        `imageCatalogRef`, `resources`, `storage.size`,
        `storage.storageClass`, `affinity.enablePodAntiAffinity`,
        `monitoring.enablePodMonitor`, and, while `backup` is set,
        `plugins`. `topologySpreadConstraints` replaces
        the spread the package derives from the availability level, and
        `enablePDB` the package's choice.
      '';
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      cnpgOperator,
      storageClasses ? null,
      prometheus ? null,
      barmanCloud ? null,
      storageCredentials ? null,
      endpointService ? null,
      ...
    }:
    let
      operator =
        if cnpgOperator.out ? operandSelectors then
          cnpgOperator.out
        else
          throw "${who}: the cnpgOperator dependency has no out.operandSelectors, as with an import. This package reads the operator's CRD handle and pod labels from it. Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";
      crds = operator.crds;

      operandSelector = operator.operandSelectors.cluster name;
      # The instance pods, without the Cluster's Job pods.
      instanceSelector = operandSelector // {
        "cnpg.io/podRole" = "instance";
      };

      storageClass =
        if config.storage.storageClass != null then
          config.storage.storageClass
        else if storageClasses != null then
          storageClasses.out.storageClassName
        else
          null;

      spread = lib.optionals (config.instances > 1) (
        kix.availability.spreadConstraints {
          level = availability;
          selector = instanceSelector;
          topology = clusterConfig.cluster.topology;
        }
      );

      quantity = q: if builtins.isString q then q else toString q;

      backupOn = config.backup != null;
      bk = config.backup;
      plugin =
        if barmanCloud == null then
          throw "${who}: backup is set and no barmanCloud dependency resolved. Add a cnpg-barman-cloud instance in the operator's namespace, or set backup = null."
        else if !(barmanCloud.out ? mkObjectStore) then
          throw "${who}: the barmanCloud dependency has no out.mkObjectStore, as with an import. Wire a cnpg-barman-cloud instance with deps.barmanCloud = ref.<namespace>.<instance>."
        else
          barmanCloud.out;

      credentialKeys =
        lib.genAttrs credentialSelectors (s: if bk.credentialKeys.${s} != null then bk.credentialKeys.${s} else s)
        // lib.optionalAttrs (bk.credentialKeys.region != null) { region = bk.credentialKeys.region; };
      credentials = kix.checkSecretKeys {
        inherit who;
        arg = "storageCredentials";
        dep =
          if storageCredentials == null then
            throw "${who}: backup is set and no storageCredentials dependency resolved in namespace ${ns}. Add a secret or secret-ref instance there with the keys ${lib.concatStringsSep " and " (builtins.attrValues credentialKeys)} and the alias storageCredentials, or set backup = null."
          else
            storageCredentials;
        keys = builtins.attrValues credentialKeys;
      };

      inClusterStore = endpointService != null;
      objectStoreSpec = kix.mergeGuarded {
        inherit who;
        what = "backup.extraSpec";
        locked = [
          [
            "configuration"
            "destinationPath"
          ]
          [
            "configuration"
            "s3Credentials"
          ]
          [ "retentionPolicy" ]
        ]
        ++ lib.optional inClusterStore [
          "configuration"
          "endpointURL"
        ];
      } objectStoreBase bk.extraSpec;
      objectStoreBase = {
        configuration = {
          inherit (bk) destinationPath;
          s3Credentials = lib.mapAttrs (_: key: (credentials.out.keyRef key).valueFrom.secretKeyRef) credentialKeys;
        }
        // lib.optionalAttrs inClusterStore {
          endpointURL =
            (endpointService.out.url
              or (throw "${who}: deps.endpointService has no out.url. Wire an instance whose root is its S3 Service.")
            )
              { };
        };
      }
      // lib.optionalAttrs (bk.retention != null) { retentionPolicy = bk.retention; };

      # The store's port outside the cluster; null for an in-cluster store,
      # whose address reaches the instance pods through the Cluster.
      storeWorldPort =
        if inClusterStore then
          null
        else if objectStoreSpec.configuration ? endpointURL then
          urlPort objectStoreSpec.configuration.endpointURL
        else
          443;

      baseSpec = {
        inherit (config) instances resources;
        imageName = kix.image.ref config.image;
        storage = {
          size = quantity config.storage.size;
        }
        // lib.optionalAttrs (storageClass != null) { inherit storageClass; };
        affinity.enablePodAntiAffinity = false;
        enablePDB = config.instances > 1;
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (spread != [ ]) {
        topologySpreadConstraints = spread;
      }
      // lib.optionalAttrs backupOn {
        plugins = [
          {
            name = plugin.pluginName;
            isWALArchiver = true;
            parameters.barmanObjectName = self.objectStore.out.name;
          }
        ];
      };

      # Paths the package sets that no option owns.
      _unownedPaths =
        if config.extraSpec ? imageCatalogRef then
          throw "${who}: extraSpec sets imageCatalogRef, and the package sets imageName from the image option. Set image instead."
        else if (config.extraSpec.affinity or { }) ? enablePodAntiAffinity then
          throw "${who}: extraSpec sets affinity.enablePodAntiAffinity, which the package sets to false: the pods spread by the topologySpreadConstraints derived from the availability level. Remove it, or set topologySpreadConstraints in extraSpec."
        else
          null;

      spec = builtins.seq _unownedPaths (
        kix.mergeGuarded {
          inherit who;
          locked = locked ++ lib.optional backupOn [ "plugins" ];
        } baseSpec config.extraSpec
      );

      postgresService = scope.mkServiceRef {
        name = "${name}-rw";
        selector = instanceSelector;
        ports = [
          {
            port = postgresPort;
            protocol = "TCP";
          }
        ];
        requires = [ self.cluster ];
      };

      # Read only when the scope has an enforcer (kix.operandPolicy).
      netpol = scope.networkPolicyEnforcer.netpol;
      tcp = port: {
        inherit port;
        protocol = "TCP";
      };
      operatorPorts = map tcp [
        statusPort
        postgresPort
      ];
      operatorNamespace = (scope.forService cnpgOperator).namespaceName;
      self' = netpol.mkSelfRules { selector = operandSelector; };
    in
    {
      inherit postgresService;

      cluster = scope.mkCR crds.Cluster {
        inherit name spec;
        # `kix.mkImport { from = packages.cnpg-cluster; }` takes its out
        # from this resource, without the operator dependency that
        # postgresService needs.
        outputs.port = toString postgresPort;
      };

      objectStore =
        if backupOn then
          plugin.mkObjectStore scope {
            name = "${name}-backup";
            spec = objectStoreSpec;
          }
        else
          null;

      # With backupOwnerReference `self`, the ScheduledBackup owns each
      # Backup object it creates, and Kubernetes deletes them with it.
      # `immediate` takes the first base backup when the ScheduledBackup is
      # created, so the archived WAL has a base to replay onto from the
      # start.
      scheduledBackup =
        if backupOn then
          scope.mkCR crds.ScheduledBackup {
            inherit name;
            spec = {
              cluster.name = self.cluster.out.name;
              inherit (bk) schedule;
              method = "plugin";
              pluginConfiguration.name = plugin.pluginName;
              backupOwnerReference = "self";
              immediate = true;
            };
          }
        else
          null;

      # The plugin's sidecar in each instance pod writes to the store.
      backupEgress =
        if backupOn && storeWorldPort != null then
          kix.operandPolicy {
            inherit scope;
            name = "${name}-backup-egress";
            spec = {
              endpointSelector.matchLabels = instanceSelector;
              egress =
                (netpol.translateIntentRules {
                  intents.store.egress = [
                    {
                      to = "world";
                      ports = [ (tcp storeWorldPort) ];
                    }
                  ];
                }).egressRules;
            };
          }
        else
          null;

      podMonitor =
        if config.metrics.enabled && prometheus != null then
          prometheus.out.mkPodMonitor scope {
            inherit name;
            spec = {
              selector.matchLabels = instanceSelector;
              podMetricsEndpoints = [
                (
                  {
                    # The instance manager's exporter (port name
                    # `metrics`). The scrape egress rule needs the number,
                    # because Kix does not see the operator's pods.
                    portNumber = metricsPort;
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
          ++ self'.egress;
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
              ports = operatorPorts;
            })
          ];
        };
      };
      # The other end of the operator rule, in the operator's namespace.
      operatorEgress = kix.operandPolicy {
        scope = scope.forService cnpgOperator;
        name = "${ns}-${name}-operator-egress";
        spec = {
          endpointSelector.matchLabels = operator.podSelector;
          egress = [
            (netpol.mkServiceEgressRule {
              selector = operandSelector;
              namespace = ns;
              sourceNamespace = operatorNamespace;
              ports = operatorPorts;
            })
          ];
        };
      };

      root = {
        resource = self.cluster;
        requires = [
          self.postgresService
        ]
        ++ builtins.filter (r: r != null) [
          self.podMonitor
          self.scheduledBackup
          self.backupEgress
          self.operandEgress
          self.operandIngress
          self.operatorEgress
        ];
        out = {
          inherit (postgresService.out) name fqdn port;
          clusterName = self.cluster.out.name;
          selector = instanceSelector;
          tls = true;
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}
