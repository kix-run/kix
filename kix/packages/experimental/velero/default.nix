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
#       package = packages.experimental.velero;
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
# come from the two ConfigMaps in workloads.nix (`podLabels`) and their
# traffic from the `dataPathEgress` and `externalStoreEgress` policies.
#
# Dependencies:
#   cloudCredentials (required)  a secret or secret-ref in one of two forms,
#                                or a cloud identity:
#                                - key `cloud`, the object-store credentials
#                                  file, mounted at /credentials and named by
#                                  the locations;
#                                - keys AWS_ACCESS_KEY_ID and
#                                  AWS_SECRET_ACCESS_KEY, set as environment
#                                  variables of the server and node-agent. The
#                                  locations name no credential, and the AWS
#                                  plugin and kopia read the pair from the
#                                  environment. A changed pair reaches the
#                                  server and node-agent when they restart;
#                                - `kix.cloudIdentity.aws`, `gcp`, or `azure`
#                                  for the cloud of the location's provider,
#                                  bound to the one ServiceAccount (below).
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
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the server Service's series.
#   VeleroBackupFailed (warning)   a backup failed or partly failed in the
#                                  last hour.
#   VeleroBackupMissing (warning)  a schedule has no successful backup
#                                  within its age (below).
#   VeleroServerDown (warning)     no running server is scraped.
# A schedule not in `metrics.maxBackupAge` takes `kix.schedules.staleAfter`
# of its cron line, two periods plus two hours (50h for a daily schedule),
# and the build fails for one whose period the package cannot read, such
# as a line that names days of the month. Up to 6d, VeleroBackupMissing
# compares the schedule's backup counters across that window, which the
# 7d Prometheus retention holds. A longer age compares
# velero_backup_last_successful_timestamp with the current time; Velero
# reports that gauge only after a backup succeeds, so after a server
# restart, or before the first success, a weekly schedule's alert is silent
# until its next success. Schedules built through `out.mkSchedule` share
# one age, `metrics.otherSchedulesMaxAge` (50h by default), since the
# package cannot read their cron lines. Left to prometheus-default-rules: crash loops
# (KubePodCrashLooping) and a node-agent pod that does not start
# (KubeDaemonSetRolloutStuck).
#
# `out`:
#   out.version                  the Velero version `image.tag` names.
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
# containers; `server.annotations` and `nodeAgent.annotations` reach the
# workloads; `nodeAgent.settings` and `repositoryMaintenance.settings` are
# Velero's own configuration; `extraPlugins` adds plugin images; instance
# `partsOverlays` covers the rest.
#
# A cloud identity in cloudCredentials binds to the `<instance>-server`
# ServiceAccount, which the server, node-agent, and every pod they launch
# run as. The package then mounts no credentials file and names no
# `credential` on the locations, so the plugins and kopia use their SDK's
# default credentials. Velero copies `azure.workload.identity/use` to the
# pods it launches only when the node-agent and maintenance `podLabels` are
# empty, and the package always sets them, so it adds the identity's pod
# labels there. Without a credentials file, each plugin needs settings on
# the location, which the build checks:
#   - GCP: `config.serviceAccount`, the Google service account the plugin
#     signs download URLs as.
#   - Azure: `config.storageAccount`, and `useAAD = "true"` or
#     `resourceGroup` and `subscriptionId`. An Azure snapshot location is
#     refused, because its snapshotter reads the subscription only from a
#     credentials file.
# An identity with an in-cluster `objectStorage` is refused, and so is a
# snapshot location for another cloud.
#
#   instances.velero.velero = {
#     package = packages.experimental.velero;
#     deps.cloudCredentials = kix.cloudIdentity.aws {
#       roleArn = "arn:aws:iam::111122223333:role/velero";
#     };
#     config.backupStorageLocation = {
#       objectStorage.bucket = "my-cluster-backups";
#       config.region = "us-east-1";
#     };
#   };
#
# Known limits:
# - With a cloud identity, the Azure plugin reads the cloud name only from a
#   credentials file and so assumes the public cloud. For another Azure
#   cloud, set the location's `storageAccountURI` and
#   `activeDirectoryAuthorityURI`.
# - With a cloud identity, the egress policy opens only the store's port
#   (443 by default) outside the cluster, which covers AWS STS and Entra ID.
#   It does not open the GKE metadata server.
# - With the key pair form, the AWS SDK prefers the pair in the environment
#   to a location's own credentials file. Another location with a
#   `credential` must set `config.profile` (for example "default") for its
#   file to be read.
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
  c = import ./common.nix { inherit lib kix scope; };
  # meta.version and image.tag read `release`; crds/sources.txt names the same tag.
  inherit (c)
    release
    awsProvider
    ns
    volumePolicyType
    cronType
    podLabelsOption
    dataPathLabelCollisions
    providerCloud
    identityCloud
    ;
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
      description = "The spec of a `default` VolumeSnapshotLocation, for a provider's native snapshots. Null builds none. Keys not listed pass through; `credential` is set by the package when cloudCredentials is a file.";
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
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "secret.reloader.stakater.com/reload" = "velero-credentials";
        };
        description = "Annotations on the server Deployment, for a controller that reads them, such as one that restarts the workload when a Secret it reads changes.";
      };
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
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "secret.reloader.stakater.com/reload" = "velero-credentials";
        };
        description = "Annotations on the node-agent DaemonSet, for a controller that reads them, such as one that restarts the workload when a Secret it reads changes.";
      };
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
      otherSchedulesMaxAge = lib.mkOption {
        type = kix.types.promDuration;
        default = "50h";
        example = "338h";
        description = "How long a Schedule this package does not render, such as one built through `out.mkSchedule`, may go without a successful backup before VeleroBackupMissing fires. The package cannot read those cron lines, so one age covers them all. The default suits daily schedules; a weekly one needs \"338h\".";
      };
      maxBackupAge = lib.mkOption {
        type = lib.types.attrsOf kix.types.promDuration;
        default = { };
        example = {
          monthly = "64d";
        };
        description = "How long each schedule, by its name in `schedules`, may go without a successful backup before VeleroBackupMissing fires, as a Prometheus duration. A schedule not listed takes `kix.schedules.staleAfter` of its cron line: two periods plus two hours, so `@daily` gives 50h and a line that names days of the week gives 338h, and one missed run does not fire it. List a schedule whose period cannot be read, such as one that names days of the month: while the alerts render, the build fails without it. An age over 6d is compared with the last success's timestamp, which Velero reports only after a success since the server started.";
      };
    };
  };

  assertions =
    {
      config,
      deps ? { },
      ...
    }:
    let
      bsl = config.backupStorageLocation;
      vsl = config.volumeSnapshotLocation;
      # `use` has already refused an identity for a cloud other than the
      # default location's, so `bslCloud` is the identity's cloud.
      identity =
        (kix.cloudIdentity.use {
          inherit scope;
          dep = deps.cloudCredentials or null;
          arg = "cloudCredentials";
          cloud = identityCloud {
            inherit config;
            objectStorage = deps.objectStorage or null;
          };
        }).identity;
      bslCloud = providerCloud bsl.provider;
      vslCloud = if vsl == null then null else providerCloud vsl.provider;
      cloudNames = {
        aws = "AWS";
        gcp = "Google Cloud";
        azure = "Azure";
      };
      cloudName = cloud: cloudNames.${cloud} or "an unsupported cloud";
      # strconv.ParseBool, which the Azure plugin reads useAAD with.
      useAAD = builtins.elem (bsl.config.useAAD or "") [
        "1"
        "t"
        "T"
        "TRUE"
        "true"
        "True"
      ];
      templates = map (s: s.template) (builtins.attrValues config.schedules);
      fsBackupPolicies = builtins.filter (p: p.action.type == "fs-backup") config.volumePolicies;
      needsNodeAgent =
        fsBackupPolicies != [ ]
        || builtins.any (t: t.defaultVolumesToFsBackup or false || t.snapshotMoveData or false) templates;
      unknownAgeKeys = builtins.filter (k: !(config.schedules ? ${k})) (
        builtins.attrNames config.metrics.maxBackupAge
      );
      setByPackage =
        location:
        lib.filter (k: location ? ${k}) [
          "credential"
          "default"
        ];
    in
    [
      # The CRDs come from `release`, and a server of another minor release
      # may not serve the same schema.
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the CRDs in kix/packages/experimental/velero/crds come from ${release}";
        fix = "To update this package to another version, change release in kix/packages/experimental/velero/common.nix and run uv run scripts/vendor-crds.py velero.";
      })
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
      {
        assertion = unknownAgeKeys == [ ];
        message = "metrics.maxBackupAge names ${lib.concatStringsSep ", " unknownAgeKeys}, which ${
          if builtins.length unknownAgeKeys == 1 then "is not a schedule" else "are not schedules"
        } in schedules. Its keys are schedule names: ${
          if config.schedules == { } then
            "there are none"
          else
            lib.concatStringsSep ", " (builtins.attrNames config.schedules)
        }.";
      }
      # One ServiceAccount carries one identity, so a snapshot location of
      # another of the three clouds cannot use it.
      {
        assertion = identity == null || vslCloud == null || vslCloud == bslCloud;
        option = "volumeSnapshotLocation.provider";
        message = "VolumeSnapshotLocation/default sets volumeSnapshotLocation.provider to \"${
          if vsl == null then "" else vsl.provider
        }\" (${cloudName vslCloud}), while BackupStorageLocation/default and deps.cloudCredentials use a cloud identity for ${cloudName bslCloud}. Velero runs both locations under one ServiceAccount, which can hold only one cloud identity, so Kix rejected this configuration.";
        fix = "Set volumeSnapshotLocation.provider to a snapshot provider for ${cloudName bslCloud}, remove volumeSnapshotLocation, or pass a Secret instance in deps.cloudCredentials.";
      }
      # The Azure volume snapshotter reads AZURE_SUBSCRIPTION_ID and
      # AZURE_RESOURCE_GROUP only from a credentials file
      # (velero-plugin-for-microsoft-azure volume_snapshotter.go Init), and
      # a cloud identity mounts none.
      {
        assertion = identity == null || vslCloud != "azure";
        option = "volumeSnapshotLocation";
        message = "VolumeSnapshotLocation/default uses the Azure plugin, which reads the disk subscription and resource group only from a mounted credentials file. When deps.cloudCredentials is a cloud identity, no credentials file is mounted, so Kix rejected volumeSnapshotLocation because the snapshot plugin would fail to start.";
        fix = "Remove volumeSnapshotLocation and use CSI snapshots (features = [ \"EnableCSI\" ]) or file-system backups instead, or pass a Secret instance with key \"cloud\" in deps.cloudCredentials.";
      }
      # Without a key file, the GCP plugin signs download URLs through the
      # IAM API as the account in `serviceAccount`, and refuses to start
      # without it (velero-plugin-for-gcp object_store.go
      # initFromComputeEngine).
      {
        assertion = identity == null || bslCloud != "gcp" || bsl.config ? serviceAccount;
        option = "backupStorageLocation.config.serviceAccount";
        message = "BackupStorageLocation/default does not set backupStorageLocation.config.serviceAccount, which Velero's GCP plugin requires when deps.cloudCredentials is a Google Cloud identity. Without a JSON key file, the plugin needs that Google service account email to sign download URLs and fails to start if it is unset, so Kix rejected this configuration.";
        fix = "Set backupStorageLocation.config.serviceAccount to a Google service account email. If you set serviceAccount in kix.cloudIdentity.gcp { serviceAccount = \"...\"; }, use that same email. If you use kix.cloudIdentity.gcp { }, pass a Google service account on which Velero's Kubernetes ServiceAccount has roles/iam.serviceAccountTokenCreator.";
      }
      # The Azure plugin reads the account's resource group and subscription
      # from the location's config or the credentials file
      # (pkg/util/azure/storage.go upstream). With useAAD it talks to the
      # blob service directly; without it, it lists the account keys
      # through Azure Resource Manager, which needs both.
      {
        assertion =
          identity == null
          || bslCloud != "azure"
          || (
            bsl.config ? storageAccount
            && (useAAD || (bsl.config ? resourceGroup && bsl.config ? subscriptionId))
          );
        option = "backupStorageLocation.config";
        message = "BackupStorageLocation/default is missing required Azure storage settings in backupStorageLocation.config (currently sets ${
          if bsl.config == { } then "nothing" else lib.concatStringsSep ", " (builtins.attrNames bsl.config)
        }). Without a mounted credentials file, Velero's Azure plugin needs storageAccount and either useAAD = \"true\" or both resourceGroup and subscriptionId, so Kix rejected this configuration.";
        fix = "In backupStorageLocation.config, set storageAccount and either useAAD = \"true\" (requires the Storage Blob Data Contributor role on the storage account) or both resourceGroup and subscriptionId (requires permission to list the storage account keys).";
      }
      (dataPathLabelCollisions "nodeAgent.settings" config.nodeAgent.settings)
      (dataPathLabelCollisions "repositoryMaintenance.settings" config.repositoryMaintenance.settings)
    ];

  build = [
    ./workloads.nix
    ./locations.nix
  ];
}
