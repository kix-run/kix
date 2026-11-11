# Build `kix.modules` from the module files beside this file.
#
# A module is a cluster module that declares a group of instances, such as
# a monitoring stack, behind a few options. `stable/` holds modules that
# break only in a minor release. `experimental/` holds modules that may
# break in any release. A cluster reaches them as `kix.modules.<name>` and
# `kix.modules.experimental.<name>`, where the name is the file's name.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  load =
    level:
    levels.list {
      dir = ./. + "/${level}";
      keep = file: type: type == "regular" && lib.hasSuffix ".nix" file;
      load = path: file: lib.nameValuePair (lib.removeSuffix ".nix" file) path;
    };
in
levels.merge {
  prefix = "kix.modules";
  stable = load "stable";
  experimental = load "experimental";
  demoted = throw;
  demotedNames = [ "monitoring" ];
  demotedId = "[K0549]";
}
