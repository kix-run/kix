# Tests for the cloud identity of StackGres backups, which spans two
# packages: stackgres-object-storage turns on StackGres's pod-credential
# field (`useIAMRole` for s3, `fetchCredentialsFromMetadataService` for
# gcs), writes no selectors, and publishes the cloud in `out.ambientCloud`.
# stackgres-cluster takes the identity in `deps.backupIdentity`, checks it
# against that cloud, and writes it to the SGCluster's
# `spec.metadata.annotations.serviceAccount`.

{
  lib,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  operatorPackage = import ../../../packages/experimental/stackgres-operator;
  clusterPackage = import ../../../packages/experimental/stackgres-cluster;
  objectStoragePackage = import ../../../packages/experimental/stackgres-object-storage;
  secretPackage = import ../../../packages/stable/secret;
  ci = kixlib.cloudIdentity;

  helpers = import ../caught.nix { inherit lib; };
  k8s = import ../../core { inherit lib; };
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

  roleArn = "arn:aws:iam::111122223333:role/orders-backup";
  otherRoleArn = "arn:aws:iam::111122223333:role/billing-backup";
  googleAccount = "orders-backup@example-project.iam.gserviceaccount.com";

  s3Ambient = {
    type = "s3";
    bucket = "pg-backups";
    extraSpec.s3 = {
      region = "eu-west-1";
      awsCredentials.useIAMRole = true;
    };
  };
  gcsAmbient = {
    type = "gcs";
    bucket = "pg-backups";
    extraSpec.gcs.gcpCredentials.fetchCredentialsFromMetadataService = true;
  };
  s3Secret = {
    type = "s3";
    bucket = "pg-backups";
  };

  # The operator, one object storage with `storage`, a Secret aliased
  # `storageCredentials` when `secret`, and a stackgres-cluster with backups
  # per entry of `clusters` (name -> instance attributes), on `flavorName`.
  backupsOn =
    {
      storage,
      secret ? false,
      storageDeps ? { },
      clusters ? {
        postgres = { };
      },
      flavorName ? "eks",
    }:
    [
      (flavor flavorName)
      {
        instances.stackgres-system.stackgres-operator.package = operatorPackage;
        instances.data = {
          backups = {
            package = objectStoragePackage;
            config = storage;
            deps = storageDeps;
          };
        }
        // lib.optionalAttrs secret {
          s3-credentials = {
            package = secretPackage;
            aliases = [ "storageCredentials" ];
            config.stringData = {
              accessKeyId = "id";
              secretAccessKey = "key";
            };
          };
        }
        // lib.mapAttrs (
          _: inst:
          lib.recursiveUpdate {
            package = clusterPackage;
            config.backups = [ { } ];
          } inst
        ) clusters;
      }
    ];

  ms = args: manifests (mkCluster (backupsOn args));
  sgCluster = name: m: byName name (ofKind "SGCluster" m);
  objectStorage = m: byName "backups" (ofKind "SGObjectStorage" m);
  ambientCloudOf =
    args: (mkCluster (backupsOn args)).instances.data.backups.raw.root.out.ambientCloud;
  saAnnotations = name: m: (sgCluster name m).spec.metadata.annotations.serviceAccount or { };
  ids = failed: map (a: a.id or null) failed;
  saysIn =
    fragment: failed: builtins.any (a: lib.hasInfix fragment (a.message + " " + (a.fix or ""))) failed;
in
{
  # On EKS, an s3 store with `useIAMRole` writes no selectors and publishes
  # "aws". The cluster's AWS role reaches the patroni ServiceAccount's
  # annotations, with the record Kix keeps of it.
  stackgres-backup-identity-aws =
    let
      args = {
        storage = s3Ambient;
        clusters.postgres.deps.backupIdentity = ci.aws { inherit roleArn; };
      };
      m = ms args;
      creds = (objectStorage m).spec.s3.awsCredentials;
      ann = saAnnotations "postgres" m;
    in
    (
      failedOf (backupsOn args) == [ ]
      && creds == { useIAMRole = true; }
      && ambientCloudOf args == "aws"
      && ann."eks.amazonaws.com/role-arn" == roleArn
      &&
        builtins.fromJSON ann.${kixKeys.cloudIdentity} == {
          mechanism = "irsa";
          aws = { inherit roleArn; };
        }
      && !((sgCluster "postgres" m).spec.metadata ? labels)
    )
    || throw "aws: ${builtins.toJSON { inherit creds ann; }}";

  # On GKE, a gcs store with `fetchCredentialsFromMetadataService` publishes
  # "gcp", and a Google service account reaches the annotations. Without a
  # service account only the record is written.
  stackgres-backup-identity-gcp =
    let
      args = identity: {
        flavorName = "gke";
        storage = gcsAmbient;
        clusters.postgres.deps.backupIdentity = identity;
      };
      m = ms (args (ci.gcp { serviceAccount = googleAccount; }));
      bare = saAnnotations "postgres" (ms (args (ci.gcp { })));
      ann = saAnnotations "postgres" m;
    in
    (
      (objectStorage m).spec.gcs.gcpCredentials == {
        fetchCredentialsFromMetadataService = true;
      }
      && ambientCloudOf (args null) == "gcp"
      && ann."iam.gke.io/gcp-service-account" == googleAccount
      && builtins.attrNames bare == [ kixKeys.cloudIdentity ]
    )
    || throw "gcp: ${builtins.toJSON { inherit ann bare; }}";

  # Without `backupIdentity`, pod credentials still build: the pods use the
  # node's credentials, and the SGCluster carries no identity.
  stackgres-backup-identity-node-credentials =
    let
      args.storage = s3Ambient;
      m = ms args;
    in
    (
      failedOf (backupsOn args) == [ ]
      && !((sgCluster "postgres" m).spec ? metadata)
      && (objectStorage m).spec.s3.awsCredentials == { useIAMRole = true; }
    )
    || throw "node credentials: ${builtins.toJSON (sgCluster "postgres" m).spec}";

  # A Secret still works: the store names its keys and publishes null.
  stackgres-backup-identity-secret =
    let
      args = {
        storage = s3Secret;
        secret = true;
      };
      creds = (objectStorage (ms args)).spec.s3.awsCredentials;
    in
    (
      failedOf (backupsOn args) == [ ]
      && ambientCloudOf args == null
      &&
        creds.secretKeySelectors.accessKeyId == {
          name = "s3-credentials";
          key = "accessKeyId";
        }
      && !(creds ? useIAMRole)
    )
    || throw "secret: ${builtins.toJSON creds}";

  # Two clusters on one store take separate roles, each on its own
  # ServiceAccount.
  stackgres-backup-identity-two-clusters =
    let
      m = ms {
        storage = s3Ambient;
        clusters = {
          orders.deps.backupIdentity = ci.aws { inherit roleArn; };
          billing.deps.backupIdentity = ci.aws { roleArn = otherRoleArn; };
        };
      };
    in
    (
      (saAnnotations "orders" m)."eks.amazonaws.com/role-arn" == roleArn
      && (saAnnotations "billing" m)."eks.amazonaws.com/role-arn" == otherRoleArn
      &&
        (sgCluster "orders" m).spec.configurations.backups == (sgCluster "billing" m)
        .spec.configurations.backups
    )
    || throw "two clusters";

  # The storage refuses the pod-credential field beside a Secret (K5962),
  # neither of them, the field on a type StackGres reads it for not, and
  # `credentialKeys` with no Secret to read. Each has a passing pair above
  # or here.
  stackgres-backup-identity-storage-refusals =
    let
      both = failedOf (backupsOn {
        storage = s3Ambient;
        secret = true;
      });
      neither = failedOf (backupsOn {
        storage = s3Secret;
      });
      onType =
        type: block:
        failedOf (backupsOn {
          storage = {
            inherit type;
            bucket = "pg-backups";
            extraSpec.${type}.${block}.useIAMRole = true;
          };
        });
      compatible = onType "s3Compatible" "awsCredentials";
      azure = onType "azureBlob" "azureCredentials";
      wrongField = onType "gcs" "gcpCredentials";
      keys = failedOf (backupsOn {
        storage = s3Ambient // {
          credentialKeys.accessKeyId = "id";
        };
      });
      azureSecret = failedOf (backupsOn {
        storage = {
          type = "azureBlob";
          bucket = "pg-backups";
        };
      });
    in
    (
      ids both == [ "K5962" ]
      && saysIn "remove `deps.storageCredentials`" both
      && saysIn "`deps.storageCredentials` is unset, and `extraSpec.s3.awsCredentials.useIAMRole` is not `true`" neither
      && builtins.elem "K5962" (ids compatible)
      && saysIn "StackGres supports pod credentials only on `s3`" compatible
      && saysIn "StackGres supports pod credentials only on `s3`" azure
      && saysIn "Replace that setting with `extraSpec.gcs.gcpCredentials.fetchCredentialsFromMetadataService = true`" wrongField
      && saysIn "`credentialKeys` sets `accessKeyId`" keys
      && !(saysIn "StackGres supports pod credentials" azureSecret)
    )
    || throw "storage refusals: ${
      builtins.toJSON {
        inherit
          both
          neither
          compatible
          keys
          ;
      }
    }";

  # A cloud identity given to the storage is refused (it goes on the
  # clusters), and so are selectors written through extraSpec beside the
  # pod-credential field.
  stackgres-backup-identity-storage-build-refusals =
    (
      evalFails (
        mkCluster (backupsOn {
          storage = s3Ambient;
          storageDeps.storageCredentials = ci.aws { inherit roleArn; };
        })
      )
      && evalFails (
        mkCluster (backupsOn {
          storage = lib.recursiveUpdate s3Ambient {
            extraSpec.s3.awsCredentials.secretKeySelectors.accessKeyId = {
              name = "other";
              key = "id";
            };
          };
        })
      )
      && !(evalFails (
        mkCluster (backupsOn {
          storage = s3Ambient;
        })
      ))
    )
    || throw "storage build refusals";

  # The cluster refuses an identity when the store reads a Secret, for
  # another cloud, without backups, or in place of a Secret, and refuses
  # extraSpec that replaces the identity's annotation. Other ServiceAccount
  # annotations in extraSpec are kept.
  stackgres-backup-identity-cluster-refusals =
    let
      withIdentity =
        args: identity:
        mkCluster (
          backupsOn (
            removeAttrs args [ "postgres" ]
            // {
              clusters.postgres = {
                deps.backupIdentity = identity;
              }
              // (args.postgres or { });
            }
          )
        );
      aws = ci.aws { inherit roleArn; };
      kept = saAnnotations "postgres" (
        manifests (
          withIdentity {
            storage = s3Ambient;
            postgres.config.extraSpec.metadata.annotations.serviceAccount."example.com/team" = "orders";
          } aws
        )
      );
    in
    (
      evalFails (
        withIdentity {
          storage = s3Secret;
          secret = true;
        } aws
      )
      && evalFails (withIdentity { storage = s3Ambient; } (ci.gcp { }))
      && evalFails (
        withIdentity {
          storage = s3Ambient;
          postgres.config.backups = null;
        } aws
      )
      && evalFails (
        mkCluster (
          backupsOn { storage = s3Ambient; }
          ++ [
            (
              { ref, ... }:
              {
                instances.data.other-secret = {
                  package = secretPackage;
                  config.stringData.key = "value";
                };
                instances.data.postgres.deps.backupIdentity = ref.data.other-secret;
              }
            )
          ]
        )
      )
      && evalFails (
        withIdentity {
          storage = s3Ambient;
          postgres.config.extraSpec.metadata.annotations.serviceAccount."eks.amazonaws.com/role-arn" =
            otherRoleArn;
        } aws
      )
      && kept."example.com/team" == "orders"
      && kept."eks.amazonaws.com/role-arn" == roleArn
      && !(evalFails (withIdentity { storage = s3Ambient; } aws))
    )
    || throw "cluster refusals: kept ${builtins.toJSON kept}";
}
