# clusters/test-cloud-identity-velero-gke.nix: Velero on the gke flavor,
# acting as a Google service account through Workload Identity Federation
# for GKE.
#
# The ServiceAccount names the Google service account in
# `iam.gke.io/gcp-service-account`. Without a key file, the GCP plugin signs
# download URLs as the account in the location's `serviceAccount`, so the
# location names the same one.
#
# Build:   kix check cloud-identity-velero-gke
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-velero-gke";
  modules = [
    kix.flavors.gke

    {
      instances.velero = {
        velero-repo-credentials = {
          package = packages.secret-ref;
          aliases = [ "repositoryPassword" ];
          config.keys = [ "repository-password" ];
        };

        # region:veleroGkeIdentity
        velero = {
          package = packages.experimental.velero;
          # One server: Velero has no leader election.
          availability = "none";
          deps.cloudCredentials = kix.cloudIdentity.gcp {
            serviceAccount = "velero@my-project.iam.gserviceaccount.com";
          };
          config = {
            awsPlugin.enabled = false;
            extraPlugins.velero-plugin-for-gcp = {
              repository = "docker.io/velero/velero-plugin-for-gcp";
              tag = "v1.14.4";
            };
            backupStorageLocation = {
              provider = "velero.io/gcp";
              objectStorage.bucket = "cloud-identity-velero-gke";
              # The account the plugin signs download URLs as.
              config.serviceAccount = "velero@my-project.iam.gserviceaccount.com";
            };
          };
        };
        # endregion:veleroGkeIdentity
      };
    }
  ];
}
