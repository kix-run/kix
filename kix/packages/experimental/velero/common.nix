# Shared constants, option types, and helpers for the Velero package.

{
  lib,
  kix,
  scope,
}:

rec {
  # meta.version and image.tag read this; crds/sources.txt names the same tag.
  release = "v1.18.4";

  # The provider the AWS plugin serves.
  awsProvider = "velero.io/aws";

  metricsPort = 8085;

  name = scope.instanceName;
  ns = scope.namespaceName;

  # Each workload, and each metrics Service, carries its own component, so
  # no selector claims another component's pods and a ServiceMonitor built
  # from one Service's labels selects only that Service.
  componentLabels = component: { "app.kubernetes.io/component" = component; };

  # Labels of the pods Velero creates itself (file-system backup and restore,
  # data mover, repository maintenance). They carry the instance's selector
  # labels, so the location's and the external store's policies reach them.
  dataPathLabels = scope.selectorLabels // componentLabels "data-path";

  # The port of an http or https URL: the explicit one, else the scheme's.
  urlPort =
    url:
    let
      m = builtins.match "(https?)://(\\[[^]]*]|[^]/:?#[]*)(:([0-9]+))?([/?#].*)?" url;
    in
    if m == null then
      scope.fail {
        option = "backupStorageLocation.config.s3Url";
        message = "s3Url \"${url}\" is not an http or https URL, so the package cannot tell which port the store listens on.";
        fix = "Write it as https://<host>[:<port>].";
      }
    else if builtins.elemAt m 3 != null then
      lib.toInt (builtins.elemAt m 3)
    else if builtins.elemAt m 0 == "https" then
      443
    else
      80;

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
  # data-path labels and `identityLabels` added. Velero copies the
  # `azure.workload.identity/use` label from its own workloads to the pods
  # it launches only when `podLabels` is empty, and the data-path labels
  # make it non-empty, so the identity's pod labels are written here.
  withDataPathLabels =
    identityLabels: settings:
    lib.filterAttrs (_: v: v != null) settings
    // {
      podLabels = settings.podLabels // identityLabels // dataPathLabels;
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

  # Return the cloud whose API a location's provider calls, or null for a
  # plugin outside the three Velero maintains. Velero adds the `velero.io/`
  # prefix to a provider name that has none.
  providerCloud =
    provider:
    {
      "velero.io/aws" = "aws";
      "velero.io/gcp" = "gcp";
      "velero.io/azure" = "azure";
    }
    .${if lib.hasInfix "/" provider then provider else "velero.io/${provider}"} or null;

  # Return the cloud a cloud identity in cloudCredentials must belong to:
  # the cloud of the default location's provider, or null when the store is
  # an in-cluster `objectStorage` dependency, which no cloud identity reaches.
  identityCloud =
    { config, objectStorage }:
    if objectStorage != null then null else providerCloud config.backupStorageLocation.provider;

  # Read the cloudCredentials dependency: a cloud identity, a credentials
  # file in key `cloud`, or an AWS key pair the pods read as environment
  # variables. Return `{ identity; bind; dep; file; envKeys; }`. `dep` is
  # the Secret, or null with an identity. `file` is true for the file form,
  # and `envKeys` names the key pair, or is null.
  readCloudCredentials =
    {
      cloudCredentials,
      config,
      objectStorage,
    }:
    let
      credentials = kix.cloudIdentity.use {
        inherit scope;
        dep = cloudCredentials;
        cloud = identityCloud { inherit config objectStorage; };
      };
      secret = checkCloudCredentials credentials.secret;
    in
    {
      inherit (credentials) identity bind;
    }
    // (
      if credentials.identity != null then
        {
          dep = null;
          file = false;
          envKeys = null;
        }
      else
        {
          inherit (secret) dep envKeys;
          file = secret.envKeys == null;
        }
    );

  # The cloudCredentials dependency, when it is a Secret, in one of two
  # forms: a credentials file in key `cloud`, or an AWS key pair the pods
  # read as environment variables. `envKeys` is null for the file form.
  checkCloudCredentials =
    cloudCredentials:
    let
      dep = kix.contracts.secret.helpers.use {
        inherit scope;
        arg = "cloudCredentials";
        dep = cloudCredentials;
        anyOf = [
          [ "cloud" ]
          awsKeyPair
        ];
      };
      declared = dep.out.keys or [ ];
      isFile = builtins.elem "cloud" declared;
    in
    if isFile && builtins.any (k: builtins.elem k declared) awsKeyPair then
      scope.fail {
        message = "deps.cloudCredentials resolved to secret \"${dep.out.name}\", which declares both `cloud` and ${lib.concatStringsSep ", " awsKeyPair}. Velero would read the key pair and ignore the file.";
        fix = "Keep one form.";
      }
    else
      {
        inherit dep;
        envKeys = if isFile then null else awsKeyPair;
      };

  awsKeyPair = [
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
  ];
}
