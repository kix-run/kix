# Tests for `kix.run/rerun-hash` on a Job under `kix.run/rerun`. The deploy
# engine reruns such a Job only when this hash changes. It follows the Job's
# own manifest, including the `checksum/*` annotations on its pod template,
# and ignores changes elsewhere in the graph, such as a namespace label or a
# resource the Job only waits for.

{
  lib,
  kixKeys,
  mkCluster,
  manifests,
  byName,
  ...
}:

let
  # A package with a ConfigMap the Job waits for, a password Secret the Job
  # reads, and the Job. `upstream` changes the ConfigMap, `password` the
  # Secret, and `image` the Job's own spec.
  jobPackage =
    {
      upstream ? "a",
      password ? "p",
      image ? "postgres:17",
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          upstream = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "upstream";
            data.value = upstream;
          };
          password = scope.mkSecret {
            name = "pw";
            stringData.password = password;
          };
          job = scope.mkJob {
            name = "bootstrap";
            annotations.${kixKeys.rerun} = "on-change";
            requires = [ self.upstream ];
            spec.template = {
              metadata = {
                labels = scope.selectorLabels;
                annotations."checksum/password" = self.password.out.contentHash;
              };
              spec = {
                restartPolicy = "OnFailure";
                containers = [
                  {
                    name = "bootstrap";
                    inherit image;
                    env = self.password.out.mkEnv { PASSWORD = "password"; };
                  }
                ];
              };
            };
          };
          root = self.job;
        };
    };

  clusterOf =
    {
      nsLabels ? { },
      ...
    }@args:
    mkCluster [
      {
        namespaces.a.labels = nsLabels;
        instances.a.app.package = jobPackage (removeAttrs args [ "nsLabels" ]);
      }
    ];

  jobOf = args: byName "bootstrap" (manifests (clusterOf args));
  stampOf = args: (jobOf args).metadata.annotations.${kixKeys.rerunHash} or null;
  identityOf =
    args: builtins.unsafeDiscardStringContext (clusterOf args).instances.a.app.raw.job.out.identityHash;

  base = stampOf { };
in
{
  # The stamp is the Job's own out.contentHash.
  rerun-hash-stamped =
    let
      out = (clusterOf { }).instances.a.app.raw.job.out;
    in
    (base != null || throw "the Job should carry the content hash")
    && (
      base == builtins.unsafeDiscardStringContext out.contentHash
      || throw "the stamp should equal out.contentHash"
    );

  # Only a resource under the rerun rule carries the stamp.
  rerun-hash-only-on-rerun =
    !((byName "upstream" (manifests (clusterOf { }))).metadata.annotations or { })
    ? ${kixKeys.rerunHash}
    || throw "a ConfigMap without the rerun annotation should not carry the content hash";

  # A label on the namespace moves the Job's identity hash and leaves its
  # content hash alone, so the Job does not run again.
  rerun-hash-ignores-namespace-label =
    let
      args.nsLabels."example.com/team" = "db";
    in
    (identityOf args != identityOf { } || throw "the identity hash should change with the namespace")
    && (stampOf args == base || throw "the content hash should not change with a namespace label");

  # A change to a resource the Job only waits for leaves its content hash
  # alone.
  rerun-hash-ignores-dependency =
    let
      args.upstream = "b";
    in
    (identityOf args != identityOf { } || throw "the identity hash should change with the ConfigMap")
    && (stampOf args == base || throw "the content hash should not change with a dependency");

  # A new password reaches the Job through its checksum annotation.
  rerun-hash-follows-read-secret =
    stampOf { password = "q"; } != base
    || throw "the content hash should change with the Secret the Job reads";

  # A change to the Job's own spec changes the hash.
  rerun-hash-follows-own-spec =
    stampOf { image = "postgres:18"; } != base
    || throw "the content hash should change with the Job's spec";
}
