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
#   holdsData       whether deleting a custom resource loses data: the
#                   clusters and their logs keep databases on their volumes,
#                   and the operator deletes a backup's files with its
#                   SGBackup. Configuration and operation kinds are false.
#
# Kinds with conditions but no readiness:
#   - SGDbOps and SGShardedDbOps set Completed=True when the operation ends,
#     which for a major version upgrade or a repack can take hours. A deploy
#     waiting on it would fail at its readiness timeout (`kix deploy
#     --timeout`, 3 minutes by default) while the operation is healthy.
#   - SGDistributedLogs sets only a Failed condition.
#   - An SGStream is Running while it streams and Completed once a finite
#     stream ends, so no one condition marks it ready.
# SGConfig has no reference (default.nix).
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
    holdsData = false;
  };
  data.holdsData = true;
in
{
  SGBackup = v1 "sgBackups" "sgbackups" // data;
  SGCluster =
    v1 "sgClusters" "sgclusters"
    // data
    // {
      readiness = bootstrapped;
    };
  SGConfig = v1 "sgConfigs" "sgconfigs";
  SGDbOps = v1 "sgDbOps" "sgdbops";
  SGDistributedLogs = v1 "sgDistributedLogs" "sgdistributedlogs" // data;
  SGInstanceProfile = v1 "sgInstanceProfiles" "sginstanceprofiles";
  SGObjectStorage = {
    part = "sgObjectStorages";
    plural = "sgobjectstorages";
    version = "v1beta1";
    holdsData = false;
  };
  SGPoolingConfig = v1 "sgPoolingConfigs" "sgpoolconfigs";
  SGPostgresConfig = v1 "sgPostgresConfigs" "sgpgconfigs";
  SGScript = v1 "sgScripts" "sgscripts";
  SGShardedBackup = v1 "sgShardedBackups" "sgshardedbackups" // data;
  SGShardedCluster = {
    part = "sgShardedClusters";
    plural = "sgshardedclusters";
    version = "v1beta1";
    servedVersions = [
      "v1beta1"
      "v1alpha1"
    ];
    readiness = bootstrapped;
    holdsData = true;
  };
  SGShardedDbOps = v1 "sgShardedDbOps" "sgshardeddbops";
  SGStream = {
    part = "sgStreams";
    plural = "sgstreams";
    version = "v1alpha1";
    holdsData = false;
  };
}
