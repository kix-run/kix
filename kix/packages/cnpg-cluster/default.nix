# cnpg-cluster: a PostgreSQL cluster run by the CloudNativePG operator, as
# one postgresql.cnpg.io Cluster.
#
# The operator creates the instance pods and their claims, the `-rw`, `-ro`,
# and `-r` Services, and the Secrets of the `app` role and database. The
# package references the `-rw` Service so consumers wait for the Cluster and
# get network policy to the PostgreSQL pods. Apps should depend on a
# `cnpg-database` instance (alias `database`) rather than directly on this
# package.
#
#   instances.data.postgres.package = packages.cnpg-cluster;
#
# Dependencies:
#   cnpgOperator (required)    Managed `cnpg-operator` instance.
#   storageClasses (optional)  StorageClass when `storage.storageClass` is null.
#   prometheus (optional)      PodMonitor and PrometheusRule alerts.
#   barmanCloud                `cnpg-barman-cloud` instance; required when
#                              `backup` is set.
#   storageCredentials         Secret or secret-ref in this namespace with S3
#                              access keys; required when `backup` is set.
#   endpointService (optional) In-cluster S3 Service when `backup` is set.
#   importSource               The server to copy from, as an instance with
#                              out.fqdn and out.port, such as a cnpg-cluster
#                              or a service-ref; required when `import` is
#                              set. A source whose out.tls is false needs an
#                              `import.sslMode` that does not require TLS.
#   importPassword             Secret or secret-ref in this namespace holding
#                              the password of `import.user` under
#                              `import.passwordKey`; required when `import` is
#                              set.
#   importCa (optional)        Secret or secret-ref in this namespace with
#                              `ca.crt`, the CA that signed the source's
#                              certificate. Required when `import.sslMode` is
#                              verify-ca or verify-full.
#
# Import: with `import` set, the Cluster names the source in
# `externalClusters` and copies `import.databases` from it when it is
# created. A Cluster that exists already copies nothing, so a later change
# to `import` changes nothing in its data. The operator makes the copy in a
# Job before the primary starts. The instance and Job pods get egress to
# the source's pods on its port, and the source's pods admit them. Once the
# Cluster exists, set `import` back to null and remove the import
# dependencies. CloudNativePG accepts the change and keeps the data. The
# deploy then keeps the two import policies as orphans, so close the path
# with `kix deploy --prune` or `kix gc`. A large database can take longer
# to copy than the deploy waits for the Cluster to be ready. Run the deploy
# again once the Cluster is ready.
#
# Exposes (`root.out`, `root` = the `Cluster`):
#   out.name, out.fqdn, out.port  The `-rw` Service (port 5432).
#   out.version                   PostgreSQL major version, read from the image tag.
#   out.clusterName               The Cluster's name.
#   out.selector                  Instance pod labels.
#   out.tls                       true (PostgreSQL always serves TLS).
#   out.extraImages               The operand image.

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

  supportedRelease = "1.30";

  postgresPort = 5432;
  statusPort = 8000;
  metricsPort = 9187;

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

  scheduleFields =
    schedule:
    builtins.length (
      builtins.filter builtins.isString (builtins.split "[[:space:]]+" (lib.trim schedule))
    );
  descriptorOk =
    schedule:
    builtins.match "@(yearly|annually|monthly|weekly|daily|midnight|hourly)" schedule != null
    || builtins.match "@every ([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+" schedule != null;
  scheduleOk =
    schedule:
    if lib.hasPrefix "@" schedule then descriptorOk schedule else scheduleFields schedule == 6;

  podMonitorName = name;

  credentialSelectors = [
    "accessKeyId"
    "secretAccessKey"
  ];

  matchUrl = builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?";

  urlHostInCluster =
    clusterDomain: url:
    let
      m = matchUrl url;
      host = lib.toLower (lib.removeSuffix "." (builtins.elemAt m 1));
    in
    m != null && (lib.hasSuffix ".svc" host || lib.hasSuffix ".svc.${lib.toLower clusterDomain}" host);

  urlPort =
    url:
    let
      m = matchUrl url;
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
        assertion =
          let
            imageTag = builtins.unsafeDiscardStringContext config.image.tag;
          in
          builtins.match "[0-9]+(\\.[0-9]+)?([-_].*)?" imageTag != null;
        message = "image.tag \"${builtins.unsafeDiscardStringContext config.image.tag}\" does not start with a PostgreSQL version. CloudNativePG reads the version from the tag and refuses `latest`; use a tag such as \"18.6-standard-trixie\".";
      }
      {
        assertion =
          config.backup == null
          || !lib.hasPrefix "@" config.backup.schedule
          || scheduleOk config.backup.schedule;
        message = "backup.schedule \"${config.backup.schedule}\" is not a descriptor CloudNativePG accepts. Use @yearly, @annually, @monthly, @weekly, @daily, @midnight, @hourly, or @every followed by a duration such as 12h or 1h30m.";
      }
      {
        assertion =
          config.backup == null
          || lib.hasPrefix "@" config.backup.schedule
          || scheduleOk config.backup.schedule;
        message = "backup.schedule \"${config.backup.schedule}\" has ${toString (scheduleFields config.backup.schedule)} fields. CloudNativePG reads six cron fields with seconds first and reads a five-field crontab as one without a day-of-week field, so it would run at other times than a crontab does. Add the seconds field (\"0 0 2 * * *\" for 02:00 every day), or use a descriptor such as \"@daily\".";
      }
      {
        assertion =
          config.import == null
          || config.import.type == "monolith"
          || (
            builtins.length config.import.databases == 1
            && !(lib.hasInfix "*" (builtins.head config.import.databases))
          );
        message = "import.databases is ${builtins.toJSON config.import.databases}. A microservice import copies exactly one named database into the application database. List one, or set import.type = \"monolith\" to copy several.";
      }
      {
        assertion =
          config.import == null
          || config.import.type == "microservice"
          || (
            (config.import.databases == [ "*" ] || !(builtins.elem "*" config.import.databases))
            && (config.import.roles == [ "*" ] || !(builtins.elem "*" config.import.roles))
          );
        message = "import.databases or import.roles lists `*` beside names. `*` copies every database or every role, so give it alone or list names.";
      }
      {
        assertion =
          config.import == null
          || config.import.type == "microservice"
          || !(config.import.extraSpec ? postImportApplicationSQL);
        message = "import.extraSpec sets postImportApplicationSQL on a monolith import, and CloudNativePG runs it after a microservice import only. Remove it, or run the statements another way.";
      }
      {
        assertion = config.import == null || config.import.type == "monolith" || config.import.roles == [ ];
        message = "import.roles is set, and a microservice import copies no roles. Remove import.roles, or set import.type = \"monolith\".";
      }
      {
        assertion =
          config.import == null
          || !(
            (config.extraSpec.bootstrap or { }) ? recovery
            || (config.extraSpec.bootstrap or { }) ? pg_basebackup
          );
        message = "extraSpec sets bootstrap.recovery or bootstrap.pg_basebackup while import is set, and a Cluster bootstraps one way. Remove one of them.";
      }
      {
        assertion = !((config.extraSpec.monitoring or { }) ? enablePodMonitor);
        message = "extraSpec sets monitoring.enablePodMonitor, which has the operator create a PodMonitor that Kix does not track. Set metrics.enabled and wire a prometheus dependency instead.";
      }
    ];

  deps.cnpgOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the Cluster fields of CloudNativePG ${supportedRelease}, and the cnpgOperator dependency runs ${dep.out.release}. Update kix/packages/cnpg-cluster for that release.";
    }
  ];

  options = import ./options.nix {
    inherit
      lib
      kix
      availability
      credentialSelectors
      ;
  };

  build = [
    (
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
        importSource ? null,
        importPassword ? null,
        importCa ? null,
        ...
      }:
      let
        operator =
          if cnpgOperator.out ? operandSelectors then
            cnpgOperator.out
          else
            throw "${who}: the cnpgOperator dependency has no out.operandSelectors, as with an import. This package reads the operator's CRD handle and pod labels from it. Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";
        crds = operator.crds;

        # Null when the tag carries no version, so the assertion on the tag
        # reports it instead of a match error here. The context is dropped
        # so the record does not depend on the image pin.
        postgresMajor =
          let
            m = builtins.match "([0-9]+).*" (builtins.unsafeDiscardStringContext config.image.tag);
          in
          if m == null then null else builtins.head m;

        operandSelector = operator.operandSelectors.cluster name;
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

        # At `node`, no two instances share a node. The spread alone does not
        # hold that for a new instance: CloudNativePG first runs a join job,
        # whose pod lacks the `cnpg.io/podRole=instance` label the spread
        # counts, so the job can land beside an instance. On node-local
        # storage the claim binds where the job ran, and the instance can
        # then never schedule. CloudNativePG gives its job pods the Cluster's
        # affinity, so required anti-affinity on the instance labels keeps
        # the job off those nodes too. Below `node`, instances may share a
        # node; at `zone`, several may share a zone.
        separateNodes = config.instances > 1 && availability == "node";

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
          lib.genAttrs credentialSelectors (
            s: if bk.credentialKeys.${s} != null then bk.credentialKeys.${s} else s
          )
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
            s3Credentials = lib.mapAttrs (
              _: key: (credentials.out.keyRef key).valueFrom.secretKeyRef
            ) credentialKeys;
          }
          // lib.optionalAttrs inClusterStore {
            endpointURL =
              (endpointService.out.url
                or (throw "${who}: deps.endpointService has no out.url. Wire an instance whose root is its S3 Service.")
              )
                { scheme = if bk.endpointScheme != null then bk.endpointScheme else "http"; };
          };
        }
        // lib.optionalAttrs (bk.retention != null) { retentionPolicy = bk.retention; };

        serverName = if bk.serverName != null then bk.serverName else "${ns}-${name}";

        _endpointScheme =
          if !inClusterStore && bk.endpointScheme != null then
            throw "${who}: backup.endpointScheme is set and no endpointService dependency resolved, so nothing reads it. Wire the in-cluster store with deps.endpointService = ref.<namespace>.<instance>, or remove backup.endpointScheme and give the scheme in backup.extraSpec.configuration.endpointURL."
          else
            null;

        storeWorldPort =
          if inClusterStore then
            null
          else if objectStoreSpec.configuration ? endpointURL then
            let
              url = objectStoreSpec.configuration.endpointURL;
            in
            if urlHostInCluster clusterConfig.clusterDomain url then
              throw "${who}: backup.extraSpec.configuration.endpointURL \"${url}\" names a Service in the cluster, and the instance pods get network policy only to stores outside it. Wire the store with deps.endpointService = ref.<namespace>.<instance> and remove endpointURL; set backup.endpointScheme = \"https\" if it serves TLS."
            else
              urlPort url
          else
            443;

        importOn = config.import != null;
        im = config.import;
        importSourceName = "import-source";
        source =
          if importSource == null then
            throw "${who}: import is set and no importSource dependency resolved. Wire the server to copy from with deps.importSource = ref.<namespace>.<instance>. For a server Kix does not manage, add a service-ref instance for its Service."
          else if !(importSource.out ? fqdn && importSource.out ? port) then
            throw "${who}: the importSource dependency has no out.fqdn and out.port, so the package cannot tell where the source listens. Wire a cnpg-cluster, a stackgres-cluster, or a service-ref instance."
          else if (importSource.out.tls or null) == false && builtins.elem im.sslMode tlsModes then
            throw "${who}: import.sslMode is ${im.sslMode}, which needs TLS, and the importSource dependency serves none (out.tls is false). Turn on TLS at the source, or set import.sslMode = \"disable\"."
          else
            importSource.out;
        tlsModes = [
          "require"
          "verify-ca"
          "verify-full"
        ];
        importCredentials = kix.checkSecretKeys {
          inherit who;
          arg = "importPassword";
          dep =
            if importPassword == null then
              throw "${who}: import is set and no importPassword dependency resolved in namespace ${ns}. Add a secret or secret-ref instance there with the key ${im.passwordKey} and wire it with deps.importPassword = ref.${ns}.<instance>."
            else
              importPassword;
          keys = [ im.passwordKey ];
        };
        verifiesSource = builtins.elem im.sslMode [
          "verify-ca"
          "verify-full"
        ];
        importCaRef =
          if importCa == null then
            if verifiesSource then
              throw "${who}: import.sslMode is ${im.sslMode}, which checks the source's certificate, and no importCa dependency resolved. Wire a secret with ca.crt, the CA that signed the source's certificate, with deps.importCa = ref.${ns}.<instance>, or set import.sslMode = \"require\" to encrypt without checking."
            else
              null
          else if !verifiesSource then
            throw "${who}: the importCa dependency is wired and import.sslMode is ${im.sslMode}, which does not check the source's certificate. Set import.sslMode = \"verify-full\", or remove deps.importCa."
          else
            (
              (kix.checkSecretKeys {
                inherit who;
                arg = "importCa";
                dep = importCa;
                keys = [ "ca.crt" ];
              }).out.keyRef
              "ca.crt"
            ).valueFrom.secretKeyRef;
        importSpec = kix.mergeGuarded {
          inherit who;
          what = "import.extraSpec";
          locked = [
            [ "type" ]
            [ "databases" ]
            [ "roles" ]
            [ "source" ]
          ];
        } importBase im.extraSpec;
        importBase = {
          inherit (im) type databases;
          source.externalCluster = importSourceName;
        }
        // lib.optionalAttrs (im.roles != [ ]) { inherit (im) roles; };
        importSourceCluster = {
          name = importSourceName;
          connectionParameters = {
            host = source.fqdn;
            port = toString source.port;
            inherit (im) user;
            dbname = im.sourceDatabase;
            sslmode = im.sslMode;
          };
          password = (importCredentials.out.keyRef im.passwordKey).valueFrom.secretKeyRef;
        }
        // lib.optionalAttrs (importCaRef != null) { sslRootCert = importCaRef; };

        baseSpec = {
          inherit (config) instances resources;
          imageName = kix.image.ref config.image;
          storage = {
            size = quantity config.storage.size;
          }
          // lib.optionalAttrs (storageClass != null) { inherit storageClass; };
          affinity = {
            enablePodAntiAffinity = false;
          }
          // lib.optionalAttrs separateNodes {
            additionalPodAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector.matchLabels = instanceSelector;
                topologyKey = clusterConfig.cluster.topology.hostKey;
              }
            ];
          };
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
              parameters = {
                barmanObjectName = self.objectStore.out.name;
                inherit serverName;
              };
            }
          ];
        }
        // lib.optionalAttrs importOn {
          bootstrap.initdb.import = importSpec;
          externalClusters = [ importSourceCluster ];
        };

        _unownedPaths =
          if config.extraSpec ? imageCatalogRef then
            throw "${who}: extraSpec sets imageCatalogRef, and the package sets imageName from the image option. Set image instead."
          else if (config.extraSpec.affinity or { }) ? enablePodAntiAffinity then
            throw "${who}: extraSpec sets affinity.enablePodAntiAffinity, which the package sets to false: the pods spread by the topologySpreadConstraints derived from the availability level. Remove it, or set topologySpreadConstraints in extraSpec."
          else if !importOn && (importSource != null || importPassword != null || importCa != null) then
            throw "${who}: an importSource, importPassword, or importCa dependency is wired and import is null, so nothing reads it. Set import, or remove the import dependencies."
          else if backupOn && (config.extraSpec.backup or { }) ? barmanObjectStore then
            throw "${who}: extraSpec sets backup.barmanObjectStore while the backup option enables the Barman Cloud plugin as WAL archiver, and CloudNativePG refuses both on one Cluster. Remove backup.barmanObjectStore and configure the store through the backup option."
          else
            null;

        spec = builtins.seq _unownedPaths (
          kix.mergeGuarded {
            inherit who;
            locked =
              locked
              ++ lib.optional backupOn [ "plugins" ]
              ++ [
                [
                  "bootstrap"
                  "initdb"
                  "import"
                ]
              ]
              ++ lib.optional importOn [ "externalClusters" ];
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
          outputs.port = toString postgresPort;
        };

        objectStore =
          if backupOn then
            builtins.seq _endpointScheme (
              plugin.mkObjectStore scope {
                name = "${name}-backup";
                spec = objectStoreSpec;
              }
            )
          else
            null;

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
              name = podMonitorName;
              spec = {
                selector.matchLabels = instanceSelector;
                podMetricsEndpoints = [
                  (
                    {
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
          }
          // lib.optionalAttrs (postgresMajor != null) { version = postgresMajor; };
        };
      }
    )

    ./alerts.nix
  ];
}
