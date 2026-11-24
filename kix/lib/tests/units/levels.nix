# Tests for the stable and experimental levels (kix/lib/core/levels.nix):
# the merged set a cluster or a package reads, the error for a name that
# has only a stable entry, the error for the old name of an entry that
# moved to experimental, the one shape every contract in kix/contracts
# has, and the id each package of Kix's own set carries.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  mkCmPackage,
  evalFails,
  manifests,
  ofKind,
  ...
}:

let
  levels = import ../../core/levels.nix { inherit lib; };
  packageLib = import ../../core/package.nix { inherit lib; };
  packages = import ../../../packages { inherit lib; };
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  contracts = kixlib.contracts;
  modules = import ../../../modules { inherit lib; };
  # Removed experimental packages keep a name that fails (removed.toml).
  removedNames = map (lib.removePrefix "experimental/") (
    builtins.attrNames (builtins.fromTOML (builtins.readFile ../../../packages/removed.toml))
  );

  fails = v: !(builtins.tryEval v).success;
  # The entries of a merged level that are not graduation errors.
  entries = lib.filterAttrs (_: v: (builtins.tryEval v).success);

  merged = levels.merge {
    prefix = "things";
    stable = {
      a = 1;
      b = 2;
    };
    experimental = {
      b = 20;
      c = 30;
    };
  };

  contractKeys = [
    "alias"
    "assertions"
    "check"
    "fields"
    "helpers"
    "name"
    "options"
    "problems"
    "require"
    "requireAs"
  ];
  # The names refused since 0.10 (kix/contracts/moved.nix) sit beside a
  # contract's parts until they are removed.
  moved = import ../../../contracts/moved.nix { inherit lib; };
  partsOf = name: contract: removeAttrs contract (builtins.attrNames (moved name));
in
{
  # Stable entries are read at the top and under `stable`, and an
  # experimental entry only under `experimental`, where it may share a
  # stable entry's name.
  levels-merge-spellings =
    (
      merged.a == 1
      && merged.b == 2
      &&
        merged.stable == {
          a = 1;
          b = 2;
        }
      && merged.experimental.b == 20
      && merged.experimental.c == 30
      && !(merged ? c)
    )
    || throw "levels merge: ${builtins.toJSON (builtins.attrNames merged)}";

  # An experimental name with only a stable entry is refused.
  levels-graduated-name-is-refused =
    fails merged.experimental.a || throw "levels: experimental.a evaluated";

  # `stable` and `experimental` cannot be entries.
  levels-reserved-names =
    fails (
      levels.merge {
        prefix = "things";
        stable.experimental = 1;
        experimental = { };
      }
    )
    || throw "levels: an entry named experimental was accepted";

  # Every stable package is read by its short name, and `packages.stable`
  # holds the packages and, for each experimental package, a marker that
  # gives the right spelling.
  levels-packages-set =
    (
      builtins.attrNames (lib.filterAttrs (_: p: (p._type or "") != "kix-moved") packages.stable)
      == builtins.attrNames packagesByLevel.stable
      && lib.all (name: packages ? ${name}) (builtins.attrNames packagesByLevel.stable)
      &&
        builtins.attrNames packages.experimental == lib.unique (
          builtins.sort builtins.lessThan (
            builtins.attrNames packagesByLevel.stable
            ++ builtins.attrNames packagesByLevel.experimental
            ++ removedNames
          )
        )
    )
    || throw "levels: packages set does not match the two folders";

  # Every contract file returns the parts `mkContract` builds and no others.
  levels-contract-shape =
    let
      wrong = lib.filterAttrs (
        name: contract: builtins.attrNames (partsOf name contract) != contractKeys
      ) (contracts.stable // entries contracts.experimental);
    in
    wrong == { }
    || throw "contracts with other parts than ${builtins.toJSON contractKeys}: ${
      builtins.toJSON (lib.mapAttrs (name: c: builtins.attrNames (partsOf name c)) wrong)
    }";

  # A stable package breaks only in a minor release, so it reads no
  # experimental contract and imports no file of an experimental package.
  levels-stable-packages-read-stable-contracts =
    let
      nixFiles =
        dir:
        lib.concatLists (
          lib.mapAttrsToList (
            name: type:
            if type == "directory" then
              nixFiles (dir + "/${name}")
            else
              lib.optional (lib.hasSuffix ".nix" name) (dir + "/${name}")
          ) (builtins.readDir dir)
        );
      readers = lib.filterAttrs (
        name: _:
        lib.any (
          file:
          let
            text = builtins.readFile file;
          in
          lib.hasInfix "contracts.experimental" text || lib.hasInfix "/experimental/" text
        ) (nixFiles (../../../packages/stable + "/${name}"))
      ) packagesByLevel.stable;
    in
    readers == { }
    || throw "stable packages that read kix.contracts.experimental or an experimental package's files: ${builtins.toJSON (builtins.attrNames readers)}. Move the package to kix/packages/experimental, or move what it reads to the stable level.";

  # A helper's old name is refused, and its new name works.
  levels-moved-helper-is-refused =
    (fails contracts.redis.usesSentinel && builtins.isFunction contracts.redis.helpers.usesSentinel)
    || throw "contracts: redis.usesSentinel evaluated";

  # The old name of a package that moved to experimental fails when an
  # instance uses it, and `availablePackages = packages` skips it.
  levels-demoted-package-is-refused =
    let
      withPackage =
        package:
        mkCluster [
          {
            instances.demo.app.package = package;
          }
        ];
      catalog = mkCluster [
        {
          availablePackages = packages;
          instances.demo.app.package = packages.echo-server;
        }
      ];
    in
    (
      evalFails (withPackage packages.dns-exporter)
      && !(evalFails (withPackage packages.experimental.dns-exporter))
      && packages.dns-exporter.error.id == "K0549"
      && lib.hasPrefix "`packages.dns-exporter` is experimental now" packages.dns-exporter.error.message
      && manifests catalog != [ ]
    )
    || throw "levels: the old name of an experimental package was accepted, or the registry read it";

  # A list of moved names must name experimental entries only.
  levels-demoted-names-are-checked =
    fails (
      levels.merge {
        prefix = "things";
        stable.a = 1;
        experimental = { };
        demoted = _: throw;
        demotedNames = [ "a" ];
        demotedId = "K0000";
      }
    )
    || throw "levels: a stable name was accepted as moved to experimental";

  # The old names of the contracts and the module that moved to experimental
  # fail, and the new names work.
  levels-demoted-contracts-and-modules =
    (
      fails contracts.oidcProvider
      && fails contracts.otlpEndpoint
      && builtins.isFunction contracts.experimental.otlpEndpoint.check
      && fails modules.monitoring
      && builtins.isPath modules.experimental.monitoring
      && modules.stable == { }
    )
    || throw "levels: an old contract or module name evaluated";

  # A dependency that only a package which moved to experimental would answer
  # from `availablePackages = packages` fails, and naming the package fixes
  # it.
  levels-moved-package-leaves-the-registry =
    let
      provider = mkCmPackage {
        name = "provider";
        metaExtra.defaultAliases = [ "thing" ];
        out.ok = true;
      };
      consumer = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            thing,
            ...
          }:
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "consumer";
              extra.data.ok = builtins.toJSON thing.out.ok;
            };
            root = self.cm;
          };
      };
      catalog = levels.merge {
        prefix = "packages";
        stable = { };
        experimental.provider = provider;
        demoted = name: error: {
          _type = "kix-moved";
          inherit name error;
          experimentalPackage = provider;
        };
        demotedNames = [ "provider" ];
        demotedId = "K0549";
      };
      withCatalog =
        availablePackages:
        mkCluster [
          {
            inherit availablePackages;
            instances.a.consumer.package = consumer;
          }
        ];
    in
    (
      evalFails (withCatalog catalog)
      && manifests (withCatalog (catalog // { inherit (catalog.experimental) provider; })) != [ ]
    )
    || throw "levels: a moved package was still offered, or naming it did not help";

  # Every package of Kix's own set carries the id change records use for
  # it, and names the arguments its function names.
  levels-package-ids =
    lib.all (
      level:
      lib.all (
        name:
        let
          package = packagesByLevel.${level}.${name};
          fn = import (../../../packages + "/${level}/${name}");
        in
        packageLib.idOf package == (if level == "stable" then name else "experimental/${name}")
        && lib.functionArgs package == builtins.functionArgs fn
      ) (builtins.attrNames packagesByLevel.${level})
    ) levels.names
    || throw "levels: a package has the wrong id, or does not name its function's arguments";

  # The old name of a moved package leads to the experimental package, so
  # it has the experimental id.
  levels-moved-package-id =
    (
      packageLib.idOf packages.dns-exporter.experimentalPackage == "experimental/dns-exporter"
      && packageLib.idOf packages.stable.dns-exporter.experimentalPackage == "experimental/dns-exporter"
    )
    || throw "levels: the old name of a moved package does not lead to the experimental id";

  # An instance records the id of its package on its PackageInstance and in
  # the build's instance info. Only a package of Kix's own set has one.
  levels-instance-records-package-id =
    let
      cluster = mkCluster [
        {
          instances.stable.app.package = packages.echo-server;
          instances.spelled.app.package = packages.stable.echo-server;
          instances.experimental.app.package = packages.experimental.dns-exporter;
          instances.inline.app.package = mkCmPackage { name = "inline"; };
          instances.function.app.package = _: mkCmPackage { name = "function"; };
          # A function that calls a Kix package is another package.
          instances.calls.app.package =
            {
              scope,
              lib,
              kix,
              availability,
            }@args:
            packages.echo-server args;
          instances.imported.app.package = eval.mkImport {
            from = packages.experimental.dns-exporter;
          };
        }
      ];
      recorded = builtins.listToAttrs (
        map (m: lib.nameValuePair m.spec.namespaceName (m.spec.package or null)) (
          ofKind "PackageInstance" (manifests cluster)
        )
      );
      listed = lib.mapAttrs (_: instances: instances.app.package) cluster.info.instances;
      expected = {
        stable = "echo-server";
        spelled = "echo-server";
        experimental = "experimental/dns-exporter";
        inline = null;
        function = null;
        calls = null;
        imported = null;
      };
    in
    (recorded == expected && listed == expected)
    || throw "levels: instances recorded ${builtins.toJSON recorded} and listed ${builtins.toJSON listed}";

  # A value that is no package is refused where Kix calls the package.
  levels-not-a-package-is-refused =
    lib.all
      (
        package:
        evalFails (mkCluster [
          { instances.demo.app = { inherit package; }; }
        ])
      )
      [
        packages.stable
        "echo-server"
        { meta.version = "1"; }
      ]
    || throw "levels: a value that is not a package was accepted as one";
}
