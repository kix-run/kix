# clusters/test-cloud-identity-velero-eks.nix: Velero on the eks flavor,
# acting as an IAM role through IAM roles for service accounts (IRSA).
#
# The server, node-agent, and the pods they launch share one ServiceAccount,
# which carries the role ARN. The pods get no credentials file and no
# `AWS_SHARED_CREDENTIALS_FILE`, and the locations name no `credential`, so
# the AWS plugin and kopia use the AWS SDK's default credential chain. An EBS
# snapshot location uses the same role.
#
# Build:   kix check cloud-identity-velero-eks
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-velero-eks";
  modules = [
    kix.flavors.eks

    {
      instances.velero = {
        # A Secret created outside Kix with the kopia repository key.
        velero-repo-credentials = {
          package = packages.secret-ref;
          aliases = [ "repositoryPassword" ];
          config.keys = [ "repository-password" ];
        };

        # region:veleroEksIdentity
        velero = {
          package = packages.experimental.velero;
          # One server: Velero has no leader election.
          availability = "none";
          deps.cloudCredentials = kix.cloudIdentity.aws {
            roleArn = "arn:aws:iam::111122223333:role/velero";
          };
          config = {
            backupStorageLocation = {
              objectStorage.bucket = "cloud-identity-velero-eks";
              config.region = "eu-west-1";
            };
            volumeSnapshotLocation.config.region = "eu-west-1";
          };
        };
        # endregion:veleroEksIdentity
      };
    }
  ];
}
