# Read image references from a pin file or an attrset. The returned interface is:
#
#     .get <key>   the pin, shape-checked, ready for kix.image.ref
#     .ref <key>   sugar for `kix.image.ref (get key)`
#     .keys        every pin name in the file
#     .all         every pin, shape-checked
#     .instances   instance pins, shape-checked: "<namespace>/<instance>" to
#                  an attrset from option path (`image`, `server.image`) to pin
#     .file        the pin file as a string, or null for an attrset
#
# `get` validates the entry and reports the command for adding a missing key.
#
# `images` holds pins a cluster reads by name with `get`. `instances` holds
# pins `kix.buildCluster { pins = ...; }` applies itself, each as a
# definition of that instance's option whose file is the pin file
# (eval/resolve.nix). A file with `instances` declares version 2.
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

  # Version 1 has `images` only; version 2 adds `instances`. Reject any
  # other version before interpreting its fields.
  SCHEMA_VERSIONS = [
    1
    2
  ];

  # Accept the kix pin envelope and a bare map of image pins without it.
  isEnvelope = parsed ? version || parsed ? images || parsed ? instances;
  version = parsed.version or 1;

  checkedEnvelope =
    if !(builtins.elem version SCHEMA_VERSIONS) then
      throw "kix.pins: ${where} declares version ${builtins.toString version}, and this Kix reads versions 1 and 2. Upgrade Kix, or check the file."
    else if version == 1 && parsed ? instances then
      throw "kix.pins: ${where} has instance pins (`instances`) but declares version 1. A file with instance pins declares version 2."
    else
      parsed;

  envelopeFields = [
    "version"
    "managedBy"
    "images"
    "instances"
  ];

  # Refused rather than ignored: a field this Kix does not know may be one a
  # newer Kix acts on, as `instances` is to a Kix that reads only version 1.
  unknownEnvelopeFields = builtins.filter (f: !(builtins.elem f envelopeFields)) (
    builtins.attrNames parsed
  );

  raw =
    if !isEnvelope then
      parsed
    else if unknownEnvelopeFields != [ ] then
      throw "kix.pins: ${where} has top-level fields Kix does not know: ${builtins.concatStringsSep ", " unknownEnvelopeFields}. Known fields are ${builtins.concatStringsSep ", " envelopeFields}. Upgrade Kix, or check the file."
    else
      checkedEnvelope.images or { };

  rawInstances = if isEnvelope then builtins.seq raw (checkedEnvelope.instances or { }) else { };

  # The image reference grammar of the OCI distribution spec
  # (distribution/reference): an optional registry host and port, then
  # lower-case path components; a tag of at most 128 word characters,
  # dots, and dashes. `kix pin` checks the same grammar
  # (cli/kix/src/pins/mod.rs).
  pathComponent = "[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*";
  hostComponent = "([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])";
  host = "(${hostComponent}([.]${hostComponent})*|[[][0-9a-fA-F:]+[]])(:[0-9]+)?";
  repositoryRe = "(${host}/)?${pathComponent}(/${pathComponent})*";
  tagRe = "[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}";

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

  # `label` names the entry in errors; `setArgs` are the `kix pin set`
  # arguments that rewrite it.
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
      throw "kix.pins: ${label} in ${where} is not an attribute set."
    else if missing != [ ] then
      throw "kix.pins: ${label} in ${where} is missing ${builtins.concatStringsSep " and " missing}. Every pin needs a repository and a tag."
    else if unknown != [ ] then
      throw "kix.pins: ${label} in ${where} has fields Kix does not know: ${builtins.concatStringsSep ", " unknown}. Known fields are ${builtins.concatStringsSep ", " known}."
    else if !repositoryOk then
      throw "kix.pins: ${label} in ${where} has a repository that is not an image repository: '${toString pin.repository}'. A repository is an optional registry host, then lower-case path components separated by `/`, such as docker.io/library/nginx."
    else if builtins.isString pin.tag && lib.hasInfix "@" pin.tag then
      throw "kix.pins: ${label} in ${where} has a digest in its tag: '${pin.tag}'. Put the tag in `tag` and the digest in `digest`, or re-resolve it with `kix pin set ${setArgs}`."
    else if !tagOk then
      throw "kix.pins: ${label} in ${where} has a tag that is not an image tag: '${toString pin.tag}'. A tag is up to 128 letters, digits, `_`, `.` and `-`, and does not start with `.` or `-`."
    else if !digestOk then
      throw "kix.pins: ${label} in ${where} has a digest that is not sha256: followed by 64 hexadecimal characters: '${digest}'. Re-resolve it with `kix pin set ${setArgs}`."
    else
      # A pin states its digest, null when unresolved. Left out, the image
      # option would keep the package's digest whenever the tags match, even
      # under a different repository (vocab/compose.nix, the `digest` default).
      pin // { inherit digest; };

  checkShape = key: checkShapeAs "pin '${key}'" key;

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
  # An instance key names one instance; an option path names an option of
  # its package, dot-separated.
  checkInstance =
    instance: byOption:
    if builtins.match "[^/]+/[^/]+" instance == null then
      throw "kix.pins: instance pin '${instance}' in ${where} is not <namespace>/<instance>."
    else if !(builtins.isAttrs byOption) || byOption == { } then
      throw "kix.pins: instance pin '${instance}' in ${where} must map option paths, such as `image`, to pins."
    else
      lib.mapAttrs (
        option: pin:
        if builtins.match "[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*" option == null then
          throw "kix.pins: instance pin '${instance}' in ${where} names option '${option}', which is not an option path such as `image` or `server.image`."
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
