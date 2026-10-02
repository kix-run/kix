# The stackgres.io kinds of the release in release.nix, from the chart's
# crds/ directory at that tag. The operator installs these definitions
# itself; this table drives the CRD references, the operator's RBAC, and
# `out.crds`.
#
#   part            the part name of the CRD reference (crds.<part>)
#   plural          spec.names.plural
#   version         the storage version, which custom resources use
#   servedVersions  every served version, when there is more than one
#   readiness       the condition that marks a custom resource ready
let
  # The operator sets no Ready or Available condition on a cluster.
  # Bootstrapped=True means the primary accepts connections.
  bootstrapped.condition = {
    type = "Bootstrapped";
    status = "True";
  };
  v1 = part: plural: {
    inherit part plural;
    version = "v1";
  };
in
{
  SGBackup = v1 "sgBackups" "sgbackups";
  SGCluster = v1 "sgClusters" "sgclusters" // {
    readiness = bootstrapped;
  };
  SGConfig = v1 "sgConfigs" "sgconfigs";
  SGDbOps = v1 "sgDbOps" "sgdbops";
  SGDistributedLogs = v1 "sgDistributedLogs" "sgdistributedlogs";
  SGInstanceProfile = v1 "sgInstanceProfiles" "sginstanceprofiles";
  SGObjectStorage = {
    part = "sgObjectStorages";
    plural = "sgobjectstorages";
    version = "v1beta1";
  };
  SGPoolingConfig = v1 "sgPoolingConfigs" "sgpoolconfigs";
  SGPostgresConfig = v1 "sgPostgresConfigs" "sgpgconfigs";
  SGScript = v1 "sgScripts" "sgscripts";
  SGShardedBackup = v1 "sgShardedBackups" "sgshardedbackups";
  SGShardedCluster = {
    part = "sgShardedClusters";
    plural = "sgshardedclusters";
    version = "v1beta1";
    servedVersions = [
      "v1beta1"
      "v1alpha1"
    ];
    readiness = bootstrapped;
  };
  SGShardedDbOps = v1 "sgShardedDbOps" "sgshardeddbops";
  SGStream = {
    part = "sgStreams";
    plural = "sgstreams";
    version = "v1alpha1";
  };
}
