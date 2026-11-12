# Tests for `cluster.recordNamespace`, the namespace that holds the
# PackageInstance record of an instance under a `_`-prefixed key such as
# `instances._cluster`. Loaded by ../default.nix with the other files in
# this directory.

{
  mkCluster,
  mkCmPackage,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  priorityClassPackage = import ../../../packages/stable/priority-class;

  sentinel = {
    instances._cluster.high = {
      package = priorityClassPackage;
      config.value = 10;
    };
  };

  recordOf = name: cluster: byName name (ofKind "PackageInstance" (manifests cluster));

  # Return the cluster's failed assertions, so a test can show the
  # cross-resource checks pass with the record outside its own namespace.
  failedOf = cluster: map (a: a.message) cluster.diagnostics.failedAssertions;

  defaulted = mkCluster [
    baseInstances
    sentinel
  ];
  moved = mkCluster [
    baseInstances
    sentinel
    { cluster.recordNamespace = "kix-records"; }
  ];
in
{
  # The record defaults to kube-system and still names its instance's key.
  lib-record-namespace-default-is-kube-system =
    let
      r = recordOf "high" defaulted;
    in
    r.metadata.namespace == "kube-system"
    && r.spec.namespaceName == "_cluster"
    && failedOf defaulted == [ ]
    || throw (
      builtins.toJSON {
        inherit (r) metadata spec;
        failed = failedOf defaulted;
      }
    );

  # A cluster can move the records to a namespace that Kix does not manage.
  lib-record-namespace-override =
    let
      r = recordOf "high" moved;
    in
    r.metadata.namespace == "kix-records"
    && !(builtins.any (n: n.metadata.name == "kix-records") (ofKind "Namespace" (manifests moved)))
    && failedOf moved == [ ]
    || throw (
      builtins.toJSON {
        inherit (r) metadata;
        failed = failedOf moved;
      }
    );

  # Records of instances in real namespaces stay in their own namespace.
  lib-record-namespace-real-instances-unchanged =
    let
      r = recordOf "app" moved;
    in
    r.metadata.namespace == "appns" || throw (builtins.toJSON r.metadata);

  # A sentinel instance and an instance in the record namespace with the same
  # name would write one record. The duplicate-resource check refuses that.
  lib-record-namespace-name-clash-fails =
    let
      cluster = mkCluster [
        baseInstances
        sentinel
        {
          instances.kube-system.high.package = mkCmPackage { name = "high-settings"; };
        }
      ];
    in
    evalFails cluster;
}
