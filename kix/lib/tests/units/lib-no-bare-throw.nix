# Packages, contracts, and modules raise errors through scope.fail or
# kix.fail (core/error.nix), never a bare `throw`. Kix shows a `fail` error
# from its fields without a stack trace. A bare `throw` shows as raw Nix
# output and carries no instance, fix, or option.

{ lib, ... }:

let
  roots = [
    ../../../packages
    ../../../contracts
    ../../../modules
  ];

  # Return every .nix file under `dir`, as paths.
  nixFiles =
    dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" then
          nixFiles (dir + "/${name}")
        else if type == "regular" && lib.hasSuffix ".nix" name then
          [ (dir + "/${name}") ]
        else
          [ ]
      ) (builtins.readDir dir)
    );

  # Return the code part of a line, without a trailing comment.
  code = line: builtins.head (lib.splitString "#" line);

  # Return true when a line calls the `throw` builtin.
  throws = line: builtins.match ".*(^|[^A-Za-z0-9_'-])throw([^A-Za-z0-9_'-]|$).*" (code line) != null;

  offenders = lib.concatMap (
    file:
    let
      lines = lib.splitString "\n" (builtins.readFile file);
    in
    lib.concatLists (
      lib.imap1 (n: line: lib.optional (throws line) "${toString file}:${toString n}") lines
    )
  ) (lib.concatMap nixFiles roots);
in
{
  lib-no-bare-throw =
    offenders == [ ]
    || throw "use scope.fail or kix.fail, not throw, at: ${builtins.concatStringsSep ", " offenders}";
}
