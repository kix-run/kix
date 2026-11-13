# Load and validate image references from a JSON pin file or an attrset.
#
# Returns an attrset with:
#   .get <key>   return a validated pin attrset for `kix.image.ref`
#   .ref <key>   render `kix.image.ref (get key)`
#   .keys        list all named image pin keys
#   .all         validate and return all named image pins
#   .instances   validate and return per-instance option pins (version 2)
#   .file        path to the pin file as a string, or null for an attrset
#
# `images` holds pins that a cluster reads by name with `get`. `instances`
# holds pins that `kix.buildCluster { pins = ...; }` applies automatically to
# matching `<namespace>/<instance>` option paths (`eval/resolve.nix`).
#
# Pin files use JSON so the CLI can update image digests without evaluating
# Nix. Shape validation does not query a registry. Use `kix pin check` to
# verify digests against registries.
{ lib, image }:

source:
let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  isPath = builtins.isPath source;
  parsed = if isPath then builtins.fromJSON (builtins.readFile source) else source;

  # Flake path literals evaluate to store paths. Show the last two path
  # components in errors so they identify the source file rather than its store
  # hash.
  where =
    if isPath then
      let
        parts = lib.splitString "/" (toString source);
        tail = lib.sublist (builtins.length parts - 2) 2 parts;
      in
      lib.concatStringsSep "/" (if builtins.length parts >= 2 then tail else parts)
    else
      "the pins attrset";

  # Version 1 supports `images` only. Version 2 adds `instances`.
  SCHEMA_VERSIONS = [
    1
    2
  ];

  # Accept either the versioned pin envelope or a bare attrset of image pins.
  isEnvelope = parsed ? version || parsed ? images || parsed ? instances;
  version = parsed.version or 1;

  checkedEnvelope =
    if !(builtins.elem version SCHEMA_VERSIONS) then
      fail {
        message = "kix.pins: ${where} declares version ${builtins.toString version}, and Kix reads versions 1 and 2.";
        fix = "Upgrade Kix, or check the file.";
      }
    else if version == 1 && parsed ? instances then
      fail {
        message = "kix.pins: ${where} has instance pins (`instances`) but declares version 1.";
        fix = "Declare version 2 in a file with instance pins.";
      }
    else
      parsed;

  envelopeFields = [
    "version"
    "managedBy"
    "images"
    "instances"
  ];

  # Reject unknown top-level fields so an older Kix never silently ignores
  # fields introduced by a newer schema version.
  unknownEnvelopeFields = builtins.filter (f: !(builtins.elem f envelopeFields)) (
    builtins.attrNames parsed
  );

  raw =
    if !isEnvelope then
      parsed
    else if unknownEnvelopeFields != [ ] then
      fail {
        message = "kix.pins: ${where} has top-level fields Kix does not know: ${builtins.concatStringsSep ", " unknownEnvelopeFields}. Known fields are ${builtins.concatStringsSep ", " envelopeFields}.";
        fix = "Upgrade Kix, or check the file.";
      }
    else
      checkedEnvelope.images or { };

  rawInstances = if isEnvelope then builtins.seq raw (checkedEnvelope.instances or { }) else { };

  # Match the OCI distribution reference grammar (`distribution/reference`)
  # enforced by `kix pin` (`cli/kix/src/pins/mod.rs`).
  pathComponent = "[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*";
  hostComponent = "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])";
  host = "(${hostComponent}([.]${hostComponent})*|[[][0-9a-fA-F:]+[]])(:[0-9]+)?";
  repositoryRe = "(${host}/)?${pathComponent}(/${pathComponent})*";
  tagRe = "[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}";

  known = [
    "repository"
    "tag"
    "digest"
    "sourceRev"
    "promotedBy"
    "resolvedAt"
    "note"
  ];

  # Validate a single pin entry. `label` names the entry in error messages and
  # `setArgs` formats the `kix pin set` command hint.
  checkShapeAs =
    label: setArgs: pin:
    let
      missing = builtins.filter (f: (pin.${f} or null) == null) [
        "repository"
        "tag"
      ];
      unknown = builtins.filter (f: !(builtins.elem f known)) (builtins.attrNames pin);
      digest = pin.digest or null;
      digestOk = digest == null || (builtins.match "sha256:[0-9a-f]{64}" digest) != null;
      repositoryOk =
        builtins.isString pin.repository
        && builtins.stringLength pin.repository <= 255
        && builtins.match repositoryRe pin.repository != null;
      tagOk = builtins.isString pin.tag && builtins.match tagRe pin.tag != null;
    in
    if !(builtins.isAttrs pin) then
      fail "kix.pins: ${label} in ${where} is not an attribute set."
    else if missing != [ ] then
      fail {
        message = "kix.pins: ${label} in ${where} is missing ${builtins.concatStringsSep " and " missing}.";
        fix = "Give every pin a repository and a tag.";
      }
    else if unknown != [ ] then
      fail "kix.pins: ${label} in ${where} has fields Kix does not know: ${builtins.concatStringsSep ", " unknown}. Known fields are ${builtins.concatStringsSep ", " known}."
    else if !repositoryOk then
      fail {
        message = "kix.pins: ${label} in ${where} has a repository that is not an image repository: '${toString pin.repository}'.";
        fix = "Write the repository as an optional registry host, then lower-case path components separated by `/`, such as docker.io/library/nginx.";
      }
    else if builtins.isString pin.tag && lib.hasInfix "@" pin.tag then
      fail {
        message = "kix.pins: ${label} in ${where} has a digest in its tag: '${pin.tag}'.";
        fix = "Put the tag in `tag` and the digest in `digest`, or re-resolve it with `kix pin set ${setArgs}`.";
      }
    else if !tagOk then
      fail {
        message = "kix.pins: ${label} in ${where} has a tag that is not an image tag: '${toString pin.tag}'.";
        fix = "Use a tag of up to 128 letters, digits, `_`, `.`, and `-` that does not start with `.` or `-`.";
      }
    else if !digestOk then
      fail {
        message = "kix.pins: ${label} in ${where} has a digest that is not sha256: followed by 64 hexadecimal characters: '${digest}'.";
        fix = "Re-resolve it with `kix pin set ${setArgs}`.";
      }
    else
      # Set `digest` explicitly (even when null) so an unresolved pin overrides
      # the package's default digest when their tags happen to match.
      pin // { inherit digest; };

  checkShape = key: checkShapeAs "pin '${key}'" key;

  get =
    key:
    if raw ? ${key} then
      checkShape key raw.${key}
    else
      fail {
        message = "kix.pins: ${where} has no pin named '${key}'. Pins in that file: ${
          if raw == { } then "none yet" else builtins.concatStringsSep ", " (builtins.attrNames raw)
        }.";
        fix = "Add it with:\n  kix pin set ${key} --repository <registry/repository> --tag <tag> --init";
      };
  # Validate the option-path map for a single `<namespace>/<instance>` entry.
  checkInstance =
    instance: byOption:
    if builtins.match "[^/]+/[^/]+" instance == null then
      fail "kix.pins: instance pin '${instance}' in ${where} is not <namespace>/<instance>."
    else if !(builtins.isAttrs byOption) || byOption == { } then
      fail "kix.pins: instance pin '${instance}' in ${where} must map option paths, such as `image`, to pins."
    else
      lib.mapAttrs (
        option: pin:
        if builtins.match "[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*" option == null then
          fail "kix.pins: instance pin '${instance}' in ${where} names option '${option}', which is not an option path such as `image` or `server.image`."
        else
          checkShapeAs "instance pin '${instance}' option '${option}'" (
            instance + lib.optionalString (option != "image") " --option ${option}"
          ) pin
      ) byOption;
in
{
  inherit get;
  ref = key: image.ref (get key);
  keys = builtins.attrNames raw;
  all = lib.mapAttrs checkShape raw;
  instances = lib.mapAttrs checkInstance rawInstances;
  file = if isPath then toString source else null;
}
