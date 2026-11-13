# Apply instance pins and track the origin of each image option value.
#
# An instance pin is an entry in a pin file's `instances` map:
# `"<namespace>/<instance>": { "<option path>": <pin> }`. `module` applies it as
# an instance config definition whose `_file` is the pin file so the module
# system records the pin file as the definition location. `check` rejects any
# pin that shares an option with a competing definition in code, and
# `imageSources` reads those location records back.
{ lib, packageDefaultPriority }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  # Strip `/nix/store/<hash>-source/` from store paths for error messages.
  relativeFile =
    file:
    let
      m = builtins.match "/nix/store/[^/]+/(.*)" file;
    in
    if m == null then file else builtins.head m;

  # Return the path of `file` relative to flake `self`, or null when `self` is
  # null or `file` lives outside `self` (for example, in another flake input).
  # `kix-image-sources.json` records only paths inside `self` that can be edited
  # in this repository.
  pathInFlake =
    self: file:
    let
      root = builtins.unsafeDiscardStringContext (toString self);
      f = builtins.unsafeDiscardStringContext (toString file);
    in
    if self == null || file == null || !(lib.hasPrefix "${root}/" f) then
      null
    else
      lib.removePrefix "${root}/" f;

  # Extract the file path from module-system location strings such as
  # `"<file>, via option instances.<ns>.<inst>.config"`, or return null for
  # inline modules (`"<unknown-file>"`).
  moduleFile =
    file:
    let
      m = builtins.match "(.*), via option .*" file;
      f = if m == null then file else builtins.head m;
    in
    if f == "<unknown-file>" then null else f;

  # Return `{ file, line }` for a module definition. When the value is an
  # attrset from Nix source, use the position of its first attribute outside
  # `kix/lib/vocab` (ignoring attributes synthesized by helpers such as
  # `pins.get`). Otherwise fall back to the module's file with `line = null`.
  kixVocab = toString ../vocab;
  definitionPlace =
    def:
    let
      positions =
        if builtins.isAttrs def.value then
          builtins.filter (p: p != null && !(lib.hasPrefix "${kixVocab}/" p.file)) (
            map (n: builtins.unsafeGetAttrPos n def.value) (builtins.attrNames def.value)
          )
        else
          [ ];
      file = moduleFile def.file;
    in
    if positions != [ ] then
      {
        inherit (builtins.head positions) file line;
      }
    else
      {
        inherit file;
        line = null;
      };

  describePlace =
    def:
    let
      p = definitionPlace def;
    in
    if p.file == null then
      "a module with no file (${def.file})"
    else if p.line == null then
      relativeFile p.file
    else
      "${relativeFile p.file} line ${toString p.line}";

  # Return true when `opt` is an image submodule option declared with
  # `kix.options.image`.
  isImageOption =
    opt:
    (builtins.tryEval (
      opt.type.name == "submodule"
      && (
        let
          sub = opt.type.getSubOptions [ ];
        in
        sub ? repository && sub ? tag && sub ? digest
      )
    )).value or false;

  # Return the attribute paths of all top-level image options in `opts` without
  # recursing into submodules.
  imageOptionPaths =
    prefix: opts:
    builtins.concatLists (
      lib.mapAttrsToList (
        k: o:
        if lib.isOption o then
          lib.optional (isImageOption o) (prefix ++ [ k ])
        else if builtins.isAttrs o && !(o ? _type) then
          imageOptionPaths (prefix ++ [ k ]) o
        else
          [ ]
      ) opts
    );

  showPaths = paths: lib.concatMapStringsSep ", " (lib.concatStringsSep ".") paths;
in
{
  inherit relativeFile pathInFlake imageOptionPaths;

  # Build the module that applies an instance's `{ file, options }` pin entries.
  module = instancePins: {
    _file = instancePins.file;
    config = lib.foldl' lib.recursiveUpdate { } (
      lib.mapAttrsToList (
        option: pin: lib.setAttrByPath (lib.splitString "." option) pin
      ) instancePins.options
    );
  };

  # Validate that each pinned option is a declared image option on the package
  # and has no competing definition outside the pin file. Without this check, a
  # definition in Nix code would merge with the pin field by field or override
  # it silently.
  #
  # Ignore definitions where every field has a lower priority than the pin
  # (such as package defaults at `packageDefaultPriority` or `lib.mkDefault` in
  # cluster code). Check `packageOptions` before reading evaluated `options` so
  # undeclared options report the package's available image options.
  check =
    {
      packageOptions,
      options,
      instancePins,
      instanceText,
    }:
    let
      where = relativeFile instancePins.file;
      pinned = builtins.attrNames instancePins.options;
      declared = builtins.foldl' (
        _: option:
        let
          opt = lib.attrByPath (lib.splitString "." option) null packageOptions;
        in
        if opt == null || !(lib.isOption opt) then
          fail {
            message = "kix.pins: ${where} pins option '${option}' of ${instanceText}, and its package has no such option.";
            fix = "Pin one of its image options: ${
              let
                paths = imageOptionPaths [ ] packageOptions;
              in
              if paths == [ ] then "none" else showPaths paths
            }.";
          }
        else if !(isImageOption opt) then
          fail {
            message = "kix.pins: ${where} pins option '${option}' of ${instanceText}, which is not an image option.";
            fix = "Pin an option declared with kix.options.image.";
          }
        else
          null
      ) null pinned;
      alone = builtins.foldl' (
        _: option:
        let
          defs = (lib.getAttrFromPath (lib.splitString "." option) options).definitionsWithLocations;
          # `lib.mkOverride` wraps a field as `{ _type = "override"; priority; }`,
          # where a numerically larger `priority` has lower precedence.
          belowPin =
            v:
            builtins.isAttrs v
            && (v._type or null) == "override"
            && v.priority > (lib.mkOverride 100 null).priority;
          weaker =
            d:
            builtins.isAttrs d.value
            && !(d.value ? _type)
            && builtins.all belowPin (builtins.attrValues d.value);
          others = builtins.filter (d: d.file != instancePins.file && !(weaker d)) defs;
        in
        if others != [ ] then
          fail {
            message = "kix.pins: ${where} pins option '${option}' of ${instanceText}, and ${
              lib.concatMapStringsSep " and " describePlace others
            } sets it too.";
            fix = "Keep one of them: remove the other value, or delete the entry from the pin file.";
          }
        else
          null
      ) null pinned;
    in
    builtins.seq declared alone;

  # Return one provenance record per evaluable image option of an instance for
  # `kix-image-sources.json`, classifying `origin` as `package_default`, `pin`,
  # `injected`, `nix_built`, or `code`. Skip options whose values fail to
  # evaluate so normal cluster evaluation reports the error at the use site.
  imageSources =
    {
      self,
      namespaceName,
      instanceName,
      evaluation,
      packageConfigFile,
      instancePins ? null,
      pins ? null,
    }:
    builtins.concatMap (
      path:
      let
        opt = lib.getAttrFromPath path evaluation.options;
        value = lib.getAttrFromPath path evaluation.config;
        final = {
          repository = value.repository;
          tag = value.tag;
          digest = value.digest;
        };
        evaluates = (builtins.tryEval (builtins.deepSeq final true)).success;
        option = lib.concatStringsSep "." path;
        defs = opt.definitionsWithLocations;
        pinFile = if instancePins == null then null else instancePins.file;
        fromPin = instancePins != null && instancePins.options ? ${option};
        fromPackage =
          opt.highestPrio >= packageDefaultPriority || builtins.all (d: d.file == packageConfigFile) defs;
        injection = lib.findFirst (d: lib.hasPrefix "config injected into " d.file) null defs;
        imagePin =
          if pins == null then
            null
          else
            lib.findFirst (
              key:
              let
                p = pins.all.${key};
              in
              p.repository == final.repository && p.tag == final.tag && (p.digest or null) == final.digest
            ) null pins.keys;
        hasContext = builtins.hasContext final.repository || builtins.hasContext final.tag;
        code = lib.findFirst (d: d.file != packageConfigFile) (builtins.head defs) defs;
        place =
          let
            p = definitionPlace code;
          in
          p // { file = pathInFlake self p.file; };
        noPlace = {
          file = null;
          line = null;
        };
        pinPlace = {
          file = if pins == null then null else pathInFlake self pins.file;
          line = null;
        };

        origin =
          if fromPin then
            {
              origin = "pin";
              pin = {
                map = "instances";
                key = "${namespaceName}/${instanceName}";
              };
              dependency = null;
            }
            // {
              file = pathInFlake self pinFile;
              line = null;
            }
          else if fromPackage then
            {
              origin = "package_default";
              pin = null;
              dependency = null;
            }
            // noPlace
          else if injection != null then
            {
              origin = "injected";
              pin = null;
              dependency = builtins.head (builtins.match "config injected into .* by (.*)" injection.file);
            }
            // noPlace
          else if imagePin != null then
            {
              origin = "pin";
              pin = {
                map = "images";
                key = imagePin;
              };
              dependency = null;
            }
            // pinPlace
          else if hasContext then
            {
              origin = "nix_built";
              pin = null;
              dependency = null;
            }
            // place
          else
            {
              origin = "code";
              pin = null;
              dependency = null;
            }
            // place;

        default =
          if opt ? default && opt.default ? repository && opt.default ? tag then
            { inherit (opt.default) repository tag; }
          else
            null;
      in
      lib.optional evaluates (
        {
          namespace = namespaceName;
          instance = instanceName;
          inherit option default;
          # A Nix-built reference carries its build in its string context,
          # which `builtins.toFile` refuses.
          repository = builtins.unsafeDiscardStringContext final.repository;
          tag = builtins.unsafeDiscardStringContext final.tag;
          digest = if final.digest == null then null else builtins.unsafeDiscardStringContext final.digest;
        }
        // origin
      )
    ) (imageOptionPaths [ ] evaluation.options);
}
