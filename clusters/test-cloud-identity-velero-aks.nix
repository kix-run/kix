# clusters/test-cloud-identity-velero-aks.nix: Velero on the aks flavor,
# acting as a managed identity through Microsoft Entra Workload ID.
#
# The ServiceAccount carries the client ID, and the server and node-agent
# pod templates carry the `azure.workload.identity/use` label. The node-agent
# and repository maintenance ConfigMaps give the same label to the pods
# Velero launches, because Velero copies it from its own workloads only when
# those ConfigMaps set no pod labels. The location reaches the storage
# account through Entra ID (`useAAD`), with no credentials file.
#
# Build:   kix check cloud-identity-velero-aks
{ kix, packages }:

kix.buildCluster {
  name = "cloud-identity-velero-aks";
  modules = [
    kix.flavors.aks

    {
      instances.velero = {
        velero-repo-credentials = {
          package = packages.secret-ref;
          aliases = [ "repositoryPassword" ];
          config.keys = [ "repository-password" ];
        };

        # region:veleroAksIdentity
        velero = {
          package = packages.experimental.velero;
          # One server: Velero has no leader election.
          availability = "none";
          deps.cloudCredentials = kix.cloudIdentity.azure {
            clientId = "00000000-0000-0000-0000-000000000000";
          };
          config = {
            awsPlugin.enabled = false;
            extraPlugins.velero-plugin-for-microsoft-azure = {
              repository = "docker.io/velero/velero-plugin-for-microsoft-azure";
              tag = "v1.14.4";
            };
            backupStorageLocation = {
              provider = "velero.io/azure";
              objectStorage.bucket = "velero";
              config = {
                storageAccount = "cloudidentityvelero";
                resourceGroup = "velero-backups";
                useAAD = "true";
              };
            };
          };
        };
        # endregion:veleroAksIdentity
      };
    }
  ];
}
