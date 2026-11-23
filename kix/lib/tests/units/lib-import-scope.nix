# Tests for the scope a `kix.mkImport { from }` package builds with
# (eval/import.nix mkImportScope). It offers every name of the package
# scope. A builder an import does not implement fails through kix.fail and
# names the import and the scope attribute.

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
  evalCaught = (import ../caught.nix { inherit lib; }).loadCaught ../../eval {
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

  packageScopeNames = builtins.attrNames (
    eval.mkScope {
      instanceName = "db";
      namespaceName = "app";
      namespaceResource = null;
      clusterDomain = "cluster.local";
    }
  );

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
  lib-import-scope-offers-every-package-scope-name =
    lib.subtractLists (builtins.attrNames (importScope eval)) packageScopeNames == [ ]
    || throw "the import scope lacks: ${toString (lib.subtractLists (builtins.attrNames (importScope eval)) packageScopeNames)}";

  lib-import-scope-unsupported-builder-names-it =
    let
      thrown = (importScope evalCaught).mkSecret.thrown or "";
    in
    lib.hasInfix "the package uses scope.mkSecret, which an import does not offer." thrown
    || throw "import scope mkSecret: ${thrown}";

  lib-import-scope-unsupported-builder-fails =
    evalFails (importing (packageUsing "mkSecret"))
    && evalFails (importing (packageUsing "mkCRDRef"))
    && evalFails (importing (packageUsing "fail"))
    || throw "an import whose package calls mkSecret, mkCRDRef, or fail evaluated";
}
