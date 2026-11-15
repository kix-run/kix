# Tests for the names of removed experimental packages
# (kix/packages/removed.toml): each one fails when a cluster names it, and
# no entry shares its name with a package that exists.

{ lib, ... }:

let
  packages = import ../../../packages { inherit lib; };
  packagesByLevel = import ../../../packages/by-level.nix { inherit lib; };
  removed = map (lib.removePrefix "experimental/") (
    builtins.attrNames (builtins.fromTOML (builtins.readFile ../../../packages/removed.toml))
  );
  fails = v: !(builtins.tryEval v).success;
in
{
  removed-packages-names-fail =
    builtins.all (name: fails packages.experimental.${name}) removed
    || throw "removed-packages: a name in kix/packages/removed.toml did not fail";

  removed-packages-names-are-free =
    builtins.filter (name: packagesByLevel.experimental ? ${name}) removed == [ ]
    || throw "removed-packages: kix/packages/removed.toml names a package that exists. Remove the entry.";
}
