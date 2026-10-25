# Tests for kix/packages/victoria-metrics-operator: the readiness rules its
# custom resources carry.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  ...
}:

let
  readinessOf = m: builtins.fromJSON ((m.metadata.annotations or { }).${kixKeys.readiness} or "null");
  ms = manifests (mkCluster [
    {
      instances.monitoring.vm-operator.package = import ../../../packages/victoria-metrics-operator;
      instances.monitoring.vm-cluster.package = import ../../../packages/victoria-metrics-cluster;
    }
  ]);
in
{
  # The operator writes updateStatus on a VMServiceScrape only from a VMAgent
  # or VMSingle that selects it, so the operator's own scrape is ready unless
  # a consumer rejects it. The VMCluster, which the operator reconciles
  # itself, must report operational.
  victoria-metrics-operator-config-kinds-ready-without-consumer =
    let
      scrapes = ofKind "VMServiceScrape" ms;
      clusters = ofKind "VMCluster" ms;
    in
    (
      scrapes != [ ]
      && clusters != [ ]
      && builtins.all (
        m:
        readinessOf m == {
          path = "/status/updateStatus";
          notEquals = "failed";
        }
      ) scrapes
      && builtins.all (
        m:
        readinessOf m == {
          path = "/status/updateStatus";
          equals = "operational";
        }
      ) clusters
    )
    || throw "VM readiness: scrapes ${builtins.toJSON (map readinessOf scrapes)}, clusters ${builtins.toJSON (map readinessOf clusters)}";
}
