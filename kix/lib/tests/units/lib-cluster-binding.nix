# Tests for `cluster.kubernetes.uid`, which binds a cluster definition to
# one Kubernetes cluster: the option's validation, the `kubernetes.uid`
# field of `kix-packages.json`, and the `kix.run/kubernetes-uid` label on
# the Activation record. Loaded by ../default.nix with the other files in
# this directory.

{
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  kixKeys,
  evalFails,
  ...
}:

let
  uid = "4d7b1c2e-9f3a-4b8e-a1c5-6d2e8f0a9b3c";

  bound = mkCluster [
    baseInstances
    { cluster.kubernetes.uid = uid; }
  ];
  unbound = mkCluster [ baseInstances ];

  # Read `kix-packages.json` back as the CLI does, so the tests also cover how
  # the index is serialized. `fromJSON` refuses text that names store paths
  # with their context attached, and the paths' context does not matter here.
  indexOf =
    cluster:
    builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile cluster.packageIndex));
  recordOf = cluster: builtins.head (ofKind "Activation" (manifests cluster));
  labelOf = cluster: (recordOf cluster).metadata.labels.${kixKeys.kubernetesUidLabel} or null;
in
{
  # An unbound definition writes `uid = null` to the index and no label on
  # its record, so a build made by an older Kix reads the same way.
  lib-cluster-binding-unbound-index-and-record =
    (indexOf unbound).kubernetes ? uid
    && (indexOf unbound).kubernetes.uid == null
    && labelOf unbound == null;

  # A bound definition writes the UID to the index and labels its record.
  lib-cluster-binding-bound-index-and-record =
    (indexOf bound).kubernetes.uid == uid && labelOf bound == uid;

  # Only a lowercase UUID is accepted: Kubernetes writes UIDs that way, and
  # a context name or a typo must not pass as a binding.
  lib-cluster-binding-rejects-a-non-uuid =
    builtins.all
      (
        bad:
        evalFails (mkCluster [
          baseInstances
          { cluster.kubernetes.uid = bad; }
        ])
      )
      [
        "kind-dev"
        ""
        "4D7B1C2E-9F3A-4B8E-A1C5-6D2E8F0A9B3C"
        "4d7b1c2e-9f3a-4b8e-a1c5-6d2e8f0a9b3"
        "4d7b1c2e9f3a4b8ea1c56d2e8f0a9b3c"
      ];
}
