# Generate the package catalog under `reference/package-catalog/`.
#
# `catalogData` reads every package in `kix/packages/stable/` and
# `kix/packages/experimental/` and returns plain data: its `meta`, its
# options as `lib.optionAttrSetToDocList` describes them, and the
# dependencies its `build` functions name. `mkCatalog` hands that data, with
# the how-to ledger, to `docs/scripts/package-catalog.py`, which writes one
# MDX page per package and an index page. The pages are build output, so
# nothing in the docs tree can fall behind the packages.
#
# A package function is called as `kix list packages` calls it, with an
# empty `scope` and `availability = "none"`. Its `meta` and `options` must
# not depend on either.

{
  pkgs,
  lib,
  # The repository checkout the packages are read from.
  root,
  # The URL of `root` on GitHub, for the links to each package's source.
  sourceUrlBase,
}:

let
  levels = import (root + "/kix/lib/core/levels.nix") { inherit lib; };
  byLevel = import (root + "/kix/packages/by-level.nix") { inherit lib; };
  packageLib = import (root + "/kix/lib/core/package.nix") { inherit lib; };
  kix = import (root + "/kix/lib/vocab") { inherit lib; };
  resolve = import (root + "/kix/lib/eval/resolve.nix") {
    inherit lib;
    kixlib = kix;
  };

  # The fields of an option that a page shows. A default or example is
  # already rendered as `{ _type; text; }` by `optionAttrSetToDocList`.
  optionData =
    o:
    {
      inherit (o) name type;
      description = o.description or null;
      readOnly = o.readOnly or false;
    }
    // lib.optionalAttrs (o ? default) { inherit (o) default; }
    // lib.optionalAttrs (o ? example) { inherit (o) example; };

  packageData =
    level: name: package:
    let
      id = packageLib.idOf package;
      definition = packageLib.call {
        inherit package kix;
        scope = { };
      };
      meta = packageLib.metaFrom definition;
      options =
        (lib.evalModules {
          modules = [ { options = definition.options or { }; } ];
        }).options;
      docs = lib.optionAttrSetToDocList (removeAttrs options [ "_module" ]);
      data = {
        inherit name level id;
        spelling = packageLib.spellingOf package;
        source = "${sourceUrlBase}/kix/packages/${level}/${name}";
        meta = {
          description = meta.description or null;
          version = meta.version or null;
          roles = meta.roles or [ ];
          defaultAliases = meta.defaultAliases or [ ];
          availabilityMax = meta.availability.max or null;
          deprecated = meta.deprecated or null;
        };
        options = map optionData (builtins.filter (o: o.visible && !o.internal) docs);
        dependencies = lib.mapAttrsToList (arg: d: {
          name = arg;
          inherit (d) optional;
        }) (resolve.discoverBuildDeps (definition.build or [ ]));
      };
    in
    # Force the data here so that an error names the package.
    builtins.addErrorContext "while reading kix/packages/${level}/${name} for the package catalog" (
      builtins.deepSeq data data
    );

  catalogData = lib.concatMap (
    level: lib.mapAttrsToList (packageData level) byLevel.${level}
  ) levels.names;

  mkCatalog =
    { ledger, guides }:
    pkgs.runCommand "kix-package-catalog"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        data = builtins.toJSON catalogData;
        passAsFile = [ "data" ];
      }
      ''
        python3 ${../scripts/package-catalog.py} \
          --data "$dataPath" \
          --ledger ${ledger} \
          --guides ${guides} \
          --out "$out"
      '';
in
{
  inherit catalogData mkCatalog;
}
