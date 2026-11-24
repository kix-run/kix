# clusters/test-cloud-identity-stackgres.nix: StackGres backups to S3 with
# cloud identities on the eks flavor, which gives pods AWS identities
# through IAM roles for service accounts (IRSA).
#
# - `orders/backups` is one SGObjectStorage with
#   `s3.awsCredentials.useIAMRole = true`, so it writes no secret key
#   selectors and takes no Secret.
# - `orders/orders` and `orders/billing` back up to it with separate IAM
#   roles. The operator creates each cluster's `<cluster>-patroni`
#   ServiceAccount from the SGCluster's
#   `spec.metadata.annotations.serviceAccount`, which carries the role ARN
#   and `kix.run/cloud-identity`. Kix does not build those pods, so they
#   carry no `checksum/cloud-identity`.
# - `orders/reports` backs up to the same store with no identity, so its
#   pods use the node's IAM role.
# - `keys/backups` reads AWS access keys from a Secret created outside Kix,
#   and `keys/postgres` backs up there with no identity.
#
# Build:   kix check cloud-identity-stackgres
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-stackgres";
  modules = [
    kix.flavors.eks

    {
      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

      # region:stackgresIrsaInstances
      instances.orders = {
        backups = {
          package = packages.experimental.stackgres-object-storage;
          config = {
            type = "s3";
            bucket = "example-pg-backups";
            extraSpec.s3 = {
              region = "eu-west-1";
              awsCredentials.useIAMRole = true;
            };
          };
        };

        orders = {
          package = packages.experimental.stackgres-cluster;
          deps.backupIdentity = kix.cloudIdentity.aws {
            roleArn = "arn:aws:iam::111122223333:role/orders-backup";
          };
          config.backups = [ { path = "orders"; } ];
        };
        # endregion:stackgresIrsaInstances

        billing = {
          package = packages.experimental.stackgres-cluster;
          deps.backupIdentity = kix.cloudIdentity.aws {
            roleArn = "arn:aws:iam::111122223333:role/billing-backup";
          };
          config.backups = [ { path = "billing"; } ];
        };

        reports = {
          package = packages.experimental.stackgres-cluster;
          config.backups = [ { path = "reports"; } ];
        };
      };

      instances.keys = {
        # A Secret created outside Kix with the keys accessKeyId and
        # secretAccessKey.
        backup-keys = {
          package = packages.secret-ref;
          aliases = [ "storageCredentials" ];
          config.keys = [
            "accessKeyId"
            "secretAccessKey"
          ];
        };

        backups = {
          package = packages.experimental.stackgres-object-storage;
          config = {
            type = "s3";
            bucket = "example-pg-backups-keys";
            extraSpec.s3.region = "eu-west-1";
          };
        };

        postgres = {
          package = packages.experimental.stackgres-cluster;
          config.backups = [ { } ];
        };
      };
    }
  ];
}
