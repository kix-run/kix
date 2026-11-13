# Tests for the warning on a Job under `kix.run/rerun` that reads a Kix-built
# Secret or ConfigMap without a `checksum/*` annotation for it. The deploy
# engine reruns such a Job only when its own manifest changes, so without the
# annotation a new value in the Secret never reaches it.

{
  lib,
  kixKeys,
  mkCluster,
  ...
}:

let
  # A package whose rerun Job reads a Kix-built Secret through env, a
  # Kix-built ConfigMap through a volume, and a Secret something outside Kix
  # writes, imported with `mkSecretRef`. `checksums` lists which of the two Kix-built objects the pod
  # template hashes.
  jobPackage =
    {
      checksums ? [ ],
      rerun ? true,
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          password = scope.mkSecret {
            name = "pw";
            stringData.password = "p";
          };
          script = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "script";
            data."run.sh" = "echo hi";
          };
          external = scope.mkSecretRef {
            name = "made-elsewhere";
            keys = [ "token" ];
          };
          job = scope.mkJob {
            name = "bootstrap";
            annotations = lib.optionalAttrs rerun { ${kixKeys.rerun} = "on-change"; };
            spec.template = {
              metadata = {
                labels = scope.selectorLabels;
                annotations =
                  lib.optionalAttrs (builtins.elem "password" checksums) {
                    "checksum/pw" = self.password.out.contentHash;
                  }
                  // lib.optionalAttrs (builtins.elem "script" checksums) {
                    "checksum/script" = self.script.out.contentHash;
                  };
              };
              spec = {
                restartPolicy = "OnFailure";
                volumes = [
                  {
                    name = "script";
                    configMap.name = self.script.out.name;
                  }
                ];
                containers = [
                  {
                    name = "bootstrap";
                    image = "postgres:17";
                    env = self.password.out.mkEnv { PASSWORD = "password"; } ++ [
                      {
                        name = "EXTERNAL";
                        valueFrom.secretKeyRef = {
                          name = self.external.out.name;
                          key = "token";
                        };
                      }
                    ];
                    volumeMounts = [
                      {
                        name = "script";
                        mountPath = "/scripts";
                      }
                    ];
                  }
                ];
              };
            };
          };
          root = self.job;
        };
    };

  warningsOf =
    args:
    builtins.filter (lib.hasInfix "no checksum annotation")
      (mkCluster [ { instances.a.app.package = jobPackage args; } ]).diagnostics.warnings;

  mentions = needle: ws: builtins.any (lib.hasInfix needle) ws;
in
{
  # Both Kix-built reads lack a checksum, so each gets a warning, and the
  # Secret imported with mkSecretRef gets none.
  rerun-checksums-warn-missing =
    let
      ws = warningsOf { };
    in
    (builtins.length ws == 2 || throw "expected two warnings, got ${builtins.toJSON ws}")
    && (mentions "reads Secret pw" ws || throw "the Secret read should warn: ${builtins.toJSON ws}")
    && (
      mentions "reads ConfigMap script" ws
      || throw "the ConfigMap read should warn: ${builtins.toJSON ws}"
    )
    && (mentions "Job a/bootstrap" ws || throw "the warning should name the Job: ${builtins.toJSON ws}")
    && (
      !(mentions "made-elsewhere" ws)
      || throw "a Secret Kix does not build should not warn: ${builtins.toJSON ws}"
    );

  # A checksum annotation from the object's contentHash covers its read.
  rerun-checksums-silent-when-present =
    let
      ws = warningsOf { checksums = [ "password" ]; };
    in
    (builtins.length ws == 1 || throw "expected one warning, got ${builtins.toJSON ws}")
    && (mentions "reads ConfigMap script" ws || throw "the ConfigMap read should still warn");

  rerun-checksums-silent-when-all-present =
    warningsOf {
      checksums = [
        "password"
        "script"
      ];
    } == [ ]
    || throw "a Job that hashes everything it reads should not warn";

  # A Job without the rerun annotation is replaced on any change, so the
  # check skips it.
  rerun-checksums-only-rerun-jobs =
    warningsOf { rerun = false; } == [ ] || throw "a Job without kix.run/rerun should not warn";

  # The warning reaches the file the CLI reads.
  rerun-checksums-in-warnings-file =
    let
      cluster = mkCluster [ { instances.a.app.package = jobPackage { }; } ];
      listed = builtins.fromJSON (builtins.readFile cluster.activationFiles.warnings);
    in
    mentions "reads Secret pw" listed || throw "kix-warnings.json should list the warning";
}
