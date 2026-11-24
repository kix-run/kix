# Helpers for the tests that read Kix's own .nix source line by line.
{ lib }:
rec {
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

  # Return the code part of a line, without a trailing comment. A `#`
  # inside a string also ends the code part.
  code = line: builtins.head (lib.splitString "#" line);
}
