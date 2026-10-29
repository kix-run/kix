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
# DI deps:
#   cnpgOperator (required)    Managed `cnpg-operator` instance.
#   storageClasses (optional)  StorageClass when `storage.storageClass` is null.
#   prometheus (optional)      PodMonitor and PrometheusRule alerts.
#   barmanCloud                `cnpg-barman-cloud` instance; required when
#                              `backup` is set.
#   storageCredentials         Secret or secret-ref in this namespace with S3
#                              access keys; required when `backup` is set.
#   endpointService (optional) In-cluster S3 Service when `backup` is set.
#
# Exposes (`root.out`, `root` = the `Cluster`):
#   out.name, out.fqdn, out.port  The `-rw` Service (port 5432).
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
        assertion = builtins.match "[0-9]+(\\.[0-9]+)?([-_].*)?" config.image.tag != null;
        message = "image.tag \"${config.image.tag}\" does not start with a PostgreSQL version. CloudNativePG reads the version from the tag and refuses `latest`; use a tag such as \"18.6-standard-trixie\".";
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
              parameters = {
                barmanObjectName = self.objectStore.out.name;
                inherit serverName;
              };
            }
          ];
        };

        _unownedPaths =
          if config.extraSpec ? imageCatalogRef then
            throw "${who}: extraSpec sets imageCatalogRef, and the package sets imageName from the image option. Set image instead."
          else if (config.extraSpec.affinity or { }) ? enablePodAntiAffinity then
            throw "${who}: extraSpec sets affinity.enablePodAntiAffinity, which the package sets to false: the pods spread by the topologySpreadConstraints derived from the availability level. Remove it, or set topologySpreadConstraints in extraSpec."
          else if backupOn && (config.extraSpec.backup or { }) ? barmanObjectStore then
            throw "${who}: extraSpec sets backup.barmanObjectStore while the backup option enables the Barman Cloud plugin as WAL archiver, and CloudNativePG refuses both on one Cluster. Remove backup.barmanObjectStore and configure the store through the backup option."
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
            self.podMonitor
            self.scheduledBackup
            self.backupEgress
            self.operandEgress
            self.operandIngress
            self.operatorEgress
            self.prometheusRules
          ];
          out = {
            inherit (postgresService.out) name fqdn port;
            clusterName = self.cluster.out.name;
            selector = instanceSelector;
            tls = true;
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      }
    )

    ./alerts.nix
  ];
}
