# Read image references from a pin file or an attrset. The returned interface is:
#
#     .get <key>   the pin, shape-checked, ready for kix.image.ref
#     .ref <key>   sugar for `kix.image.ref (get key)`
#     .keys        every pin name in the file
#     .all         every pin, shape-checked
#
# `get` validates the entry and reports the command for adding a missing key.
#
# Pin files use JSON so Kix can rewrite registry values as data without
# evaluating them as Nix. The evaluation cache includes JSON files in its
# input fingerprint (`cli/kix/src/eval/cache.rs`).
#
# Shape validation does not verify a digest against a registry. Use
# `kix pin check` for registry verification.
{ lib, image }:

source:
let
  isPath = builtins.isPath source;
  parsed = if isPath then builtins.fromJSON (builtins.readFile source) else source;

  # Flake path literals evaluate to store paths. Show the last two components
  # in errors so they identify the source file rather than its store copy.
  where =
    if isPath then
      let
        parts = lib.splitString "/" (toString source);
        tail = lib.sublist (builtins.length parts - 2) 2 parts;
      in
      lib.concatStringsSep "/" (if builtins.length parts >= 2 then tail else parts)
    else
      "the pins attrset";

  # Reject other schema versions before interpreting their fields.
  SCHEMA_VERSION = 1;

  # Accept the kix pin envelope and a bare map without that envelope.
  version = parsed.version or SCHEMA_VERSION;

  raw =
    if version != SCHEMA_VERSION then
      throw "kix.pins: ${where} declares version ${builtins.toString version}, and this Kix reads version ${builtins.toString SCHEMA_VERSION}. Upgrade Kix, or check the file."
    else
      parsed.images or parsed;

  # repository and tag are required. digest, provenance fields, and the
  # user-maintained note remain optional.
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
      throw "kix.pins: pin '${key}' in ${where} has a digest that is not sha256: followed by 64 hexadecimal characters: '${digest}'. Re-resolve it with `kix pin set ${key}`."
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
