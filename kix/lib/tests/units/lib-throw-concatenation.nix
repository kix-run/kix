# Reject `throw "a" + "b"` and the same shape with `abort` or `fail` in
# every .nix file under kix/. Function application binds tighter than `+`,
# so Nix reads it as `(throw "a") + "b"` and prints only "a". Wrap the whole
# message in parentheses instead.
#
# The check reads one line, or one line and the next, so it misses a
# message string that holds a `"` or `#`, or one written as an indented
# string.

{ lib, ... }:

let
  root = ../../..;

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

  call = ''(^|[^A-Za-z0-9_'-])(throw|abort|fail) +"[^"]*" *'';
  joinedOnLine = line: builtins.match ".*${call}[+].*" (code line) != null;
  endsOnLine = line: builtins.match ".*${call}" (code line) != null;
  startsWithPlus = line: builtins.match " *[+].*" line != null;

  # Return `<n>` for each line of `text` that holds the shape, or ends with
  # the call while the next line starts with `+`.
  offendingLines =
    text:
    let
      lines = lib.splitString "\n" text;
      next = n: if n < builtins.length lines then builtins.elemAt lines n else "";
    in
    lib.concatLists (
      lib.imap1 (
        n: line:
        lib.optional (joinedOnLine line || (endsOnLine line && startsWithPlus (next n))) (toString n)
      ) lines
    );

  offenders = lib.concatMap (
    file: map (n: "${toString file}:${n}") (offendingLines (builtins.readFile file))
  ) (builtins.filter (f: f != ./lib-throw-concatenation.nix) (nixFiles root));
in
{
  lib-throw-concatenation-check-finds-the-shape =
    offendingLines ''
      ok = throw ("a" + "b");
      bad = throw "a ''${x}: " + y;
      worse = scope.fail "a"
        + "b";
      # comment: throw "a" + "b"
    '' == [
      "2"
      "3"
    ]
    || throw "the throw-concatenation check misread its sample";

  lib-throw-concatenation-none =
    offenders == [ ]
    || throw "wrap the whole message in parentheses, as in throw (\"a\" + \"b\"), at: ${builtins.concatStringsSep ", " offenders}";
}
