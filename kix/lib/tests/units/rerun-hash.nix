# Tests for `kix.run/rerun` and `kix.run/rerun-hash` on a Job. `scope.mkJob`
# puts every Job under the rerun rule, and the deploy engine reruns the Job
# only when this hash changes. The hash follows the Job's own manifest and the
# content of the Kix-built Secrets and ConfigMaps its pod reads. It ignores
# changes elsewhere in the graph, such as a namespace label or a resource the
# Job only waits for.

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
  # reads through env, a script ConfigMap an init container reads through
  # envFrom, a Secret imported with `mkSecretRef`, and the Job. `upstream`
  # changes the ConfigMap, `password` the Secret, `script` the script, and
  # `image` the Job's own spec. `reads = false` drops every read.
  jobPackage =
    {
      upstream ? "a",
      password ? "p",
      script ? "echo hi",
      image ? "postgres:17",
      reads ? true,
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
          script = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "script";
            data.SCRIPT = script;
          };
          external = scope.mkSecretRef {
            name = "made-elsewhere";
            keys = [ "token" ];
          };
          job = scope.mkJob {
            name = "bootstrap";
            requires = [ self.upstream ];
            spec.template = {
              metadata.labels = scope.selectorLabels;
              spec = {
                restartPolicy = "OnFailure";
                initContainers = lib.optional reads {
                  name = "prepare";
                  inherit image;
                  envFrom = [ { configMapRef.name = self.script.out.name; } ];
                };
                containers = [
                  (
                    {
                      name = "bootstrap";
                      inherit image;
                    }
                    // lib.optionalAttrs reads {
                      env = self.password.out.mkEnv { PASSWORD = "password"; } ++ [
                        {
                          name = "EXTERNAL";
                          valueFrom.secretKeyRef = {
                            name = self.external.out.name;
                            key = "token";
                          };
                        }
                      ];
                    }
                  )
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
  # A Job whose pod reads no Kix-built Secret or ConfigMap stamps its own
  # out.contentHash, so its hash does not move when nothing it reads exists.
  rerun-hash-stamped =
    let
      args.reads = false;
      out = (clusterOf args).instances.a.app.raw.job.out;
    in
    (stampOf args != null || throw "the Job should carry the content hash")
    && (
      stampOf args == builtins.unsafeDiscardStringContext out.contentHash
      || throw "the stamp should equal out.contentHash"
    );

  # `scope.mkJob` sets the rerun rule, so a package does not write it.
  rerun-set-by-mkjob =
    (jobOf { }).metadata.annotations.${kixKeys.rerun} or null == "on-change"
    || throw "scope.mkJob should set kix.run/rerun to on-change";

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

  # A new password in a Secret the Job reads through env reruns it.
  rerun-hash-follows-read-secret =
    stampOf { password = "q"; } != base
    || throw "the rerun hash should change with the Secret the Job reads";

  # A new script in a ConfigMap an init container reads through envFrom
  # reruns the Job.
  rerun-hash-follows-read-configmap =
    stampOf { script = "echo bye"; } != base
    || throw "the rerun hash should change with the ConfigMap the Job reads";

  # A read Secret or ConfigMap changes only the rerun hash. The Job's own
  # manifest, and so its pod template, stays the same.
  rerun-hash-reads-leave-manifest-alone =
    let
      ownHash =
        args: builtins.unsafeDiscardStringContext (clusterOf args).instances.a.app.raw.job.out.contentHash;
    in
    ownHash { password = "q"; } == ownHash { }
    || throw "a read Secret should not change the Job's own content hash";

  # A change to the Job's own spec changes the hash.
  rerun-hash-follows-own-spec =
    stampOf { image = "postgres:18"; } != base
    || throw "the content hash should change with the Job's spec";
}
