# The errors and warnings in packages, contracts, modules, and the library
# write their fields in one form. `fieldProblem` in core/error.nix owns the
# form of each field and checks every record when it is raised. This test
# runs the same function on every literal value written in the source, so it
# also covers the records no test raises. A fix starting with a capital
# letter is a rule of this source tree only, so this test owns it.

{ lib, ... }:

let
  errors = import ../../core/error.nix { inherit lib; };

  roots = [
    ../../../packages
    ../../../contracts
    ../../../modules
    ../..
  ];

  # Return every .nix file under `dir`, as paths, leaving out the tests.
  nixFiles =
    dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" && name != "tests" then
          nixFiles (dir + "/${name}")
        else if type == "regular" && lib.hasSuffix ".nix" name then
          [ (dir + "/${name}") ]
        else
          [ ]
      ) (builtins.readDir dir)
    );

  # Return true when `line` sets `option`, `dependency`, or `clusterOption`
  # to a literal string that `fieldProblem` refuses. Each interpolation in
  # the string counts as a plain name.
  badSetting =
    line:
    let
      found = builtins.match ".*[^A-Za-z](option|dependency|clusterOption) = \"([^\"]*)\";.*" line;
      value = lib.concatMapStrings (part: if builtins.isList part then "x" else part) (
        builtins.split "\\$\\{[^}]*}" (builtins.elemAt found 1)
      );
    in
    found != null && errors.fieldProblem (builtins.elemAt found 0) value != null;

  # Return true when `line` starts a fix string with a lower-case letter.
  # `previous` is the line before it, for a fix whose string starts on the
  # next line.
  lowerFix =
    previous: line:
    builtins.match ".*[^A-Za-z]fix = (\"|''[[:space:]]*)[a-z].*" line != null
    || (
      builtins.match ".*[^A-Za-z]fix =[[:space:]]*" previous != null
      && builtins.match "[[:space:]]*(\"|'')[a-z].*" line != null
    );

  offenders =
    check:
    lib.concatMap (
      file:
      let
        lines = lib.splitString "\n" (builtins.readFile file);
      in
      lib.concatLists (
        lib.imap1 (
          n: line:
          lib.optional (check (
            if n == 1 then "" else builtins.elemAt lines (n - 2)
          ) line) "${toString file}:${toString n}"
        ) lines
      )
    ) (lib.unique (lib.concatMap nixFiles roots));

  report = what: found: found == [ ] || throw "${what}, at: ${builtins.concatStringsSep ", " found}";
in
{
  lib-error-fields-form-option = report "write each field in the form core/error.nix gives for it" (
    offenders (_: badSetting)
  );

  lib-error-fields-form-fix = report "start a fix with a capital letter" (offenders lowerFix);
}
