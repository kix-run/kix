# Tests for the velero package's cloudCredentials dependency holding a cloud
# identity (`kix.cloudIdentity.aws`, `gcp`, `azure`) in place of a Secret:
# what it renders on each cloud, the Secret forms it still takes, and the
# settings each object-store plugin needs when no credentials file exists.

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  veleroPackage = import ../../../packages/experimental/velero;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  ci = kixlib.cloudIdentity;

  helpers = import ../caught.nix { inherit lib; };
  k8s = import ../../core { inherit lib; };
  # The evaluator loaded so that a failed assertion does not stop the
  # build, which leaves `diagnostics.failedAssertions` readable.
  evalCaught = helpers.loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  failedOf =
    modules:
    (evalCaught.buildCluster {
      name = "test";
      inherit modules;
    }).diagnostics.failedAssertions;

  roleArn = "arn:aws:iam::111122223333:role/velero";
  googleAccount = "velero@my-project.iam.gserviceaccount.com";
  clientId = "00000000-0000-0000-0000-000000000000";

  # The plugins and locations of each cloud's object store.
  gcpConfig = {
    awsPlugin.enabled = false;
    extraPlugins.velero-plugin-for-gcp = {
      repository = "docker.io/velero/velero-plugin-for-gcp";
      tag = "v1.14.4";
    };
    backupStorageLocation.provider = "velero.io/gcp";
  };
  azureConfig = {
    awsPlugin.enabled = false;
    extraPlugins.velero-plugin-for-microsoft-azure = {
      repository = "docker.io/velero/velero-plugin-for-microsoft-azure";
      tag = "v1.14.4";
    };
    backupStorageLocation = {
      provider = "velero.io/azure";
      config.storageAccount = "backups";
    };
  };

  # Velero on flavour `flavorName` with `credentials ref` as its
  # cloudCredentials and `config` merged over a bucket. The namespace also
  # holds a Secret with a credentials file (`file`) and the repository key.
  veleroOn =
    {
      flavorName,
      credentials,
      config ? { },
    }:
    [
      (flavor flavorName)
      (
        { ref, ... }:
        {
          instances.velero = {
            file = {
              package = secretRefPackage;
              config.keys = [ "cloud" ];
            };
            velero-repo-credentials = {
              package = secretRefPackage;
              aliases = [ "repositoryPassword" ];
              config.keys = [ "repository-password" ];
            };
            velero = {
              package = veleroPackage;
              availability = "none";
              deps.cloudCredentials = credentials ref;
              config = lib.recursiveUpdate { backupStorageLocation.objectStorage.bucket = "b"; } config;
            };
          };
        }
      )
    ];

  aws = _: ci.aws { inherit roleArn; };
  gcp = _: ci.gcp { serviceAccount = googleAccount; };
  azure = _: ci.azure { inherit clientId; };
  fileSecret = ref: ref.velero.file;

  # What the instance renders: the ServiceAccount's annotations, the two
  # pod templates, the pod labels in the two ConfigMaps, and the location
  # specs.
  rendered =
    modules:
    let
      ms = manifests (mkCluster modules);
      podLabelsOf =
        name: key: (builtins.fromJSON (byName name (ofKind "ConfigMap" ms)).data.${key}).podLabels;
      vsl = byName "default" (ofKind "VolumeSnapshotLocation" ms);
    in
    {
      serviceAccount = (byName "velero-server" (ofKind "ServiceAccount" ms)).metadata.annotations;
      server = (byName "velero" (ofKind "Deployment" ms)).spec.template;
      nodeAgent = (byName "node-agent" (ofKind "DaemonSet" ms)).spec.template;
      nodeAgentPodLabels = podLabelsOf "velero-node-agent" "node-agent.json";
      maintenancePodLabels = podLabelsOf "velero-repo-maintenance" "global";
      backupLocation = (byName "default" (ofKind "BackupStorageLocation" ms)).spec;
      snapshotLocation = if vsl == null then null else vsl.spec;
    };

  envNames = template: map (e: e.name) (builtins.head template.spec.containers).env;
  volumeNames = template: map (v: v.name) template.spec.volumes;
  stamped = template: (template.metadata.annotations or { }) ? "checksum/cloud-identity";

  # The pod templates carry the restart stamp, and neither mounts a
  # credentials file nor sets a credential variable. No location names a
  # credential.
  ambient =
    r:
    builtins.all (t: stamped t && !(builtins.elem "cloud-credentials" (volumeNames t))) [
      r.server
      r.nodeAgent
    ]
    && !(builtins.any (
      n: lib.hasSuffix "_CREDENTIALS_FILE" n || n == "GOOGLE_APPLICATION_CREDENTIALS"
    ) (envNames r.server ++ envNames r.nodeAgent))
    && !(r.backupLocation ? credential)
    && (r.snapshotLocation == null || !(r.snapshotLocation ? credential));

  # The ids and messages of the failed assertions.
  messagesOf = modules: map (a: a.message) (failedOf modules);
  refusedWith =
    needle: modules:
    builtins.any (lib.hasInfix needle) (messagesOf modules) && evalFails (mkCluster modules);
in
{
  # On EKS the ServiceAccount carries the IAM role, and the AWS plugin and
  # kopia find it through the AWS SDK's default chain: no file, no
  # `AWS_SHARED_CREDENTIALS_FILE`, and no `credential` on either location.
  velero-cloud-identity-aws =
    let
      r = rendered (veleroOn {
        flavorName = "eks";
        credentials = aws;
        config.volumeSnapshotLocation.config.region = "eu-west-1";
      });
    in
    (
      r.serviceAccount."eks.amazonaws.com/role-arn" == roleArn
      && r.serviceAccount ? "kix.run/cloud-identity"
      && ambient r
      && r.snapshotLocation != null
      && !(r.nodeAgentPodLabels ? "azure.workload.identity/use")
    )
    || throw "velero aws: ${builtins.toJSON r}";

  # On GKE the ServiceAccount names the Google service account, and the
  # location names the account the plugin signs download URLs as.
  velero-cloud-identity-gcp =
    let
      r = rendered (veleroOn {
        flavorName = "gke";
        credentials = gcp;
        config = lib.recursiveUpdate gcpConfig {
          backupStorageLocation.config.serviceAccount = googleAccount;
        };
      });
    in
    (
      r.serviceAccount."iam.gke.io/gcp-service-account" == googleAccount
      && ambient r
      && r.backupLocation.config.serviceAccount == googleAccount
    )
    || throw "velero gcp: ${builtins.toJSON r}";

  # Without a key file, the GCP plugin refuses to start unless the location
  # names a Google service account, so the build refuses it too. Direct
  # access (`gcp { }`) builds once the location names one.
  velero-cloud-identity-gcp-needs-signing-account =
    let
      on =
        credentials: config:
        veleroOn {
          flavorName = "gke";
          inherit credentials;
          config = lib.recursiveUpdate gcpConfig config;
        };
      direct = _: ci.gcp { };
    in
    (
      refusedWith "does not set backupStorageLocation.config.serviceAccount" (on gcp { })
      && refusedWith "does not set backupStorageLocation.config.serviceAccount" (on direct { })
      && failedOf (on direct { backupStorageLocation.config.serviceAccount = googleAccount; }) == [ ]
    )
    || throw "velero gcp signing account: ${builtins.toJSON (messagesOf (on gcp { }))}";

  # On AKS the server and node-agent pods carry the workload identity label,
  # and so do the pods Velero launches: its ConfigMaps set pod labels, which
  # stops Velero copying the label from its own workloads.
  velero-cloud-identity-azure =
    let
      r = rendered (veleroOn {
        flavorName = "aks";
        credentials = azure;
        config = lib.recursiveUpdate azureConfig { backupStorageLocation.config.useAAD = "true"; };
      });
      labelled = labels: (labels."azure.workload.identity/use" or null) == "true";
    in
    (
      r.serviceAccount."azure.workload.identity/client-id" == clientId
      && ambient r
      && builtins.all labelled [
        r.server.metadata.labels
        r.nodeAgent.metadata.labels
        r.nodeAgentPodLabels
        r.maintenancePodLabels
      ]
      && r.nodeAgentPodLabels."app.kubernetes.io/component" == "data-path"
    )
    || throw "velero azure: ${builtins.toJSON r}";

  # With no credentials file, the Azure plugin reads the account settings
  # from the location: `useAAD`, or the resource group and subscription to
  # list the account keys. Either builds. An Azure snapshot location reads
  # its subscription only from a credentials file, so it is refused.
  velero-cloud-identity-azure-needs-location-settings =
    let
      on =
        config:
        veleroOn {
          flavorName = "aks";
          credentials = azure;
          config = lib.recursiveUpdate azureConfig config;
        };
      viaAAD.backupStorageLocation.config.useAAD = "true";
    in
    (
      refusedWith
        "BackupStorageLocation/default is missing required Azure storage settings in backupStorageLocation.config"
        (on { })
      && failedOf (on viaAAD) == [ ]
      &&
        failedOf (on {
          backupStorageLocation.config = {
            resourceGroup = "rg";
            subscriptionId = clientId;
          };
        }) == [ ]
      &&
        refusedWith "reads the disk subscription and resource group only from a mounted credentials file"
          (on (viaAAD // { volumeSnapshotLocation.provider = "velero.io/azure"; }))
    )
    || throw "velero azure settings: ${builtins.toJSON (messagesOf (on { }))}";

  # A Secret still works on a cloud cluster: the file form mounts it and
  # names it on the location, and the pods get no restart stamp.
  velero-cloud-identity-secret-fallback =
    let
      r = rendered (veleroOn {
        flavorName = "eks";
        credentials = fileSecret;
      });
    in
    (
      builtins.elem "cloud-credentials" (volumeNames r.server)
      && builtins.elem "AWS_SHARED_CREDENTIALS_FILE" (envNames r.server)
      && r.backupLocation.credential.key == "cloud"
      && !(stamped r.server)
      && !(r.serviceAccount ? "kix.run/cloud-identity")
    )
    || throw "velero secret: ${builtins.toJSON r}";

  # An identity for another cloud than the location's provider fails, and so
  # does one for an in-cluster store, which no cloud identity reaches. A
  # snapshot location of another cloud is refused, and one of the same
  # cloud builds.
  velero-cloud-identity-refusals =
    let
      inClusterStore = [
        (
          { ref, ... }:
          {
            instances.store.s3 = {
              package = {
                meta.version = "test";
                build =
                  { self, scope, ... }:
                  {
                    service = scope.mkResource {
                      apiVersion = "v1";
                      kind = "Service";
                      name = "s3";
                      spec.ports = [ { port = 9000; } ];
                    };
                    root = {
                      resource = self.service;
                      out.url = _: "http://s3.store.svc:9000";
                    };
                  };
              };
            };
            instances.velero.velero.deps.objectStorage = ref.store.s3;
          }
        )
      ];
      awsWith =
        config:
        veleroOn {
          flavorName = "eks";
          credentials = aws;
          inherit config;
        };
    in
    (
      evalFails (
        mkCluster (veleroOn {
          flavorName = "eks";
          credentials = aws;
          config = gcpConfig;
        })
      )
      && !(evalFails (mkCluster (awsWith { })))
      && evalFails (mkCluster (awsWith { } ++ inClusterStore))
      && !(evalFails (
        mkCluster (
          veleroOn {
            flavorName = "eks";
            credentials = fileSecret;
          }
          ++ inClusterStore
        )
      ))
      &&
        refusedWith
          "while BackupStorageLocation/default and deps.cloudCredentials use a cloud identity for AWS"
          (awsWith {
            volumeSnapshotLocation.provider = "velero.io/gcp";
          })
      &&
        failedOf (awsWith {
          volumeSnapshotLocation.provider = "aws";
        }) == [ ]
    )
    || throw "velero refusals: ${
      builtins.toJSON (
        messagesOf (awsWith {
          volumeSnapshotLocation.provider = "velero.io/gcp";
        })
      )
    }";
}
