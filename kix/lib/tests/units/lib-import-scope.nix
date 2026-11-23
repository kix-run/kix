# Tests for the scope a `kix.mkImport { from }` package builds with
# (eval/import.nix mkImportScope). A builder an import does not implement
# fails through kix.fail and names the import and the scope attribute.
# `scope.fail` names the import instance.

{
  lib,
  k8s,
  eval,
  mkCluster,
  manifests,
  evalFails,
  ...
}:

let
  caughtLib = import ../caught.nix { inherit lib; };
  evalCaught = caughtLib.loadCaughtFull ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };

  importScope =
    e:
    e.mkImportScope {
      instanceName = "db";
      namespaceName = "app";
      namespaceResource = null;
      clusterDomain = "cluster.local";
    };

  # A package whose build calls `builder` on the scope before it builds
  # its root ConfigMap.
  packageUsing = builder: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = builtins.seq (scope.${builder} { name = "x"; }) (
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "db";
          }
        );
        root = self.cm;
      };
  };

  importing =
    package:
    mkCluster [
      {
        instances.app.db.package = eval.mkImport { from = package; };
      }
    ];
in
{
  lib-import-scope-unsupported-builder-names-it =
    let
      record = builtins.head (caughtLib.records ((importScope evalCaught).mkSecret.thrown or ""));
    in
    (
      lib.hasInfix "Kix cannot derive 'out' from 'from' for this kix.mkImport because the package uses scope.mkSecret." record.message
      && record.instance == "app/db"
    )
    || throw "import scope mkSecret: ${builtins.toJSON record}";

  lib-import-scope-fail-names-the-import =
    let
      record = builtins.head (
        caughtLib.records (((importScope evalCaught).fail { message = "boom"; }).thrown or "")
      );
    in
    (record.message == "boom" && record.instance == "app/db")
    || throw "import scope fail: ${builtins.toJSON record}";

  lib-import-scope-unsupported-builder-fails =
    evalFails (importing (packageUsing "mkSecret")) && evalFails (importing (packageUsing "mkCRDRef"))
    || throw "an import whose package calls mkSecret or mkCRDRef evaluated";
}
