# The errors in packages, contracts, modules, and the library write their
# fields in one form (core/error.nix). `option` is a path in the instance's
# `config`, so it does not start with `config.`. A dependency goes in
# `dependency`, and a package's `meta` is not an option. A fix starts with a
# capital letter. `kix.fail` checks the setting fields of each error it
# raises. This test checks the written values, including errors no test
# raises.

{ lib, ... }:

let
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

  # Return true when `line` sets `option` to a path that starts with
  # `config.`, `deps.`, or `meta.`.
  badOption = line: builtins.match ".*[^A-Za-z]option = \"(config|deps|meta)\\..*" line != null;

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
  lib-error-fields-form-option =
    report "write `option` as a path in the instance's config, and a dependency as `dependency`"
      (offenders (_: badOption));

  lib-error-fields-form-fix = report "start a fix with a capital letter" (offenders lowerFix);
}
