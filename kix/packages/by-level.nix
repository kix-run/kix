# Return the packages in `stable/` and `experimental/` as two sets, each
# holding nothing but packages. Code that walks every package reads this.
# A cluster definition reads the merged set in `default.nix`.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
in
lib.genAttrs levels.names (
  level:
  levels.list {
    dir = ./. + "/${level}";
    keep = _: type: type == "directory";
    load =
      path: name:
      lib.nameValuePair name (
        builtins.addErrorContext "while loading kix/packages/${level}/${name}" (import path)
      );
  }
)
