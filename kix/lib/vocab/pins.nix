# Reading the committed record of what each image reference resolved to.
#
# Separate from `compose.nix` because that file composes Kubernetes objects in
# memory and this one reads a file off disk. It is the only piece of the
# vocabulary that touches the filesystem.
#
# Written by `kix pin`, read here. See `kix.image` in `compose.nix` for the
# reasoning about digests.
#
# Takes the path to a pin file, or an already-imported attrset (which is what
# the tests use). Returns:
#
#     .get <key>   the pin, shape-checked, ready for kix.image.ref
#     .ref <key>   sugar for `kix.image.ref (get key)`
#     .keys        every pin name in the file
#     .all         every pin, shape-checked
#
# `get` throws when the key is missing and names the command that adds it.
# That matters more than it looks: the state that produces the error is
# exactly the state in which the reader needs a remedy they can run. `get`
# and `find` are the same pair `importChart` uses (`../helm.nix`), so the
# spelling is the one a reader already knows.
#
# A pin file is JSON. Reading a Nix file would mean evaluating it, and writing
# one would mean escaping registry-supplied strings into a programming
# language by hand; neither belongs in a file a bot rewrites every build. The
# evaluation cache fingerprints `.json` alongside `.nix`
# (`cli/kix/src/eval/cache.rs`), so it lands in the fingerprint either way.
#
# What this does not do: check that the digest refers to anything. Nix
# evaluation is pure, so a well-formed invented digest passes every check
# here. `kix pin check` is what asks the registry.
{ lib, image }:

source:
let
  isPath = builtins.isPath source;
  parsed = if isPath then builtins.fromJSON (builtins.readFile source) else source;

  # A path literal inside a flake evaluates to a store path, so
  # `toString source` here is `/nix/store/<hash>-source/clusters/pins.json`
  # and naming it in an error would point the reader at a read-only copy of
  # their own file. The last two segments are what they recognise.
  where =
    if isPath then
      let
        parts = lib.splitString "/" (toString source);
        tail = lib.sublist (builtins.length parts - 2) 2 parts;
      in
      lib.concatStringsSep "/" (if builtins.length parts >= 2 then tail else parts)
    else
      "the pins attrset";

  # The version `kix pin` writes, and the only one this understands. Checked
  # rather than ignored: a file from a newer Kix read as though it were this
  # one is the failure a version field exists to prevent.
  SCHEMA_VERSION = 1;

  # `{ version, managedBy, images }` is what `kix pin` writes. A bare map of
  # pins is what a hand-written file tends to look like, and both read here.
  version = parsed.version or SCHEMA_VERSION;

  raw =
    if version != SCHEMA_VERSION then
      throw "kix.pins: ${where} declares version ${builtins.toString version}, and this Kix reads version ${builtins.toString SCHEMA_VERSION}. Upgrade Kix, or check the file."
    else
      parsed.images or parsed;

  # `repository` and `tag` are required: without both there is nothing to
  # pull. Everything else is optional, because an upstream image has no
  # source revision and a pin that has never been resolved has no digest.
  # `note` is whatever a person wanted to say about the entry; Kix never
  # reads it, and `kix.options.image` declares it so it passes through the
  # same way the other record-keeping fields do.
  known = [
    "repository"
    "tag"
    "digest"
    "sourceRev"
    "promotedBy"
    "resolvedAt"
    "note"
  ];

  checkShape =
    key: pin:
    let
      missing = builtins.filter (f: (pin.${f} or null) == null) [
        "repository"
        "tag"
      ];
      unknown = builtins.filter (f: !(builtins.elem f known)) (builtins.attrNames pin);
      digest = pin.digest or null;
      digestOk = digest == null || (builtins.match "sha256:[0-9a-f]{64}" digest) != null;
    in
    if !(builtins.isAttrs pin) then
      throw "kix.pins: pin '${key}' in ${where} is not an attribute set."
    else if missing != [ ] then
      throw "kix.pins: pin '${key}' in ${where} is missing ${builtins.concatStringsSep " and " missing}. Every pin needs a repository and a tag."
    else if unknown != [ ] then
      throw "kix.pins: pin '${key}' in ${where} has fields Kix does not know: ${builtins.concatStringsSep ", " unknown}. Known fields are ${builtins.concatStringsSep ", " known}."
    else if !digestOk then
      throw "kix.pins: pin '${key}' in ${where} has a digest that is not sha256 followed by 64 hex characters: '${digest}'. Re-resolve it with `kix pin set ${key}`."
    else
      pin;

  get =
    key:
    if raw ? ${key} then
      checkShape key raw.${key}
    else
      throw ''
        kix.pins: ${where} has no pin named '${key}'.
        Pins in that file: ${
          if raw == { } then "none yet" else builtins.concatStringsSep ", " (builtins.attrNames raw)
        }
        Add it with:
          kix pin set ${key} --repository <registry/repository> --tag <tag> --init
      '';
in
{
  inherit get;
  ref = key: image.ref (get key);
  keys = builtins.attrNames raw;
  all = lib.mapAttrs checkShape raw;
}
