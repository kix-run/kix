# Tests for the names of removed experimental packages
# (kix/packages/removed.toml): each one fails when a cluster names it, under
# `packages.experimental.<name>` and `packages.<name>`, and no entry shares
# its name with a package that exists.

{
  lib,
  mkCluster,
  evalFails,
  manifests,
  ...
}:

let
  packages = import ../../../packages { inherit lib; };
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  entries = builtins.fromTOML (builtins.readFile ../../../packages/removed.toml);
  removed = map (lib.removePrefix "experimental/") (builtins.attrNames entries);
  fails = v: !(builtins.tryEval v).success;
  withPackage =
    package:
    mkCluster [
      {
        instances.demo.app.package = package;
      }
    ];
in
{
  removed-packages-names-fail =
    builtins.all (name: fails packages.experimental.${name}) removed
    || throw "removed-packages: a name in kix/packages/removed.toml did not fail";

  # The top-level name is a marker that carries the entry's error. An
  # instance that uses it fails, and `availablePackages = packages` skips it.
  removed-packages-old-names-are-refused =
    (
      builtins.all (
        name:
        evalFails (withPackage packages.${name}) && packages.${name}.error == entries."experimental/${name}"
      ) removed
      &&
        manifests (mkCluster [
          {
            availablePackages = packages;
            instances.demo.app.package = packages.echo-server;
          }
        ]) != [ ]
    )
    || throw "removed-packages: the top-level name of a removed package was accepted, or the registry read it";

  removed-packages-names-are-free =
    builtins.filter (name: packagesByLevel.experimental ? ${name}) removed == [ ]
    || throw "removed-packages: kix/packages/removed.toml names a package that exists. Remove the entry.";
}
