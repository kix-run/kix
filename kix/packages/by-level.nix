# Return the packages in `stable/` and `experimental/` as two sets, each
# holding nothing but packages, and `byName`, both sets in one. Code that
# walks every package reads this. A cluster definition reads the merged set
# in `default.nix`.
#
# Each package carries its id, which an instance of it records on its
# PackageInstance. The id is the name change records give the package.
{ lib }:
let
  levels = import ../lib/core/levels.nix { inherit lib; };
  packageLib = import ../lib/core/package.nix { inherit lib; };
  byLevel = lib.genAttrs levels.names (
    level:
    levels.list {
      dir = ./. + "/${level}";
      keep = _: type: type == "directory";
      load =
        path: name:
        lib.nameValuePair name (
          packageLib.withId (if level == "stable" then name else "${level}/${name}") (
            builtins.addErrorContext "while loading kix/packages/${level}/${name}" (import path)
          )
        );
    }
  );
in
byLevel
// {
  # A rework has the name of a stable package, and the stable one wins here.
  byName = byLevel.experimental // byLevel.stable;
}
