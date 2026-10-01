# velero: the Velero server Deployment and node-agent DaemonSet, the
# `default` BackupStorageLocation, an optional VolumeSnapshotLocation,
# Schedules, and global volume policies, with the 13 velero.io CRDs vendored
# under ./crds (scripts/vendor-crds.py, `crds/sources.txt`).
#
#   instances.velero = {
#     velero-credentials = {         # an AWS credentials file in key `cloud`
#       package = packages.secret-ref;
#       aliases = [ "cloudCredentials" ];
#       config.keys = [ "cloud" ];
#     };
#     velero-repo-credentials = {    # the kopia repository key
#       package = packages.secret-ref;
#       aliases = [ "repositoryPassword" ];
#       config.keys = [ "repository-password" ];
#     };
#     velero = {
#       package = packages.velero;
#       config.backupStorageLocation = {
#         objectStorage.bucket = "my-cluster-backups";
#         config.region = "us-east-1";
#       };
#       config.schedules.daily.schedule = "CRON_TZ=UTC 0 2 * * *";
#     };
#   };
#
# One instance per cluster (`meta.conflictsWith`): the CRDs, the
# cluster-admin binding, and the node-agent DaemonSet are cluster singletons.
# Velero finds its own workloads by fixed names in its namespace, so they
# keep them whatever the instance is called: repository maintenance copies
# the Deployment named `velero`, and the data path reads the DaemonSet named
# `node-agent`.
#
# Since 1.17, node-agent runs file-system backups, restores, and the CSI data
# mover in pods it creates in Velero's namespace, and the server runs kopia
# maintenance as Jobs there. Kix renders none of these pods, so their labels
# come from the two ConfigMaps below (`podLabels`) and their traffic from the
# `dataPathEgress` and `externalStoreEgress` policies.
#
# DI deps:
#   cloudCredentials (required)  a secret or secret-ref with key `cloud`, the
#                                object-store credentials file, mounted at
#                                /credentials and named by the locations.
#   repositoryPassword           a secret or secret-ref named
#                                velero-repo-credentials with key
#                                `repository-password`, the kopia repository
#                                key. Required while node-agent is on.
#   objectStorage (optional)     an in-cluster S3 store whose root is its
#                                Service. It sets the location's `s3Url`,
#                                which the instance may then not set.
#   prometheus (optional)        metrics Services, ServiceMonitors, and the
#                                backup alerts.
#
# Exposes:
#   out.crds.<Kind>              the 13 CRDs. Velero reads its CRs only in
#                                its own namespace, so build one there:
#                                (scope.forService velero).mkCR
#                                  velero.out.crds.Restore { ... }.
#   out.mkBackup scope { name; spec; requires ? [ ]; }
#   out.mkSchedule scope { name; spec; requires ? [ ]; }
#       Build the CR in Velero's namespace, waiting for an Available location.
#       A Backup runs once: Velero deletes the CR when its `ttl` expires
#       (720h unless set), and the next deploy creates it again, which runs a
#       new backup under the same name. A Backup that ends Failed or
#       PartiallyFailed never reaches Completed, so the deploy waits until its
#       timeout. A Schedule is the durable form.
#
# Escape hatches: the location, snapshot location, and schedule options pass
# unknown keys through to their CR spec; `server.extraArgs`,
# `nodeAgent.extraArgs`, `server.env`, and `nodeAgent.env` reach the
# containers; `nodeAgent.settings` and `repositoryMaintenance.settings` are
# Velero's own configuration; `extraPlugins` adds plugin images; instance
# `partsOverlays` covers the rest.
#
# Known limits:
# - `cloudCredentials` is a credentials file. A cloud identity (EKS IRSA,
#   Azure workload identity) needs a profile in that file and a
#   ServiceAccount annotation added with `partsOverlays`.
# - Without an `objectStorage` dependency, Velero's pods may open
#   connections to any address outside the cluster on the store's port (from
#   `s3Url`, else 443), and on 443 when a snapshot location is set. A second
#   location on another port needs its own network policy.
# - The namespace gets the `privileged` Pod Security level even with
#   node-agent off, because `meta` cannot read config.
#
# root = the server Deployment, waiting for the location.

{
  scope,
  lib,
  kix,
}:

let
  # meta.version and image.tag read this; crds/sources.txt names the same tag.
  release = "v1.18.4";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "velero ${ns}/${name}";

  # The port of an http or https URL: the explicit one, else the scheme's.
  urlPort =
    url:
    let
      m = builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?" url;
    in
    if m == null then
      throw (
        "${who}: backupStorageLocation.config.s3Url \"${url}\" is not an http or https URL, so the "
        + "package cannot tell which port the store listens on. Write it as https://<host>[:<port>]."
      )
    else if builtins.elemAt m 3 != null then
      lib.toInt (builtins.elemAt m 3)
    else if builtins.elemAt m 0 == "https" then
      443
    else
      80;

  # Each workload, and each metrics Service, carries its own component, so
  # no selector claims another component's pods and a ServiceMonitor built
  # from one Service's labels selects only that Service.
  componentLabels = component: { "app.kubernetes.io/component" = component; };

  # Labels of the pods Velero creates itself (file-system backup and restore,
  # data mover, repository maintenance). They carry the instance's selector
  # labels, so the location's and the external store's policies reach them.
  dataPathLabels = scope.selectorLabels // componentLabels "data-path";

  metricsPort = 8085;

  # The CRDs come from `release`; a server of another minor release may not
  # serve the same schema.
  releaseMinor = builtins.match "v([0-9]+)\\.([0-9]+)\\..*" release;
  checkedRef =
    image:
    if builtins.match "v([0-9]+)\\.([0-9]+)\\..*" image.tag != releaseMinor then
      throw (
        "${who}: image.tag \"${image.tag}\" is not a ${lib.concatStringsSep "." releaseMinor} release, "
        + "and the CRDs under kix/packages/velero/crds are vendored from ${release}. To move to "
        + "another release, change release in kix/packages/velero/default.nix and run "
        + "uv run scripts/vendor-crds.py velero."
      )
    else
      kix.image.ref image;

  # Velero decodes the policy file with unknown keys refused, and a refused
  # file fails every backup, so the conditions are a closed set.
  volumeTypes = [
    "awsAzureDisk"
    "awsElasticBlockStore"
    "azureDisk"
    "azureFile"
    "cinder"
    "cephfs"
    "configMap"
    "csi"
    "downwardAPI"
    "emptyDir"
    "ephemeral"
    "fc"
    "flocker"
    "flexVolume"
    "gitRepo"
    "glusterfs"
    "gcePersistentDisk"
    "hostPath"
    "iscsi"
    "local"
    "nfs"
    "photonPersistentDisk"
    "portworxVolume"
    "projected"
    "quobyte"
    "rbd"
    "scaleIO"
    "secret"
    "storageOS"
    "vsphereVolume"
  ];

  nullOrOption =
    type: description:
    lib.mkOption {
      type = lib.types.nullOr type;
      default = null;
      inherit description;
    };

  volumePolicyType = lib.types.submodule {
    options = {
      conditions = lib.mkOption {
        default = { };
        description = "What a volume must match. Every field set must match; an unset field matches any volume.";
        type = lib.types.submodule {
          options = {
            capacity = nullOrOption lib.types.str "Capacity range \"<min>,<max>\", either side may be empty, e.g. \"0,100Gi\".";
            storageClass = nullOrOption (lib.types.listOf lib.types.str) "StorageClass names.";
            nfs = nullOrOption (lib.types.submodule {
              options = {
                server = nullOrOption lib.types.str "NFS server host.";
                path = nullOrOption lib.types.str "Exported path.";
              };
            }) "NFS volumes. `{ }` matches any NFS volume.";
            csi = nullOrOption (lib.types.submodule {
              options = {
                driver = nullOrOption lib.types.str "CSI driver name.";
                volumeAttributes = nullOrOption (lib.types.attrsOf lib.types.str) "CSI volume attributes. Needs `driver`.";
              };
            }) "CSI volumes. `{ }` matches any CSI volume.";
            volumeTypes = nullOrOption (lib.types.listOf (lib.types.enum volumeTypes)) "Pod volume source types, as Velero names them.";
            pvcLabels = nullOrOption (lib.types.attrsOf lib.types.str) "Labels the PersistentVolumeClaim carries.";
            pvcPhase = nullOrOption (lib.types.listOf (
              lib.types.enum [
                "Pending"
                "Bound"
                "Lost"
              ]
            )) "PersistentVolumeClaim phases.";
            pvcVolumeMode = nullOrOption (lib.types.enum [
              "Filesystem"
              "Block"
            ]) "PersistentVolumeClaim volume mode.";
            pvcAccessModes = nullOrOption (lib.types.listOf (
              lib.types.enum [
                "ReadWriteOnce"
                "ReadOnlyMany"
                "ReadWriteMany"
                "ReadWriteOncePod"
              ]
            )) "PersistentVolumeClaim access modes.";
          };
        };
      };
      action = {
        type = lib.mkOption {
          type = lib.types.enum [
            "skip"
            "snapshot"
            "fs-backup"
            "custom"
          ];
          description = "What Velero does with a matching volume.";
        };
        parameters = nullOrOption (lib.types.attrsOf lib.types.anything) "Parameters for the action, read by the plugin that handles it.";
      };
    };
  };

  # Null fields are left out. An empty `nfs` or `csi` stays, because Velero
  # reads it as "any NFS (CSI) volume".
  renderPolicy =
    policy:
    let
      dropNulls = lib.filterAttrs (_: v: v != null);
      conditions = lib.mapAttrs (_: v: if builtins.isAttrs v then dropNulls v else v) (
        dropNulls policy.conditions
      );
    in
    {
      inherit conditions;
      action = dropNulls policy.action;
    };

  # A cron line as robfig/cron's ParseStandard accepts it: five fields, or a
  # descriptor such as `@daily` or `@every 6h`, optionally after
  # CRON_TZ=<zone> or TZ=<zone>.
  cronType = lib.types.strMatching "((CRON_TZ|TZ)=[^ ]+ +)?(@.+|[^ ]+( +[^ ]+){4})";

  # Package config the node-agent and maintenance ConfigMaps carry, with the
  # data-path labels added.
  withDataPathLabels =
    settings:
    lib.filterAttrs (_: v: v != null) settings
    // {
      podLabels = settings.podLabels // dataPathLabels;
    };

  podLabelsOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Labels for the pods. The package adds the instance's selector labels and `app.kubernetes.io/component = data-path`, which the network policies select on.";
  };

  dataPathLabelCollisions =
    option: settings:
    let
      hits = builtins.attrNames (builtins.intersectAttrs dataPathLabels settings.podLabels);
    in
    {
      assertion = hits == [ ];
      message =
        "${option}.podLabels sets ${lib.concatStringsSep ", " hits}, which the package sets on the pods "
        + "Velero launches: the ${name}-data-path network policy and the backup location's policy select "
        + "those pods by it. Remove ${if builtins.length hits == 1 then "it" else "them"}.";
    };

  # The provider the AWS plugin serves.
  awsProvider = "velero.io/aws";
in
{
  meta = {
    version = release;
    description = "Velero backup and restore: server, node-agent, a default backup location, and scheduled backups";
    owner = "platform";
    defaultAliases = [ "velero" ];
    conflictsWith = [ "cluster:velero" ];
    # node-agent reads every pod's volumes under /var/lib/kubelet/pods, which
    # needs uid 0. The server reads every kind for a backup and recreates any
    # kind on restore, including custom resources installed after this build,
    # so no rule list derived here covers it.
    unsafe = [
      "run-as-root"
      "cluster-admin"
    ];
    # node-agent and the pods it launches mount hostPath volumes. meta cannot
    # read config, so this holds with node-agent off too.
    podSecurity = "privileged";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/velero/velero";
      tag = release;
      digest = "sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b";
      description = "Image of the server and node-agent. Its major.minor must match the vendored CRDs.";
    };

    awsPlugin = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the AWS object-store plugin, which serves provider `velero.io/aws` (S3 and S3-compatible stores).";
      };
      # Plugin v1.14 is the line built for Velero 1.18 (the compatibility
      # table in velero-plugin-for-aws's README).
      image = kix.options.image {
        repository = "docker.io/velero/velero-plugin-for-aws";
        tag = "v1.14.4";
        digest = "sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa";
        description = "Image of the AWS plugin init container.";
      };
    };

    extraPlugins = lib.mkOption {
      type = lib.types.attrsOf (kix.options.image { }).type;
      default = { };
      example = lib.literalExpression ''
        {
          velero-plugin-for-gcp = {
            repository = "docker.io/velero/velero-plugin-for-gcp";
            tag = "v1.14.0";
          };
        }
      '';
      description = "More plugins, init container name to image. Each image copies its plugin into /target, as Velero's own plugin images do.";
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "EnableCSI" ];
      description = "Velero feature flags, passed as `--features` to the server and node-agent.";
    };

    backupStorageLocation = lib.mkOption {
      default = { };
      description = ''
        The spec of the `default` BackupStorageLocation. Keys not listed here
        pass through to the spec. `credential` and `default` are set by the
        package. A second location is a CR built from
        `out.crds.BackupStorageLocation` in Velero's namespace.
      '';
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options = {
          provider = lib.mkOption {
            type = lib.types.str;
            default = awsProvider;
            description = "Object-store plugin that serves the location.";
          };
          objectStorage = lib.mkOption {
            default = { };
            description = "Where in the store backups go. Other keys, such as `caCertRef`, pass through.";
            type = lib.types.submodule {
              freeformType = lib.types.attrsOf lib.types.anything;
              options = {
                bucket = lib.mkOption {
                  type = lib.types.str;
                  description = "Bucket name. Bucket names are global to the store, so there is no default.";
                };
                prefix = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Directory in the bucket for every Velero object. Velero marks a location Unavailable when the bucket's top level holds directories it did not write, so a shared bucket needs one.";
                };
              };
            };
          };
          config = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = {
              region = "us-east-1";
              s3ForcePathStyle = "true";
            };
            description = "The plugin's settings (for the AWS plugin `region`, `s3Url`, `s3ForcePathStyle`, `checksumAlgorithm`). An empty string is passed on. With an `objectStorage` dependency, the package sets `s3Url` to its Service and refuses one set here, and `s3ForcePathStyle` defaults to `\"true\"`. Without one, the network policy opens the port of `s3Url` (443 when unset) to addresses outside the cluster.";
          };
        };
      };
    };

    volumeSnapshotLocation = lib.mkOption {
      default = null;
      description = "The spec of a `default` VolumeSnapshotLocation, for a provider's native snapshots. Null builds none. Keys not listed pass through; `credential` is set by the package.";
      type = lib.types.nullOr (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            provider = lib.mkOption {
              type = lib.types.str;
              default = awsProvider;
              description = "Volume-snapshotter plugin.";
            };
            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "The plugin's settings.";
            };
          };
        }
      );
    };

    schedules = lib.mkOption {
      default = { };
      description = "Schedules, by name. Each is a Schedule `spec`; keys not listed pass through.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            schedule = lib.mkOption {
              type = cronType;
              example = "CRON_TZ=UTC 0 3 * * *";
              description = "Cron line: five fields or a descriptor (`@daily`, `@every 6h`), optionally after `CRON_TZ=<zone>`.";
            };
            template = lib.mkOption {
              default = { };
              description = "The Backup spec each run uses. Keys not listed pass through.";
              type = lib.types.submodule {
                freeformType = lib.types.attrsOf lib.types.anything;
                options.storageLocation = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "BackupStorageLocation name. Null uses the package's `default` location.";
                };
              };
            };
          };
        }
      );
    };

    volumePolicies = lib.mkOption {
      type = lib.types.listOf volumePolicyType;
      default = [ ];
      example = lib.literalExpression ''
        [ { conditions.storageClass = [ "local-path" ]; action.type = "fs-backup"; } ]
      '';
      description = "Volume policies applied to every backup (a global policies ConfigMap). The first policy a volume matches decides its action.";
    };

    server = {
      resources = kix.options.resources {
        requests = {
          cpu = "500m";
          memory = "128Mi";
        };
        limits = {
          cpu = "1";
          memory = "512Mi";
        };
        description = "Resources of the server container. The defaults are `velero install`'s.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--default-repo-maintain-frequency=24h" ];
        description = "Flags appended to `velero server`.";
      };
      env = kix.options.env // {
        description = "Extra environment variables of the server, such as `HTTPS_PROXY`, `NO_PROXY`, or `GOMAXPROCS`. The repository maintenance Jobs copy them. A value is a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. The credentials file, scratch directory, plugin path, and namespace variables are set by the package.";
      };
    };

    nodeAgent = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run node-agent, which file-system backups and the CSI data mover need.";
      };
      # Velero leaves node-agent without requests or limits so a backup is
      # neither throttled nor OOM-killed (customize-installation.md); these
      # are requests only.
      resources = kix.options.resources {
        requests = {
          cpu = "500m";
          memory = "512Mi";
        };
        description = "Resources of the node-agent container. No limits by default, following Velero's advice not to throttle or OOM-kill backups.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Flags appended to `velero node-agent server`.";
      };
      env = kix.options.env // {
        description = "Extra environment variables of node-agent, such as `HTTPS_PROXY`, `NO_PROXY`, or `GOMAXPROCS`. The backup, restore, and data mover pods node-agent launches copy them. A value is a string, a `fieldRef` source, or a `secretKeyRef` naming a Secret managed outside Kix with `kix.untrackedRef`. The credentials file, scratch directory, node name, and namespace variables are set by the package.";
      };
      settings = lib.mkOption {
        default = { };
        example = {
          loadConcurrency.globalConfig = 2;
          podResources = {
            cpuRequest = "500m";
            memoryRequest = "512Mi";
          };
        };
        description = "node-agent's configuration (Velero's NodeAgentConfigs: `loadConcurrency`, `loadAffinity`, `podResources`, `backupPVC`, `priorityClassName`, ...), written to the node-agent ConfigMap.";
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options.podLabels = podLabelsOption;
        };
      };
    };

    repositoryMaintenance.settings = lib.mkOption {
      default = { };
      example = {
        keepLatestMaintenanceJobs = 3;
      };
      description = "The `global` entry of the repository-maintenance ConfigMap (Velero's JobConfigs: `keepLatestMaintenanceJobs`, `podResources`, `loadAffinity`, `priorityClassName`, ...). Used while node-agent is on.";
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
        options.podLabels = podLabelsOption;
      };
    };

    metrics = kix.options.monitor // {
      maxBackupAge = lib.mkOption {
        type = lib.types.strMatching "([0-9]+(ms|s|m|h|d|w|y))+";
        default = "26h";
        example = "8d";
        description = "How long a schedule may go without a successful backup before the VeleroBackupMissing alert fires, as a Prometheus duration. Set it above the longest interval between a schedule's runs plus its run time.";
      };
    };
  };

  assertions =
    { config, ... }:
    let
      bsl = config.backupStorageLocation;
      vsl = config.volumeSnapshotLocation;
      templates = map (s: s.template) (builtins.attrValues config.schedules);
      fsBackupPolicies = builtins.filter (p: p.action.type == "fs-backup") config.volumePolicies;
      needsNodeAgent =
        fsBackupPolicies != [ ]
        || builtins.any (t: t.defaultVolumesToFsBackup or false || t.snapshotMoveData or false) templates;
      setByPackage =
        location:
        lib.filter (k: location ? ${k}) [
          "credential"
          "default"
        ];
    in
    [
      {
        assertion = setByPackage bsl == [ ];
        message = "backupStorageLocation sets ${lib.concatStringsSep " and " (setByPackage bsl)}, which the package sets: the credential comes from the cloudCredentials dependency and this location is the default. Build another location in ${ns}, the only namespace Velero reads, with (scope.forService velero).mkCR velero.out.crds.BackupStorageLocation.";
      }
      {
        assertion = vsl == null || !(vsl ? credential);
        message = "volumeSnapshotLocation sets credential, which the package sets from the cloudCredentials dependency. Remove it.";
      }
      {
        assertion =
          config.awsPlugin.enabled
          || (bsl.provider != awsProvider && (vsl == null || vsl.provider != awsProvider));
        message = "awsPlugin.enabled is false, but a location uses provider ${awsProvider}, which that plugin serves. Turn the plugin back on, or set the location's provider to one an extraPlugins entry serves.";
      }
      {
        assertion = config.nodeAgent.enabled || !needsNodeAgent;
        message = "nodeAgent.enabled is false, but a volume policy uses fs-backup or a schedule sets defaultVolumesToFsBackup or snapshotMoveData; node-agent runs those. Turn node-agent on, or remove them.";
      }
      {
        assertion = builtins.all (
          p:
          p.conditions.csi == null
          || p.conditions.csi.volumeAttributes == null
          || p.conditions.csi.driver != null
        ) config.volumePolicies;
        message = "a volume policy sets conditions.csi.volumeAttributes without conditions.csi.driver, and Velero refuses that policy file, so every backup would fail. Set the driver.";
      }
      (dataPathLabelCollisions "nodeAgent.settings" config.nodeAgent.settings)
      (dataPathLabelCollisions "repositoryMaintenance.settings" config.repositoryMaintenance.settings)
    ];

  build = [
    (
      {
        self,
        config,
        cloudCredentials,
        repositoryPassword ? null,
        objectStorage ? null,
        prometheus ? null,
        ...
      }:
      let
        creds = kix.checkSecretKeys {
          inherit who;
          arg = "cloudCredentials";
          dep = cloudCredentials;
          keys = [ "cloud" ];
        };

        # Velero reads the repository key only from this Secret, by name
        # (pkg/repository/keys). Without it, Velero creates the Secret with
        # a key compiled into every Velero binary.
        repoSecretName = "velero-repo-credentials";
        repoPassword =
          let
            checked = kix.checkSecretKeys {
              inherit who;
              arg = "repositoryPassword";
              dep = repositoryPassword;
              keys = [ "repository-password" ];
            };
          in
          if repositoryPassword == null then
            if config.nodeAgent.enabled then
              throw (
                "${who}: node-agent is on and no repositoryPassword dependency resolved, so Velero would "
                + "encrypt the kopia repositories with the key compiled into every Velero binary. Add a "
                + "secret or secret-ref instance named ${repoSecretName} in ${ns} with key "
                + "repository-password and alias repositoryPassword, or set nodeAgent.enabled = false."
              )
            else
              null
          else if checked.out.name != repoSecretName then
            throw (
              "${who}: deps.repositoryPassword resolved to secret \"${checked.out.name}\", but Velero "
              + "reads the repository key only from a Secret named ${repoSecretName} in ${ns}. "
              + "Rename that instance."
            )
          else
            checked;

        bsl = config.backupStorageLocation;

        # The dependency's URL is what forms the location's network policy
        # to the store, so a user `s3Url` may not replace it.
        locationConfig =
          if objectStorage == null then
            bsl.config
          else if bsl.config ? s3Url then
            throw (
              "${who}: backupStorageLocation.config.s3Url is set to \"${bsl.config.s3Url}\", and the "
              + "objectStorage dependency supplies the store's URL. Velero would dial the address in "
              + "s3Url, and no network policy would open it. Remove s3Url to use the dependency's "
              + "Service, or stop wiring an objectStorage dependency to use a store outside the cluster."
            )
          else
            {
              s3Url =
                (objectStorage.out.url
                  or (throw "${who}: deps.objectStorage has no out.url. Wire an instance whose root is its S3 Service.")
                )
                  { };
              s3ForcePathStyle = "true";
            }
            // bsl.config;

        # Ports opened outside the cluster: the store on the port of `s3Url`
        # (443 when unset, the AWS endpoints), and HTTPS for a snapshot
        # location's cloud API. An in-cluster store wired as `objectStorage`
        # is opened by the location's operand policy instead.
        externalPorts = lib.unique (
          lib.optional (objectStorage == null) (if bsl.config ? s3Url then urlPort bsl.config.s3Url else 443)
          ++ lib.optional (config.volumeSnapshotLocation != null) 443
        );

        credential = {
          name = creds.out.name;
          key = "cloud";
        };

        credentialEnv = lib.genAttrs [
          "AWS_SHARED_CREDENTIALS_FILE"
          "AZURE_CREDENTIALS_FILE"
          "GOOGLE_APPLICATION_CREDENTIALS"
          "ALIBABA_CLOUD_CREDENTIALS_FILE"
        ] (_: "/credentials/cloud");

        # The root filesystem is read-only. kopia keeps its repository config
        # and cache under $HOME, so HOME points at the /scratch emptyDir;
        # Velero writes temp files to /tmp. The pods Velero launches copy
        # this env and these volumes from the server and node-agent.
        ownedEnv = extra: [
          {
            vars = credentialEnv;
            from = "the cloudCredentials dependency, mounted at /credentials/cloud";
            fix = "Remove it, and put the credentials in that Secret's `cloud` key.";
          }
          {
            vars = {
              VELERO_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
              VELERO_SCRATCH_DIR = "/scratch";
              HOME = "/scratch";
            }
            // extra;
            from = "the package (the pod's namespace or node, and the writable directories it mounts)";
            fix = "Remove it.";
          }
        ];

        emptyDirs =
          names:
          map (n: {
            name = n;
            emptyDir = { };
          }) names;

        commonMounts = [
          {
            name = "cloud-credentials";
            mountPath = "/credentials";
          }
          {
            name = "scratch";
            mountPath = "/scratch";
          }
          {
            name = "tmpdir";
            mountPath = "/tmp";
          }
        ];

        metricsContainerPort = {
          name = "http-monitoring";
          containerPort = metricsPort;
          protocol = "TCP";
        };

        metricsProbe = {
          httpGet = {
            path = "/metrics";
            port = "http-monitoring";
          };
          initialDelaySeconds = 10;
          periodSeconds = 30;
          timeoutSeconds = 5;
          failureThreshold = 5;
        };

        featureArgs = lib.optional (
          config.features != [ ]
        ) "--features=${lib.concatStringsSep "," config.features}";

        ownedArgs = {
          "--features" = "set the features option.";
          "--metrics-address" = "the probes and the metrics Service use :${toString metricsPort}; remove it.";
          "--node-agent-configmap" = "set nodeAgent.settings.";
          "--repo-maintenance-job-configmap" = "set repositoryMaintenance.settings.";
          "--global-backup-volume-policies-configmap" = "set volumePolicies.";
        };

        plugins =
          lib.optionalAttrs config.awsPlugin.enabled { velero-plugin-for-aws = config.awsPlugin.image; }
          // config.extraPlugins;

        pluginContainer = initName: image: {
          name = initName;
          image = kix.image.ref image;
          imagePullPolicy = image.pullPolicy;
          # The container copies one plugin binary into /target and exits.
          resources = {
            requests = {
              cpu = "10m";
              memory = "32Mi";
            };
            limits = {
              cpu = "100m";
              memory = "64Mi";
            };
          };
          securityContext.readOnlyRootFilesystem = true;
          volumeMounts = [
            {
              name = "plugins";
              mountPath = "/target";
            }
          ];
        };

        workloadRequires =
          builtins.attrValues self.crds
          ++ lib.optional (self.repositoryKey != null) self.repositoryKey
          ++ lib.optional (self.externalStoreEgress != null) self.externalStoreEgress;

        metricsOn = config.metrics.enabled && prometheus != null;

        crdFile = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
        phaseReadiness = phase: {
          path = "/status/phase";
          equals = phase;
        };
      in
      {
        crds = {
          backupRepositories = scope.mkCRD { spec = crdFile "backuprepositories.velero.io.json"; };
          backups = scope.mkCRD {
            spec = crdFile "backups.velero.io.json";
            readiness = phaseReadiness "Completed";
          };
          # Velero's pods dial the store named in the location's config
          # (`s3Url`), not whoever creates the location.
          backupStorageLocations = scope.mkCRD {
            spec = crdFile "backupstoragelocations.velero.io.json";
            readiness = phaseReadiness "Available";
            factBehavior = {
              endpoint = "terminate";
              podSelector = scope.selectorLabels;
            };
          };
          dataDownloads = scope.mkCRD { spec = crdFile "datadownloads.velero.io.json"; };
          dataUploads = scope.mkCRD { spec = crdFile "datauploads.velero.io.json"; };
          deleteBackupRequests = scope.mkCRD { spec = crdFile "deletebackuprequests.velero.io.json"; };
          downloadRequests = scope.mkCRD { spec = crdFile "downloadrequests.velero.io.json"; };
          podVolumeBackups = scope.mkCRD { spec = crdFile "podvolumebackups.velero.io.json"; };
          podVolumeRestores = scope.mkCRD { spec = crdFile "podvolumerestores.velero.io.json"; };
          restores = scope.mkCRD {
            spec = crdFile "restores.velero.io.json";
            readiness = phaseReadiness "Completed";
          };
          schedules = scope.mkCRD {
            spec = crdFile "schedules.velero.io.json";
            readiness = phaseReadiness "Enabled";
          };
          serverStatusRequests = scope.mkCRD { spec = crdFile "serverstatusrequests.velero.io.json"; };
          volumeSnapshotLocations = scope.mkCRD { spec = crdFile "volumesnapshotlocations.velero.io.json"; };
        };

        # Nothing in the pod specs names the repository Secret, because
        # Velero reads it by name, and a server that starts before it exists
        # creates it with the compiled-in key. The workloads require this
        # reference, so the deploy waits for the Secret first.
        repositoryKey =
          if repoPassword == null then
            null
          else
            scope.mkSecretRef {
              name = repoSecretName;
              keys = [ "repository-password" ];
            };

        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${name}-server";
        };

        clusterRoleBinding = scope.mkClusterResource {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRoleBinding";
          name = "${name}-server";
          extra = {
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "cluster-admin";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = self.serviceAccount.out.name;
                namespace = ns;
              }
            ];
          };
        };

        deployment = scope.mkDeployment {
          name = "velero";
          # One server: it has no leader election, and a second would race
          # the first over the same backups.
          availability.max = "none";
          spec = {
            replicas = 1;
            strategy.type = "Recreate";
            # node-agent and data-path pods carry the selector labels too;
            # the component keeps them out of this selector.
            selector.matchLabels = scope.selectorLabels // componentLabels "server";
            template.spec = {
              serviceAccount = self.serviceAccount;
              # On SIGTERM the server cancels its work and exits, and marks
              # in-progress backups and restores Failed at its next start
              # (markInProgressCRsFailed), so a longer grace period lets no
              # backup finish.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                # `cnb` in the velero image.
                runAsUser = 1002;
              };
              initContainers = lib.mapAttrsToList pluginContainer plugins;
              containers = [
                {
                  name = "velero";
                  image = checkedRef config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  command = [ "/velero" ];
                  args = [
                    "server"
                    "--metrics-address=:${toString metricsPort}"
                  ]
                  ++ featureArgs
                  ++ lib.optional (
                    self.volumePolicies != null
                  ) "--global-backup-volume-policies-configmap=${self.volumePolicies.out.name}"
                  ++ lib.optional (
                    self.repositoryMaintenanceConfig != null
                  ) "--repo-maintenance-job-configmap=${self.repositoryMaintenanceConfig.out.name}"
                  ++ kix.guardArgs {
                    inherit who;
                    option = "server.extraArgs";
                    owned = ownedArgs;
                  } config.server.extraArgs;
                  env = kix.mkEnvVars (
                    kix.mergeEnv {
                      inherit who;
                      owned = ownedEnv { LD_LIBRARY_PATH = "/plugins"; };
                    } config.server.env
                  );
                  ports = [ metricsContainerPort ];
                  livenessProbe = metricsProbe;
                  readinessProbe = metricsProbe;
                  resources = config.server.resources;
                  securityContext.readOnlyRootFilesystem = true;
                  volumeMounts = commonMounts ++ [
                    {
                      name = "plugins";
                      mountPath = "/plugins";
                    }
                  ];
                }
              ];
              volumes = [
                (creds.out.volume "cloud-credentials")
              ]
              ++ emptyDirs [
                "plugins"
                "scratch"
                "tmpdir"
              ];
            };
          };
          requires = workloadRequires;
        };

        nodeAgent =
          if !config.nodeAgent.enabled then
            null
          else
            scope.mkDaemonSet {
              name = "node-agent";
              spec = {
                # Velero finds node-agent pods by `role` (pkg/nodeagent/node_agent.go).
                selector.matchLabels =
                  scope.selectorLabels
                  // componentLabels "node-agent"
                  // {
                    role = "node-agent";
                  };
                template = {
                  metadata = {
                    # node-agent reads its ConfigMap at start.
                    annotations."checksum/node-agent-config" = self.nodeAgentConfig.out.identityHash;
                  };
                  spec = {
                    serviceAccount = self.serviceAccount;
                    # node-agent also cancels its work on SIGTERM (see the server).
                    terminationGracePeriodSeconds = 30;
                    securityContext.runAsUser = 0;
                    containers = [
                      {
                        name = "node-agent";
                        image = checkedRef config.image;
                        imagePullPolicy = config.image.pullPolicy;
                        command = [ "/velero" ];
                        args = [
                          "node-agent"
                          "server"
                          "--metrics-address=:${toString metricsPort}"
                        ]
                        ++ featureArgs
                        ++ [ "--node-agent-configmap=${self.nodeAgentConfig.out.name}" ]
                        ++ kix.guardArgs {
                          inherit who;
                          option = "nodeAgent.extraArgs";
                          owned = ownedArgs;
                        } config.nodeAgent.extraArgs;
                        env = kix.mkEnvVars (
                          kix.mergeEnv {
                            inherit who;
                            owned = ownedEnv { NODE_NAME.valueFrom.fieldRef.fieldPath = "spec.nodeName"; };
                          } config.nodeAgent.env
                        );
                        ports = [ metricsContainerPort ];
                        livenessProbe = metricsProbe;
                        readinessProbe = metricsProbe;
                        resources = config.nodeAgent.resources;
                        securityContext.readOnlyRootFilesystem = true;
                        volumeMounts = commonMounts ++ [
                          {
                            name = "host-pods";
                            mountPath = "/host_pods";
                            mountPropagation = "HostToContainer";
                          }
                          {
                            name = "host-plugins";
                            mountPath = "/var/lib/kubelet/plugins";
                            mountPropagation = "HostToContainer";
                          }
                        ];
                      }
                    ];
                    volumes = [
                      (creds.out.volume "cloud-credentials")
                      {
                        name = "host-pods";
                        hostPath.path = "/var/lib/kubelet/pods";
                      }
                      {
                        name = "host-plugins";
                        hostPath.path = "/var/lib/kubelet/plugins";
                      }
                    ]
                    ++ emptyDirs [
                      "scratch"
                      "tmpdir"
                    ];
                  };
                };
              };
              requires = workloadRequires;
            };

        # Velero reads the one data key of each of these ConfigMaps, as JSON.
        nodeAgentConfig =
          if !config.nodeAgent.enabled then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-node-agent";
              data."node-agent.json" = builtins.toJSON (withDataPathLabels config.nodeAgent.settings);
            };

        repositoryMaintenanceConfig =
          if !config.nodeAgent.enabled then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-repo-maintenance";
              data.global = builtins.toJSON (withDataPathLabels config.repositoryMaintenance.settings);
            };

        # JSON is YAML, which is what Velero decodes.
        volumePolicies =
          if config.volumePolicies == [ ] then
            null
          else
            scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-volume-policies";
              data."policies.yaml" = builtins.toJSON {
                version = "v1";
                volumePolicies = map renderPolicy config.volumePolicies;
              };
            };

        # DNS and API server egress for the pods Velero launches (file-system
        # backup and restore, data mover, repository maintenance). The store
        # is opened for them by the location's operand policy or by
        # externalStoreEgress, which both select every pod of the instance.
        dataPathEgress =
          if !config.nodeAgent.enabled then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-data-path";
              spec =
                let
                  netpol = scope.networkPolicyEnforcer.netpol;
                in
                {
                  endpointSelector.matchLabels = dataPathLabels;
                  egress = [
                    netpol.dnsEgressRule
                    netpol.apiServerEgressRule
                  ];
                };
            };

        # Egress outside the cluster for every pod of the instance; see
        # externalPorts.
        externalStoreEgress =
          if externalPorts == [ ] then
            null
          else
            kix.operandPolicy {
              inherit scope;
              name = "${name}-external-store";
              spec = {
                endpointSelector.matchLabels = scope.selectorLabels;
                egress =
                  (scope.networkPolicyEnforcer.netpol.translateIntentRules {
                    intents.store.egress = [
                      {
                        to = "world";
                        ports = map (port: {
                          inherit port;
                          protocol = "TCP";
                        }) externalPorts;
                      }
                    ];
                  }).egressRules;
              };
            };

        service =
          if !metricsOn then
            null
          else
            self.deployment
            |> kix.service.fromWorkload {
              inherit name;
              labels = componentLabels "server";
              ports = [
                {
                  name = "http-monitoring";
                  port = metricsPort;
                  targetPort = "http-monitoring";
                }
              ];
            }
            |> scope.mkResource;

        nodeAgentService =
          if !(metricsOn && config.nodeAgent.enabled) then
            null
          else
            self.nodeAgent
            |> kix.service.fromWorkload {
              name = "${name}-node-agent";
              labels = componentLabels "node-agent";
              ports = [
                {
                  name = "http-monitoring";
                  port = metricsPort;
                  targetPort = "http-monitoring";
                }
              ];
            }
            |> scope.mkResource;

        backupStorageLocation = self.crds.backupStorageLocations.out.mkCR scope {
          name = "default";
          spec =
            removeAttrs bsl [
              "objectStorage"
              "config"
            ]
            // {
              objectStorage = lib.filterAttrs (k: v: !(k == "prefix" && v == null)) bsl.objectStorage;
              config = locationConfig;
              default = true;
              inherit credential;
            };
          requires = [ self.deployment ];
        };

        volumeSnapshotLocation =
          if config.volumeSnapshotLocation == null then
            null
          else
            self.crds.volumeSnapshotLocations.out.mkCR scope {
              name = "default";
              spec = config.volumeSnapshotLocation // {
                inherit credential;
              };
              requires = [ self.deployment ];
            };

        schedules = lib.mapAttrs (
          scheduleName: schedule:
          self.crds.schedules.out.mkCR scope {
            name = scheduleName;
            spec = schedule // {
              template = schedule.template // {
                storageLocation =
                  if schedule.template.storageLocation == null then
                    self.backupStorageLocation.out.name
                  else
                    schedule.template.storageLocation;
              };
            };
            # A schedule on the default location already depends on it
            # through storageLocation; one on another location waits for the
            # default, so the server is running when it is applied.
            requires = lib.optional (schedule.template.storageLocation != null) self.backupStorageLocation;
          }
        ) config.schedules;

        root = {
          resource = self.deployment;
          # Dependents wait for an Available location, and for the data-path
          # policy before anything they build starts a backup. Listing the
          # monitoring parts keeps them referenced from root.
          requires = [
            self.backupStorageLocation
          ]
          ++ builtins.filter (part: part != null) [
            self.dataPathEgress
            self.service
            self.serviceMonitor
            self.prometheusRules
            self.nodeAgentService
            (self.nodeAgentMonitor or null)
            (self.nodeAgentRules or null)
          ];
          out =
            let
              # Velero watches only its own namespace, so the CR is built
              # there and waits for an Available location.
              inVeleroNamespace =
                part: consumerScope: args:
                self.crds.${part}.out.mkCR (consumerScope.forNamespace ns) (
                  args // { requires = (args.requires or [ ]) ++ [ self.backupStorageLocation ]; }
                );
            in
            {
              crds = {
                Backup = self.crds.backups;
                BackupRepository = self.crds.backupRepositories;
                BackupStorageLocation = self.crds.backupStorageLocations;
                DataDownload = self.crds.dataDownloads;
                DataUpload = self.crds.dataUploads;
                DeleteBackupRequest = self.crds.deleteBackupRequests;
                DownloadRequest = self.crds.downloadRequests;
                PodVolumeBackup = self.crds.podVolumeBackups;
                PodVolumeRestore = self.crds.podVolumeRestores;
                Restore = self.crds.restores;
                Schedule = self.crds.schedules;
                ServerStatusRequest = self.crds.serverStatusRequests;
                VolumeSnapshotLocation = self.crds.volumeSnapshotLocations;
              };
              mkBackup = inVeleroNamespace "backups";
              mkSchedule = inVeleroNamespace "schedules";
            };
        };
      }
    )

    # The server alerts read the threshold from config, so the wrapper names
    # every argument kix.monitor reads (see the node-agent monitor below).
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        server = ''namespace="${ns}",service="${name}"'';
        scheduled = ''${server},schedule!=""'';
        age = config.metrics.maxBackupAge;
      in
      kix.monitor {
        service = "service";
        port = "http-monitoring";
        alerts = {
          VeleroBackupFailed = {
            expr = "sum by (schedule) (increase(velero_backup_failure_total{${server}}[1h]) + increase(velero_backup_partial_failure_total{${server}}[1h])) > 0";
            severity = "warning";
            summary = "A Velero backup failed or partly failed in the last hour";
            description = "Velero in ${ns} recorded a failed or partially failed backup for schedule {{ $labels.schedule }}. Run velero backup describe on its latest backup.";
          };
          # Velero creates a schedule's counters at 0 when it reconciles the
          # schedule, so they exist before the first run. A schedule is
          # reported when the server knew it maxBackupAge ago, still knows
          # it, and counted no success in between. The last-success
          # timestamp gauge is not used: a restarted server reports it only
          # after its next success.
          VeleroBackupMissing = {
            expr = "(sum by (schedule) (velero_backup_attempt_total{${scheduled}} offset ${age}) and on (schedule) sum by (schedule) (velero_backup_attempt_total{${scheduled}})) unless on (schedule) (sum by (schedule) (increase(velero_backup_success_total{${scheduled}}[${age}])) > 0)";
            "for" = "15m";
            severity = "warning";
            summary = "A Velero schedule has no successful backup within metrics.maxBackupAge";
            description = "Schedule {{ $labels.schedule }} of Velero in ${ns} has not completed a backup in ${age}. Check the backup location with velero backup-location get and the schedule's latest backups.";
          };
          VeleroServerDown = {
            expr = "absent(up{${server}} == 1)";
            "for" = "15m";
            severity = "warning";
            summary = "The Velero server is not being scraped";
            description = "Prometheus has scraped no running Velero server in ${ns} for 15 minutes, so no backup runs. Check deployment/velero.";
          };
        };
      } args
    )

    # The node-agent monitor exists only with node-agent. DI passes a build
    # function only the arguments its formals name (builtins.functionArgs),
    # so the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      lib.optionalAttrs config.nodeAgent.enabled (
        kix.monitor {
          name = "${name}-node-agent";
          service = "nodeAgentService";
          port = "http-monitoring";
          monitorPart = "nodeAgentMonitor";
          rulesPart = "nodeAgentRules";
        } args
      )
    )
  ];
}
