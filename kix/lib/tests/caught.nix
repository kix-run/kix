# Helpers for reading the text of a refusal, which `builtins.tryEval` drops.
#
# `caught` loads a file with `throw` bound to a function that returns
# `{ thrown = <message>; }`. `kix.fail` (core/error.nix) is loaded the same
# way, so errors raised through it are caught too. `thrown` then holds the
# full rendered text, ending in the `kix-error/1` line.
{ lib }:
let
  caught = builtins.scopedImport {
    throw = message: { thrown = message; };
    import = path: if baseNameOf path == "error.nix" then caught path else import path;
  };
  marker = "kix-error/1 ";
  # Return the error records in a thrown message, parsed from its marker line.
  records =
    thrown:
    let
      line = lib.findFirst (lib.hasPrefix marker) null (lib.splitString "\n" thrown);
    in
    if line == null then
      throw "no kix-error/1 line in: ${thrown}"
    else
      (builtins.fromJSON (lib.removePrefix marker line)).errors;

  # Return the records of a thrown message as one line each, `message` then
  # `fix`, or the message itself when it has no marker line.
  sentences =
    thrown:
    if lib.hasInfix "\n${marker}" thrown then
      lib.concatMapStringsSep "\n" (r: r.message + lib.optionalString (r ? fix) " ${r.fix}") (
        records thrown
      )
    else
      thrown;

  # Like `caught`, with `thrown` reduced to `sentences`.
  caughtSentences =
    let
      load = builtins.scopedImport {
        throw = message: { thrown = sentences message; };
        import = path: if baseNameOf path == "error.nix" then load path else import path;
      };
    in
    load;

  # Load `path` and every file it imports so that `kix.fail` and
  # `scope.fail` return `{ thrown = <sentences>; }`. A plain `throw` still
  # throws.
  loadCaught =
    path:
    builtins.scopedImport {
      import = p: if baseNameOf p == "error.nix" then caughtSentences p else loadCaught p;
    } path;

  # Like `loadCaught`, with `thrown` holding the full text, so `records`
  # can read the fields of each error.
  loadCaughtFull =
    path:
    builtins.scopedImport {
      import = p: if baseNameOf p == "error.nix" then caught p else loadCaughtFull p;
    } path;
in
{
  inherit
    caught
    caughtSentences
    records
    sentences
    loadCaught
    loadCaughtFull
    ;
}
