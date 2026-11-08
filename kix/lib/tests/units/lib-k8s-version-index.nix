# Tests for the `kubernetes.version` field of `kix-packages.json`, which
# carries the definition's `k8sVersion` so the CLI can compare it with the
# Kubernetes cluster it deploys to. Loaded by ../default.nix with the other
# files in this directory.

{
  mkCluster,
  baseInstances,
  ...
}:

let
  unset = mkCluster [ baseInstances ];
  minor = mkCluster [
    baseInstances
    { k8sVersion = "1.31"; }
  ];
  vendor = mkCluster [
    baseInstances
    { k8sVersion = "v1.31.2-gke.1209000"; }
  ];
in
{
  # An unset `k8sVersion` writes `version = null`, which the CLI reads as
  # "do not compare", the same as an index from before the field existed.
  lib-k8s-version-index-unset-is-null = unset.packageIndexContent.kubernetes.version == null;

  # The index carries the version exactly as the definition writes it, so
  # the CLI compares only as precisely as the author did.
  lib-k8s-version-index-carries-the-definition-value =
    minor.packageIndexContent.kubernetes.version == "1.31"
    && vendor.packageIndexContent.kubernetes.version == "v1.31.2-gke.1209000";

  # Adding the field leaves the binding's `uid` where it was.
  lib-k8s-version-index-keeps-uid = minor.packageIndexContent.kubernetes.uid == null;
}
